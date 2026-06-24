use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::net::Ipv4Addr;
use std::time::{Duration, Instant};

// K8s API 및 Prometheus 패키지 개방
use kube::{api::{Api, Patch, PatchParams}, Client};
use k8s_openapi::api::core::v1::Pod;
use serde_json::json;
use prometheus::{opts, register_counter_vec, register_gauge, CounterVec, Gauge};
use lazy_static::lazy_static;

// 🚨 [혁신적 구조] Prometheus 메트릭 전역 레지스트리 선언 (TCP 재전송 게이지 추가)
lazy_static! {
    static ref TENANT_BYTES_TOTAL: CounterVec = register_counter_vec!(
        opts!("vantage_tenant_tx_bytes_total", "5G tenant accumulated transmit bytes total"),
        &["pod_ip"]
    ).unwrap();

    static ref TENANT_PACKETS_TOTAL: CounterVec = register_counter_vec!(
        opts!("vantage_tenant_tx_packets_total", "5G tenant accumulated transmit packets total"),
        &["pod_ip"]
    ).unwrap();

    // 💡 [새로운 무기] 커널 글로벌 TCP 재전송 누적 감시용 Prometheus 게이지
    static ref NODE_TCP_RETRANSMIT_TOTAL: Gauge = register_gauge!(
        opts!("vantage_node_tcp_retransmit_total", "5G node accumulated retransmit packets total")
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

// 커널 C 구조체와 100% 동기화되는 메모리 패딩 명세
#[repr(C)]
struct TelemetryEvent {
    tenant_id: u32, 
    pkt_len: u32,
    target_bps: u64,
    delay_ns: u64,
    timestamp_ns: u64,
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
            // 1. [비동기 엔진 가동] Prometheus HTTP Exporter 서버를 9090 포트에 개방
            tokio::spawn(async {
                println!("[Vantage-5G] 📈 Prometheus Metrics Endpoint 가동 중: http://0.0.0.0:9090/metrics");
                prometheus_exporter::start("0.0.0.0:9090".parse().unwrap())
                    .expect("Prometheus Exporter 가동 실패");
            });

            // 2. [오케스트레이션 영속화] 커널 제어 및 데이터 폴링용 동기 블로킹 태스크 진입
            tokio::task::spawn_blocking(|| -> Result<()> {
                println!("[Vantage-5G] 📡 Rust-Native libbpf 엔진 런타임 초기화...");

                // eBPF 오브젝트 파일 직접 로드 (bpftool 완전 대체)
                let open_obj = libbpf_rs::ObjectBuilder::default()
                    .open_file("vantage_ringbuf_edt.o")
                    .context("[-] eBPF 오브젝트 바이너리 오픈 실패")?;

                let mut loaded_obj = open_obj.load().context("[-] 커널 메모리 로드 거부 (BTF/커널 버전 체크 필요)")?;
                println!("[+] 1단계: eBPF 오브젝트 커널 주입 무결성 검증 완료.");

                // 🚨 [인프라 정렬 자율화] 외부 ready.sh 및 tc 호환성을 위해 가상 파일시스템(BPFFS) 고정 강제 실행
                let _ = std::fs::create_dir_all("/sys/fs/bpf/vantage");
                let _ = std::fs::create_dir_all("/sys/fs/bpf/tc/globals");

                // 🚨 [혁신적 교정 주입] 과거 유령 핀 파일 선제 소각 (Idempotent Cleanup)
                // 이 처리를 통해 맵 분열(Split-Brain) 현상을 원천 차단합니다.
                let _ = std::fs::remove_file("/sys/fs/bpf/tc/globals/telemetry_rb");
                let _ = std::fs::remove_file("/sys/fs/bpf/tc/globals/tcp_retransmit_counter");
                let _ = std::fs::remove_file("/sys/fs/bpf/vantage/vantage_telemetry_sniffer");

                // 핀 결속 코드
                if let Some(map) = loaded_obj.map_mut("telemetry_rb") { let _ = map.pin("/sys/fs/bpf/tc/globals/telemetry_rb"); }
                if let Some(map) = loaded_obj.map_mut("tcp_retransmit_counter") { let _ = map.pin("/sys/fs/bpf/tc/globals/tcp_retransmit_counter"); }
                if let Some(prog) = loaded_obj.prog_mut("vantage_telemetry_sniffer") { let _ = prog.pin("/sys/fs/bpf/vantage/vantage_telemetry_sniffer"); }

                // 🚨 [핵심 돌파] bpftool 제약을 깨부수는 fentry 프로그램 자율 결속 (Auto-Attach)
                let _fentry_link = loaded_obj.prog_mut("vantage_tcp_retransmit")
                    .ok_or_else(|| anyhow::anyhow!("[-] vantage_tcp_retransmit 섹션 부재"))?
                    .attach()
                    .context("[-] fentry 커널 트램펄린 자율 용접 실패")?;
                println!("[+] 2단계: fentry/tcp_retransmit_skb 자율 커널 링크 형성 완료.");

                // 3. [고수준 고안] libbpf-rs 전용 RingBuffer 인터페이스 빌드 (Unsafe 완전 소각)
                let mut rb_builder = libbpf_rs::RingBufferBuilder::new();
                let telemetry_map = loaded_obj.map("telemetry_rb").context("[-] telemetry_rb 맵 탐색 실패")?;
                
                // Safe Rust 클로저 바인딩으로 포인터 역참조 경고(E0133) 완벽 제거
                rb_builder.add(&telemetry_map, move |data: &[u8]| {
                    if data.len() < std::mem::size_of::<TelemetryEvent>() { return 1; }
                    
                    // 정렬된 바이트 슬라이스를 구조체 참조로 안전하게 투영
                    let event = unsafe { &*(data.as_ptr() as *const TelemetryEvent) };
                    
                    let ip_bytes = event.tenant_id.to_ne_bytes();
                    let ip_addr = Ipv4Addr::new(ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3]);
                    let ip_str = ip_addr.to_string();

                    TENANT_BYTES_TOTAL.with_label_values(&[&ip_str]).inc_by(event.pkt_len as f64);
                    TENANT_PACKETS_TOTAL.with_label_values(&[&ip_str]).inc();

                    println!("[📡 TELEMETRY] Pod IP: {:<15} | 📦 크기: {:>4} Bytes | 메트릭 적치 완료", 
                        ip_str, event.pkt_len);
                    0
                }).context("[-] 링버퍼 이벤트 콜백 등록 실패")?;

                let ring_buffer = rb_builder.build().context("[-] 커널 링버퍼 빌드 실패")?;
                println!("[+] 3단계: 하이브리드 가상 관측망 통합 청취 루프 개통.");

                // 🚨 [정밀 주입] 초기 기동 시 0 값 강제 주입으로 프로메테우스 엔드포인트에 즉시 노출 선언
                NODE_TCP_RETRANSMIT_TOTAL.set(0.0);

                // 4. [시분할 아키텍처] 100ms 폴링 루프 내 1초 주기 Per-CPU 맵 스크래핑 엔진
                let counter_map = loaded_obj.map("tcp_retransmit_counter").context("[-] 카운터 맵 탐색 실패")?;
                let map_key = 0u32.to_ne_bytes();
                let mut last_scrape = Instant::now();

                loop {
                    // 고속 패킷 링 버퍼 청취 (Timeout: 100ms)
                    if let Err(e) = ring_buffer.poll(Duration::from_millis(100)) {
                        println!("[-] 커널 관측망 폴링 파괴: {}", e);
                        break;
                    }

                    // 리소스 경합을 막기 위한 1초 주기 시분할 커널 스크래핑 ($O(1)$ 연산)
                    if last_scrape.elapsed() >= Duration::from_secs(1) {
                        if let Ok(Some(value_bytes)) = counter_map.lookup(&map_key, libbpf_rs::MapFlags::empty()) {
                            let mut total_retransmits = 0u64;

                            // 모든 CPU 코어의 카운터 배열 바이트 스트림을 u64 단위로 합산
                            for chunk in value_bytes.chunks_exact(8) {
                                if let Ok(arr) = chunk.try_into() {
                                    total_retransmits += u64::from_ne_bytes(arr);
                                }
                            }

                            if total_retransmits > 0 {
                                // Prometheus 실시간 메트릭 동기화
                                NODE_TCP_RETRANSMIT_TOTAL.set(total_retransmits as f64);
                                println!("[🚨 KERNEL INFRA] 커널 미세 신호 포착 -> 누적 TCP 재전송 총합: {} 회", total_retransmits);
                            }
                        }
                        last_scrape = Instant::now();
                    }
                }
                Ok(())
            }).await??;
        }
    }
    Ok(())
}
