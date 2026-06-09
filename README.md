# vatage-5G

## Phase 1: eBPF-Cilium 제어 평면 연동 A to Z 플레이북

### Rust 컴파일러 및 빌드 툴체인 설치
순정 Ubuntu 24.04 환경에 시스템 프로그래밍을 위한 Rust 환경을 구축합니다.

```
# 1. Rust 공식 인스톨러 다운로드 및 설치 (설치 프롬프트에서 '1' 입력 후 Enter)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 2. 현재 터미널 세션에 Cargo 환경 변수 즉시 적용
source $HOME/.cargo/env

# 3. 설치 정상 완료 확인
cargo --version
```

### 프로젝트 디렉터리 생성 및 초기화
Vantage-5G 제어 평면 에이전트를 개발할 작업 공간을 구성합니다.

```
# 1. 프로젝트 최상위 디렉터리 생성 및 이동
mkdir -p ~/vantage-5g
cd ~/vantage-5g

# 2. 실행 가능한 바이너리 프로젝트로 초기화 (Cargo.toml 및 src/ 폴더 자동 생성)
cargo init --bin
```

### 프로젝트 의존성 명세 (Cargo.toml)
불안정한 eBPF 고수준 라이브러리를 배제하고, 리눅스 커널 시스템 콜 직결을 위한 libc 표준 라이브러리만 주입합니다.

`~/vantage-5g/Cargo.toml` 파일을 열어 아래 내용으로 완전히 덮어씁니다.

```
[package]
name = "vantage-5g"
version = "0.1.0"
edition = "2026"

[dependencies]
# 리눅스 BPF 커널 시스템 콜 직결을 위한 C-FFI 표준 라이브러리
libc = "0.2"
```

### 제어 평면(Control Plane) 커널 직결 소스코드 작성
Cilium v2 맵의 24B/24B 패딩 규격을 완벽하게 리버스 엔지니어링한 최종 무결성 코드입니다.

`~/vantage-5g/src/main.rs` 파일을 열어 아래 내용으로 완전히 덮어씁니다.

