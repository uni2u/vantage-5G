use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use std::ffi::CString;
use std::os::raw::{c_int, c_void};
use std::net::Ipv4Addr;

// K8s API 및 Prometheus 패키지 개방
use kube::{api::{Api, Patch, PatchParams}, Client};
use k8s_openapi::api::core::v1::Pod;
use serde_json::json;
use prometheus::{opts, register_counter_vec, register_gauge_vec, CounterVec, GaugeVec};
use lazy_static::lazy_static;

// 🚨 [혁신적 구조] Prometheus 메트릭 전역 레지스트리 선언
lazy_static! {
    static ref TENANT_BYTES_TOTAL: CounterVec = register_counter_vec!(
        opts!("vantage_tenant_tx_bytes_total", "5G 테넌트 누적 전송 바이트 수"),
        &["pod_ip"]
    ).unwrap();

    static ref TENANT_PACKETS_TOTAL: CounterVec = register_counter_vec!(
        opts!("vantage_tenant_tx_packets_total", "5G 테넌트 누적 전송 패킷 수"),
        &["pod_ip"]
    ).unwrap();
}

#[derive(Parser)]
#[command(name = "vantage-cli", about = "Vantage-5G Hybrid Orchestrator")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Set {
        #[arg(short, long)] pod: String,
        #[arg(short, long, default_value = "default")] namespace: String,
        #[arg(short, long)] bw_mbps: u64,
    },
    Reset {
        #[arg(short, long)] pod: String,
        #[arg(short, long, default_value = "default")] namespace: String,
    },
    Monitor,
}

#[repr(C)]
struct TelemetryEvent {
    tenant_id: u32, // 커널로부터 수신된 원시 IP 바이트 데이터
    pkt_len: u32,
    target_bps: u64,
    delay_ns: u64,
    timestamp_ns: u64,
}

// 🚨 커널 Ring Buffer 이벤트를 수신하는 고속 콜백 함수
unsafe extern "C" fn handle_event(_ctx: *mut c_void, data: *mut c_void, _size: u64) -> c_int {
    let event = std::ptr::read(data as *const TelemetryEvent);
    
    // IP 주소 포맷 변환
    let ip_bytes = event.tenant_id.to_ne_bytes();
    let ip_addr = Ipv4Addr::new(ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3]);
    let ip_str = ip_addr.to_string();

    // 🚨 [Zero-Overhead 연산] Prometheus 메트릭 카운터 증가 (실시간 스레드 세이프)
    TENANT_BYTES_TOTAL.with_label_values(&[&ip_str]).inc_by(event.pkt_len as f64);
    TENANT_PACKETS_TOTAL.with_label_values(&[&ip_str]).inc();

    // 실시간 CLI 콘솔 가시성 확보
    println!("[📡 TELEMETRY] Pod IP: {:<15} | 📦 크기: {:>4} Bytes | 메트릭 적치 완료", 
        ip_str, event.pkt_len);
    0
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    
    match &cli.command {
        Commands::Set { pod, namespace, bw_mbps } => {
            let client = Client::try_default().await.context("K8s 연결 실패")?;
            let pods: Api<Pod> = Api::namespaced(client, namespace); 
            let patch = json!({
                "metadata": {"annotations": {"kubernetes.io/egress-bandwidth": format!("{}M", bw_mbps)}}
            });
            pods.patch(pod, &PatchParams::apply("vantage-cli"), &Patch::Merge(&patch)).await?;
            println!("[Vantage-5G] 🚀 K8s Pod '{}' 대역폭 {} Mbps 제어 선포 (Cilium EDT).", pod, bw_mbps);
        }
        
        Commands::Reset { pod, namespace } => {
            let client = Client::try_default().await?;
            let pods: Api<Pod> = Api::namespaced(client, namespace); 
            let patch = json!({
                "metadata": {"annotations": {"kubernetes.io/egress-bandwidth": serde_json::Value::Null}}
            });
            pods.patch(pod, &PatchParams::apply("vantage-cli"), &Patch::Merge(&patch)).await?;
            println!("[Vantage-5G] 🔓 K8s Pod '{}' 대역폭 제어 정책 해제.", pod);
        }
        
        Commands::Monitor => {
            // 🚨 [비동기 엔진 가동] Prometheus HTTP Exporter 서버를 9090 포트에 개방
            tokio::spawn(async {
                println!("[Vantage-5G] 📈 Prometheus Metrics Endpoint 가동 중: http://0.0.0.0:9090/metrics");
                prometheus_exporter::start("0.0.0.0:9090".parse().unwrap())
                    .expect("Prometheus Exporter 가동 실패");
            });

            // 커널 폴링 루프 스레드 분리 보호
            tokio::task::spawn_blocking(|| {
                let map_path = CString::new("/sys/fs/bpf/tc/globals/telemetry_rb").unwrap();
                let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
                if fd < 0 { panic!("telemetry_rb를 찾을 수 없습니다."); }

                println!("[Vantage-5G] 📡 커널 가상 파이프라인 수신 루프 기동.");
                let rb = unsafe { libbpf_sys::ring_buffer__new(fd, Some(handle_event), std::ptr::null_mut(), std::ptr::null()) };
                
                loop {
                    let err = unsafe { libbpf_sys::ring_buffer__poll(rb, 100) }; 
                    if err < 0 { break; }
                }
                unsafe { libbpf_sys::ring_buffer__free(rb) };
            }).await?;
        }
    }
    Ok(())
}
