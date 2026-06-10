use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use std::ffi::CString;
use std::os::raw::{c_int, c_void};

#[derive(Parser)]
#[command(name = "vantage-cli", about = "Vantage-5G Control & Telemetry CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// 특정 테넌트의 대역폭을 설정합니다 (QoS Enforcement)
    Set {
        #[arg(short, long)] tenant: u32,
        #[arg(short, long)] bw_mbps: u64,
    },
    /// 대역폭 제한을 해제합니다.
    Reset {
        #[arg(short, long)] tenant: u32,
    },
    /// 📡 [Phase 5] 실시간 텔레메트리 모니터링 데몬 실행
    Monitor,
}

// eBPF C 코드의 telemetry_event와 메모리 레이아웃 100% 동일 정렬
#[repr(C)]
struct TelemetryEvent {
    tenant_id: u32,
    pkt_len: u32,
    target_bps: u64,
    delay_ns: u64,
    timestamp_ns: u64,
}

// 2. 콜백 함수 시그니처 수정 (usize -> u64 로 변경 및 unsafe 명시)
unsafe extern "C" fn handle_event(_ctx: *mut c_void, data: *mut c_void, _size: u64) -> c_int {
    // unsafe 함수 내부이므로 unsafe 블록을 따로 열 필요가 없습니다.
    let event = std::ptr::read(data as *const TelemetryEvent);
    
    let target_mbps = event.target_bps / 1_000_000;
    let delay_ms = event.delay_ns as f64 / 1_000_000.0;

    println!("[📡 EVENT] Tenant: {} | 📦 {} Bytes | 🚀 {} Mbps | ⏱️ Delay: {:.2} ms", 
        event.tenant_id, event.pkt_len, target_mbps, delay_ms);
    
    0 // 정상 처리 반환
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    
    match &cli.command {
        Commands::Set { tenant, bw_mbps } => {
            let map_path = CString::new("/sys/fs/bpf/tc/globals/tenant_bw_map")?;
            let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
            if fd < 0 { bail!("Failed to open tenant_bw_map. eBPF 데이터 평면 확인 요망."); }
            
            let target_bps: u64 = bw_mbps * 1_000_000;
            let key = tenant.to_ne_bytes();
            let value = target_bps.to_ne_bytes();

            let ret = unsafe {
                libbpf_sys::bpf_map_update_elem(fd, key.as_ptr() as *const _, value.as_ptr() as *const _, libbpf_sys::BPF_ANY.into())
            };
            if ret != 0 { bail!("Update failed."); }
            println!("[Vantage-5G] 🚀 Tenant {} bandwidth set to {} Mbps.", tenant, bw_mbps);
        }
        Commands::Reset { tenant } => {
            let map_path = CString::new("/sys/fs/bpf/tc/globals/tenant_bw_map")?;
            let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
            if fd < 0 { bail!("Failed to open tenant_bw_map."); }

            let key = tenant.to_ne_bytes();
            unsafe { libbpf_sys::bpf_map_delete_elem(fd, key.as_ptr() as *const _) };
            println!("[Vantage-5G] 🔓 Tenant {} policy removed.", tenant);
        }
        Commands::Monitor => {
            // Ring Buffer 맵의 File Descriptor 획득
            let map_path = CString::new("/sys/fs/bpf/tc/globals/telemetry_rb")?;
            let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
            if fd < 0 { 
                bail!("Failed to open telemetry_rb. eBPF 코드가 정상 로드되었는지 확인하십시오."); 
            }

            println!("[Vantage-5G] 📡 BPF Ring Buffer 텔레메트리 수신 개시... (Ctrl+C 종료)");

            // 커널 버퍼와 Rust 콜백 함수 연결
            let rb = unsafe {
                libbpf_sys::ring_buffer__new(fd, Some(handle_event), std::ptr::null_mut(), std::ptr::null())
            };

            if rb.is_null() {
                bail!("Failed to create ring buffer object.");
            }

            // 폴링 루프 (커널 버퍼를 주기적으로 확인)
            loop {
                let err = unsafe { libbpf_sys::ring_buffer__poll(rb, 100) }; // 100ms 타임아웃
                if err < 0 {
                    println!("Poll error: {}", err);
                    break;
                }
            }
            
            unsafe { libbpf_sys::ring_buffer__free(rb) };
        }
    }
    Ok(())
}