```
// src/main.rs - Vantage-5G 제어 평면 eBPF 커널 직결 에이전트
use std::ffi::CString;
use std::path::Path;
use std::net::Ipv4Addr;

// 리눅스 커널 bpf_attr 공용체(Union) 완벽 모사 (144바이트 패딩 방어)
#[repr(C)]
union BpfAttr {
    obj_get: BpfObjGetAttr,
    map_update: BpfMapUpdateAttr,
    _pad: [u8; 144], 
}

#[repr(C)]
#[derive(Clone, Copy)]
struct BpfObjGetAttr {
    pathname: u64,
    bpf_fd: u32,
    file_flags: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct BpfMapUpdateAttr {
    map_fd: u32,
    key: u64,
    value: u64,
    flags: u64,
}

// [리버스 엔지니어링 결과] Cilium v2 맵 24바이트 Key 구조체
#[derive(Clone, Copy)]
#[repr(C, packed)]
struct CiliumIpcacheKeyV2 {
    prefixlen: u32,       // 64 (32bit 패밀리 패딩 + 32bit IPv4 주소)
    pad_family: [u8; 4],  // [0, 0, 0, 1] (Family = 1: IPv4)
    ip_address: [u8; 16], // [10, 45, 1, 100, 0, 0, ... ]
}

// [리버스 엔지니어링 결과] Cilium v2 맵 24바이트 Value 구조체
#[derive(Clone, Copy)]
#[repr(C, packed)]
struct CiliumIpcacheValueV2 {
    identity: u32,        // 테넌트 ID (예: 5001)
    tunnel_endpoint: u32, 
    key_flags_cluster: [u8; 4], 
    pad1: u32,            
    pad2: u64,            
}

// x86_64 리눅스 BPF 시스템 콜 매직 넘버
const SYS_BPF: libc::c_long = 321;
const BPF_MAP_UPDATE_ELEM: libc::c_int = 2;
const BPF_OBJ_GET: libc::c_int = 7;

fn main() -> Result<(), std::io::Error> {
    let bpf_map_path = "/sys/fs/bpf/tc/globals/cilium_ipcache_v2"; 
    
    if !Path::new(bpf_map_path).exists() {
        println!("[Vantage-5G Error] Target v2 BPFFS path not found. Is Cilium running?");
        std::process::exit(1);
    }

    let c_path = CString::new(bpf_map_path).unwrap();
    
    // 1. SYS_BPF(OBJ_GET): 핀된 맵의 파일 디스크립터(FD) 획득
    let mut attr = BpfAttr { _pad: [0; 144] };
    attr.obj_get = BpfObjGetAttr {
        pathname: c_path.as_ptr() as u64,
        bpf_fd: 0,
        file_flags: 0,
    };

    let map_fd = unsafe {
        libc::syscall(
            SYS_BPF, BPF_OBJ_GET,
            &mut attr as *mut BpfAttr as *mut libc::c_void,
            std::mem::size_of::<BpfAttr>() as libc::c_int,
        )
    };

    if map_fd < 0 {
        println!("[Vantage-5G Error] Failed to get Map FD. Are you running as root?");
        std::process::exit(1);
    }
    
    // 2. 주입할 5G 단말 IP 및 식별자 세팅 (10.45.1.100 -> 5001)
    let target_ip = Ipv4Addr::new(10, 45, 1, 100);
    let mut ip_buf = [0u8; 16];
    ip_buf[0..4].copy_from_slice(&target_ip.octets());

    let key = CiliumIpcacheKeyV2 {
        prefixlen: 64,            
        pad_family: [0, 0, 0, 1], 
        ip_address: ip_buf,
    };

    let value = CiliumIpcacheValueV2 {
        identity: 5001,
        tunnel_endpoint: 0,
        key_flags_cluster: [0, 0, 0, 0],
        pad1: 0, pad2: 0,
    };

    // 3. SYS_BPF(MAP_UPDATE_ELEM): 커널 맵 영역에 록리스(Lock-less) 데이터 직접 강제 주입
    let mut update_attr = BpfAttr { _pad: [0; 144] };
    update_attr.map_update = BpfMapUpdateAttr {
        map_fd: map_fd as u32,
        key: &key as *const _ as u64,
        value: &value as *const _ as u64,
        flags: 0, 
    };

    let ret = unsafe {
        libc::syscall(
            SYS_BPF, BPF_MAP_UPDATE_ELEM,
            &mut update_attr as *mut BpfAttr as *mut libc::c_void,
            std::mem::size_of::<BpfAttr>() as libc::c_int,
        )
    };

    if ret != 0 {
        let errno = std::io::Error::last_os_error();
        println!("[Vantage-5G Error] Kernel rejected element update. Errno: {}", errno);
        std::process::exit(1);
    }

    println!("[Vantage-5G Control] CRITICAL: 5G Subscriber {} successfully mapped to Identity {} (24B Aligned)!", target_ip, value.identity);
    Ok(())
}
```

### 빌드 및 실전 집행 (커널 타격)
일반 권한으로 최적화 컴파일을 수행한 뒤, 생성된 바이너리만 최고 관리자 권한으로 기동합니다.

```
# 1. 프로젝트 디렉터리 내에서 릴리즈 최적화 빌드 수행
cd ~/vantage-5g
cargo build --release

# 2. Root 권한으로 커널 맵 직접 타격 실행
sudo ./target/release/vantage-5g
```

### 실증 및 교차 검증 (Cilium CLI)
데이터가 커널에 안착한 직후, K8s 클러스터 내부의 Cilium 데몬이 해당 데이터를 유효한 가입자로 인식했는지 최종 확인합니다.

```
# 1. Cilium 데몬 Pod 이름 추출
CILIUM_POD=$(sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')

# 2. 커널 테이블 파싱 결과 확인 (10.45.1.100이 5001번으로 매핑되었는지 확인)
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system $CILIUM_POD -- cilium bpf ipcache list | grep 10.45.1.100
```

성공 출력 예시: `10.45.1.100/32    identity=5001 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>`

