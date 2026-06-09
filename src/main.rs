use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use std::ffi::CString;

/// Vantage-5G: eBPF-EDT 기반 동적 대역폭 제어 CLI
#[derive(Parser)]
#[command(name = "vantage-cli")]
#[command(about = "Controls 5G Tenant Bandwidth via Pinned eBPF Maps", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// 특정 테넌트의 대역폭을 설정합니다 (QoS Enforcement)
    Set {
        /// Cilium이 부여한 테넌트 Identity 번호 (예: 5001)
        #[arg(short, long)]
        tenant: u32,

        /// 목표 대역폭 (단위: Mbps). 0 입력 시 즉각 차단(Kill Switch).
        #[arg(short, long)]
        bw_mbps: u64,
    },
    /// 특정 테넌트의 정책을 삭제하여 대역폭 제한을 해제합니다.
    Reset {
        #[arg(short, long)]
        tenant: u32,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    
    // Vantage-5G 데이터 평면이 핀(Pin)해둔 커널 맵 경로
    let map_path = CString::new("/sys/fs/bpf/tc/globals/tenant_bw_map")?;

    // 1. [Low-level] 핀(Pin)된 커널 맵의 File Descriptor 획득
    let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
    if fd < 0 {
        bail!("Failed to open pinned map. Vantage-5G 데이터 평면이 정상적으로 부착되었는지 확인하십시오.");
    }

    match &cli.command {
        Commands::Set { tenant, bw_mbps } => {
            // Mbps를 bps로 변환
            let target_bps: u64 = bw_mbps * 1_000_000;
            
            let key = tenant.to_ne_bytes();
            let value = target_bps.to_ne_bytes();

            // 2. [Low-level] BPF Syscall을 통한 메모리 직접 업데이트
            let ret = unsafe {
                libbpf_sys::bpf_map_update_elem(
                    fd,
                    key.as_ptr() as *const _,
                    value.as_ptr() as *const _,
                    libbpf_sys::BPF_ANY.into(),
                )
            };

            if ret != 0 {
                bail!("Map update failed with error code: {}", ret);
            }

            if *bw_mbps == 0 {
                println!("[Vantage-5G] 🛑 Tenant {} is now BLOCKED (0 Mbps).", tenant);
            } else {
                println!("[Vantage-5G] 🚀 Tenant {} bandwidth set to {} Mbps.", tenant, bw_mbps);
            }
        }
        Commands::Reset { tenant } => {
            let key = tenant.to_ne_bytes();
            
            // 3. [Low-level] 맵 엔트리 삭제
            let ret = unsafe {
                libbpf_sys::bpf_map_delete_elem(
                    fd,
                    key.as_ptr() as *const _,
                )
            };
            
            if ret == 0 {
                println!("[Vantage-5G] 🔓 Tenant {} policy removed (Unlimited).", tenant);
            } else {
                println!("[Vantage-5G] ⚠️ Failed to reset. 해당 테넌트를 맵에서 찾을 수 없습니다.");
            }
        }
    }

    Ok(())
}
