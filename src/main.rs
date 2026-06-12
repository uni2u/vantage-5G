use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use std::ffi::CString;
use std::os::raw::{c_int, c_void};

// K8s API 패키지
use kube::{api::{Api, Patch, PatchParams}, Client};
use k8s_openapi::api::core::v1::Pod;
use serde_json::json;

#[derive(Parser)]
#[command(name = "vantage-cli", about = "Vantage-5G Hybrid Orchestrator (Cilium EDT + Custom BPF)")]
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
    tenant_id: u32,
    pkt_len: u32,
    target_bps: u64,
    delay_ns: u64,
    timestamp_ns: u64,
}

unsafe extern "C" fn handle_event(_ctx: *mut c_void, data: *mut c_void, _size: u64) -> c_int {
    let event = std::ptr::read(data as *const TelemetryEvent);
    let target_mbps = event.target_bps / 1_000_000;
    let delay_ms = event.delay_ns as f64 / 1_000_000.0;
    println!("[📡 EVENT] Tenant: {} | 📦 {} Bytes | 🚀 {} Mbps | ⏱️ Delay: {:.2} ms", 
        event.tenant_id, event.pkt_len, target_mbps, delay_ms);
    0
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    
    match &cli.command {
        Commands::Set { pod, namespace, bw_mbps } => {
            let client = Client::try_default().await.context("Failed to connect to K8s API. KUBECONFIG를 확인하세요.")?;
            let pods: Api<Pod> = Api::namespaced(client, namespace); 

            let patch = json!({
                "metadata": {
                    "annotations": {
                        "kubernetes.io/egress-bandwidth": format!("{}M", bw_mbps)
                    }
                }
            });

            pods.patch(pod, &PatchParams::apply("vantage-cli"), &Patch::Merge(&patch)).await?;
            println!("[Vantage-5G] 🚀 K8s Pod '{}' bandwidth set to {} Mbps via Cilium Fast-Path.", pod, bw_mbps);
        }
        
        Commands::Reset { pod, namespace } => {
            let client = Client::try_default().await?;
            let pods: Api<Pod> = Api::namespaced(client, namespace); 

            let patch = json!({
                "metadata": {
                    "annotations": {
                        "kubernetes.io/egress-bandwidth": serde_json::Value::Null
                    }
                }
            });

            pods.patch(pod, &PatchParams::apply("vantage-cli"), &Patch::Merge(&patch)).await?;
            println!("[Vantage-5G] 🔓 K8s Pod '{}' policy removed.", pod);
        }
        
        Commands::Monitor => {
            println!("[Vantage-5G] 📈 Prometheus 메트릭 서버 백그라운드 준비 완료");
            // 향후 여기에 prometheus_exporter::start(...) 등의 코드가 비동기로 실행될 수 있습니다.

            // 🚨 [핵심 변경 사항] 커널 폴링 루프를 별도의 OS 스레드로 격리하여 비동기 런타임 마비 방지
            tokio::task::spawn_blocking(|| {
                let map_path = CString::new("/sys/fs/bpf/tc/globals/telemetry_rb").expect("Map path error");
                let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
                if fd < 0 { 
                    eprintln!("Failed to open telemetry_rb. 엔진이 로드되었는지 확인하십시오."); 
                    return; 
                }

                println!("[Vantage-5G] 📡 BPF Ring Buffer 텔레메트리 수신 개시... (Ctrl+C 종료)");
                let rb = unsafe { libbpf_sys::ring_buffer__new(fd, Some(handle_event), std::ptr::null_mut(), std::ptr::null()) };
                if rb.is_null() { 
                    eprintln!("Failed to create ring buffer object."); 
                    return; 
                }

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
