# vatage-5G

## Phase 1: eBPF-Cilium 제어 평면 연동 A to Z 플레이북

### Rust 컴파일러 및 빌드 툴체인 설치
순정 Ubuntu 24.04 환경에 시스템 프로그래밍을 위한 Rust 환경을 구축합니다.

```bash
# 1. Rust 공식 인스톨러 다운로드 및 설치 (설치 프롬프트에서 '1' 입력 후 Enter)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 2. 현재 터미널 세션에 Cargo 환경 변수 즉시 적용
source $HOME/.cargo/env

# 3. 설치 정상 완료 확인
cargo --version
```

### 프로젝트 디렉터리 생성 및 초기화
Vantage-5G 제어 평면 에이전트를 개발할 작업 공간을 구성합니다.

```bash
# 1. 프로젝트 최상위 디렉터리 생성 및 이동
mkdir -p ~/vantage-5G
cd ~/vantage-5G

# 2. 실행 가능한 바이너리 프로젝트로 초기화 (Cargo.toml 및 src/ 폴더 자동 생성)
cargo init --bin
```

### 프로젝트 의존성 명세 (Cargo.toml)
불안정한 eBPF 고수준 라이브러리를 배제하고, 리눅스 커널 시스템 콜 직결을 위한 libc 표준 라이브러리만 주입합니다.

`~/vantage-5G/Cargo.toml` 파일을 열어 아래 내용으로 완전히 덮어씁니다.

```toml
[package]
name = "vantage-5G"
version = "0.1.0"
edition = "2026"

[dependencies]
# 리눅스 BPF 커널 시스템 콜 직결을 위한 C-FFI 표준 라이브러리
libc = "0.2"
```

### 제어 평면(Control Plane) 커널 직결 소스코드 작성
Cilium v2 맵의 24B/24B 패딩 규격을 완벽하게 리버스 엔지니어링한 최종 무결성 코드입니다.

`~/vantage-5G/src/main.rs` 파일을 열어 아래 내용으로 완전히 덮어씁니다.

```rust
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

```bash
# 1. 프로젝트 디렉터리 내에서 릴리즈 최적화 빌드 수행
cd ~/vantage-5G
cargo build --release

# 2. Root 권한으로 커널 맵 직접 타격 실행
sudo ./target/release/vantage-5G
```

### 실증 및 교차 검증 (Cilium CLI)
데이터가 커널에 안착한 직후, K8s 클러스터 내부의 Cilium 데몬이 해당 데이터를 유효한 가입자로 인식했는지 최종 확인합니다.

```bash
# 1. Cilium 데몬 Pod 이름 추출
CILIUM_POD=$(sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')

# 2. 커널 테이블 파싱 결과 확인 (10.45.1.100이 5001번으로 매핑되었는지 확인)
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system $CILIUM_POD -- cilium bpf ipcache list | grep 10.45.1.100
```

성공 출력 예시: `10.45.1.100/32    identity=5001 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>`

## Phase 2: eBPF 데이터 평면 패킷 식별 실증 플레이북

### 아키텍처 목표 및 달성 성과
목표: Phase 1에서 제어 평면을 통해 커널 맵에 주입한 가입자 정보(`10.45.1.100` -> `5001`)를, 실제 데이터 평면(Data Plane)에서 흐르는 패킷을 가로채어 커널 레벨에서 즉각 식별하고 판독하는 것.

성과: 커널의 맵 검증 규격, ARP 드롭, 로컬 라우팅(Martian Packet) 차단, 그리고 Cilium GC의 간섭을 모두 뚫어내고, `lo` 인터페이스의 Egress 훅에서 대상 패킷을 100%의 정확도로 저격(Sniping)하는 eBPF C 코드를 완성함.

### Breakthroughs
이 플레이북에서 가장 가치 있는 정보는 우리가 마주했던 커널 스택의 4대 함정과 그 타파 방법입니다.

- __Parameter Mismatch (맵 규격 충돌):__ Cilium은 데이터 평면의 무결성을 위해 맵에 flags: 129 (`BPF_F_NO_PREALLOC` | `BPF_F_RDONLY_PROG`)라는 숨겨진 읽기 전용(Read-Only) 락을 걸어둡니다. 이를 C 코드에 정확히 100% 동기화하여 해결했습니다.
- __네트워크 방향성과 IP 추출 (`saddr` vs `daddr`):__ 호스트 로컬에서 핑을 쏠 때는 패킷의 출발지가 아닌 목적지(`daddr`)를 뜯어봐야 맵에 기록된 타겟 IP(`10.45.1.100`)와 일치한다는 점을 교정했습니다.
- __가상 인터페이스 조기 폐기 (Dummy Drop) & Martian 라우팅:__ 더미 인터페이스의 태생적 패킷 증발 현상을 막기 위해 사냥터를 루프백(`lo`)으로 옮기고, `10.45.1.100/32` 주소를 `lo` 인터페이스에 로컬 바인딩하여 커널의 라우팅 차단을 완벽히 우회했습니다.
- __Cilium GC 간섭 방어 (Rapid Fire):__ 제어 평면 데이터가 Cilium의 가비지 컬렉터에 의해 삭제되기 전에 실증을 끝내기 위해, 데이터를 꽂자마자 패킷을 사격하는 '동시 타격 전술'을 수립했습니다.

### 최종 무결성 산출물 (Golden Code Reference)
이 코드는 어떠한 노이즈도 없이, 오직 우리가 지정한 `5001`번 테넌트의 패킷만 커널 로그에 출력하는 완벽한 스나이퍼 모드(Sniper Mode) 데이터 평면 코드입니다.

`vantage_datapath.c`
```c
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// [핵심] Cilium 맵 규격 완벽 동기화 (Flags 129)
#ifndef BPF_F_NO_PREALLOC
#define BPF_F_NO_PREALLOC 1
#endif
#ifndef BPF_F_RDONLY_PROG
#define BPF_F_RDONLY_PROG 128
#endif
#ifndef LIBBPF_PIN_BY_NAME
#define LIBBPF_PIN_BY_NAME 1
#endif

struct cilium_ipcache_key {
    __u32 prefixlen;
    __u8  pad_family[4];
    __u8  ip_address[16];
} __attribute__((packed));

struct cilium_ipcache_value {
    __u32 identity;
    __u32 tunnel_endpoint;
    __u8  key_flags_cluster[4];
    __u32 pad1;
    __u64 pad2;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __uint(key_size, sizeof(struct cilium_ipcache_key));
    __uint(value_size, sizeof(struct cilium_ipcache_value));
    __uint(max_entries, 512000);
    __uint(map_flags, BPF_F_NO_PREALLOC | BPF_F_RDONLY_PROG); // Flags 129
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} cilium_ipcache_v2 SEC(".maps");

SEC("tc_ingress")
int vantage_tc_filter(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(ETH_P_IP)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;

    // 맵 룩업 준비 (목적지 IP 기준)
    struct cilium_ipcache_key key = {};
    key.prefixlen = 64;
    key.pad_family[3] = 1;
    __builtin_memcpy(&key.ip_address, &ip->daddr, sizeof(ip->daddr));

    struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_v2, &key);
    
    // [스나이퍼 샷] 5001번 테넌트 식별 시 즉각 로깅
    if (val && val->identity == 5001) {
        bpf_printk("[Vantage-5G] CRITICAL HIT! Tenant 5001 Packet Detected! IP: %pI4\n", &ip->daddr);
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
```

### 실전 가동 및 검증 파이프라인 (Rapid Fire Sequence)
향후 시스템을 재부팅하거나 완전히 새로운 환경에서 이 코드를 실증할 때 사용하는 표준 명령 셋입니다.

#### Step 1: 환경 정렬 및 eBPF 컴파일/부착
```bash
# 1. 대상 IP를 루프백 인터페이스에 로컬 바인딩 (Martian Drop 우회)
sudo ip addr add 10.45.1.100/32 dev lo

# 2. C 코드 컴파일 및 루프백 인터페이스 부착
sudo clang -O2 -g -target bpf -c vantage_datapath.c -o vantage_datapath.o
sudo tc qdisc del dev lo clsact 2>/dev/null
sudo tc qdisc add dev lo clsact
sudo tc filter add dev lo egress bpf da obj vantage_datapath.o sec tc_ingress

# 3. 커널 로깅 활성화
echo 1 | sudo tee /sys/kernel/debug/tracing/tracing_on
```

#### Step 2: 실증 작전 집행 (3-Terminal 동시 진행)
Cilium GC가 데이터를 지우기 전에 꽂고 쏘는 쾌속 콤보입니다.

- [창1: 모니터링] `sudo cat /sys/kernel/debug/tracing/trace_pipe`
- [창 2: 제어 평면 맵 주입] `sudo ./target/release/vantage-5G`
- [창 3: 데이터 평면 패킷 사격] `ping -c 3 10.45.1.100` (창 2 실행 직후 즉시 엔터)

성공 출력 예시: `bpf_trace_printk: [Vantage-5G] CRITICAL HIT! Tenant 5001 Packet Detected! IP: 10.45.1.100`

## Phase 3: eBPF-EDT QoS 인포스먼트 실증 플레이북

### 아키텍처 배경 및 기술적 혁신 (EDT vs HTB)
레거시 리눅스 커널의 대역폭 제어 방식(HTB 등)은 패킷을 중간 큐(Queue)에 가두고 락(Lock)을 걸어 스케줄링했기 때문에 심각한 CPU 오버헤드와 버퍼블로트(Bufferbloat)를 유발했습니다.

Vantage-5G 아키텍처가 채택한 EDT(Earliest Departure Time) 모델은 패킷이 eBPF 훅을 통과하는 순간, 패킷의 크기와 목표 대역폭을 계산하여 "이 패킷이 네트워크 카드를 빠져나가야 할 미래의 정확한 나노초 타임스탬프(`skb->tstamp`)"를 각인합니다.
최하단의 록리스 FQ(Fair Queueing) 스케줄러는 이 타임스탬프에 도달할 때까지 패킷을 메모리 상에서 정밀하게 지연 방출(Pacing)함으로써, 제로 오버헤드 수준의 선형적 네트워크 슬라이싱을 구현합니다.

### 핵심 메커니즘 및 지연 시간 방정식
목표 대역폭을 10Mbps ($10,000,000\text{ bps}$)로 제한하기 위해 패킷의 길이($L$, Bytes)에 따라 가해지는 커널 나노초 지연($\Delta t$) 계산 식은 다음과 같습니다.

$$\Delta t = L \times 8 \times \frac{10^9\text{ ns}}{10,000,000\text{ bps}} = L \times 800\text{ ns}$$

이전 패킷의 출발 예약 시간(`last_tstamp`)을 커널 내부에 상태 저장(Stateful)하기 위해 새로운 BPF Hash Map을 추가로 연동했습니다.

### 최종 무결성 산출물 (Golden Code Reference)
`vantage_edt.c`

```c
// vantage_edt.c - Vantage-5G eBPF-EDT Pacing Core
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef BPF_F_NO_PREALLOC
#define BPF_F_NO_PREALLOC 1
#endif
#ifndef BPF_F_RDONLY_PROG
#define BPF_F_RDONLY_PROG 128
#endif
#ifndef LIBBPF_PIN_BY_NAME
#define LIBBPF_PIN_BY_NAME 1
#endif

// Phase 2: Cilium v2 가입자 식별 구조체 및 맵 정의
struct cilium_ipcache_key {
    __u32 prefixlen;
    __u8  pad_family[4];
    __u8  ip_address[16];
} __attribute__((packed));

struct cilium_ipcache_value {
    __u32 identity;
    __u32 tunnel_endpoint;
    __u8  key_flags_cluster[4];
    __u32 pad1;
    __u64 pad2;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __uint(key_size, sizeof(struct cilium_ipcache_key));
    __uint(value_size, sizeof(struct cilium_ipcache_value));
    __uint(max_entries, 512000);
    __uint(map_flags, BPF_F_NO_PREALLOC | BPF_F_RDONLY_PROG); // Flags 129
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} cilium_ipcache_v2 SEC(".maps");

// Phase 3: EDT 상태 저장용 맵 선언 (테넌트별 마지막 전송 타임스탬프 기록)
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);   // Identity (5001)
    __type(value, __u64); // Last Departure Timestamp (ns)
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tenant_tstamp_map SEC(".maps");

SEC("tc_egress")
int vantage_edt_pacing(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(ETH_P_IP)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;

    struct cilium_ipcache_key key = {};
    key.prefixlen = 64;
    key.pad_family[3] = 1;
    __builtin_memcpy(&key.ip_address, &ip->daddr, sizeof(ip->daddr));

    struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_v2, &key);
    
    // 🎯 5001번 테넌트 식별 시 정밀 EDT 통제 개입
    if (val && val->identity == 5001) {
        __u32 tenant_id = val->identity;
        __u64 now = bpf_ktime_get_ns();
        __u64 next_tstamp = now;
        __u64 *last_tstamp;

        // 10Mbps 스로틀링을 위한 나노초 딜레이 계산 (패킷 Byte 길이 * 800ns)
        __u64 delay_ns = (__u64)skb->len * 800;

        last_tstamp = bpf_map_lookup_elem(&tenant_tstamp_map, &tenant_id);
        if (last_tstamp) {
            if (*last_tstamp > now) {
                next_tstamp = *last_tstamp;
            }
        } else {
            bpf_map_update_elem(&tenant_tstamp_map, &tenant_id, &now, BPF_ANY);
            last_tstamp = bpf_map_lookup_elem(&tenant_tstamp_map, &tenant_id);
            if (!last_tstamp) return TC_ACT_OK;
        }

        next_tstamp += delay_ns;
        *last_tstamp = next_tstamp;

        // 🎯 패킷 메타데이터에 커널 FQ 스케줄러 연동용 미래 시간 각인
        skb->tstamp = next_tstamp;

        bpf_printk("[Vantage-5G EDT] T:%d | Len:%d | Delay:%llu ns\n", tenant_id, skb->len, delay_ns);
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
```

### 인프라 얼라인먼트 및 실행 명령

#### Step 1: 커널 FQ 및 전용 clsact 큐디스크 적재

```bash
# 1. 소스코드 컴파일
sudo clang -O2 -g -target bpf -c vantage_edt.c -o vantage_edt.o

# 2. 루프백 최상단 큐디스크를 fq(Fair Queueing) 스케줄러로 전격 교체 (EDT 활성화의 핵심)
sudo tc qdisc replace dev lo root fq

# 3. 기존 clsact 안전하게 초기화 후 재적재 (Exclusivity Flag 충돌 방지)
sudo tc qdisc del dev lo clsact 2>/dev/null
sudo tc qdisc add dev lo clsact

# 4. 컴파일된 EDT 바이트코드를 lo 인터페이스 Egress 파이프라인에 바인딩
sudo tc filter add dev lo egress bpf da obj vantage_edt.o sec tc_egress
```

#### Step 2: 실전 3중 교차 검증 (Rapid Flood Combo)
Cilium GC 가비지 컬렉터 루프가 돌기 전, 제어 평면 데이터 주입과 동시에 임계점을 타격하는 폭우 사격 검증 시퀀스입니다.

- [터미널 1 - 커널 트레이싱]
```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe
```
- [터미널 2 - Rust 제어 평면 주입]
```bash
sudo ./target/release/vantage-5G
```
- [터미널 3 - Flood 사격 집행] (터미널 2 성공 즉시 1초 내 실행)
```bash
sudo ping -f -s 1400 -c 1000 10.45.1.100
```

성공 데이터 지표: `1000 received, 0% packet loss, time 4515ms` (물리적 대역폭 억제 완료 및 록리스 평탄화 증명)

## Phase 4: 동적 대역폭 자율 제어(Dynamic QoS Control) 플레이북

### 아키텍처 목표 및 달성 성과
목표: 5G 단말의 트래픽을 제어하는 eBPF 데이터 평면을 재컴파일이나 무중단(Zero-Downtime) 상태로 유지하면서, 외부의 관리 명령에 따라 특정 테넌트의 대역폭을 실시간으로 조절하거나 차단하는 것.

성과: 커널 공간에 '동적 대역폭 설정 맵(`tenant_bw_map`)'을 신설하고, bpftool 같은 외부 유틸리티 없이 리눅스 커널 시스템 콜(`libbpf-sys`)을 직접 타격하는 Rust 기반의 전용 제어기(`vantage-cli`)를 완벽하게 구축함.

### Breakthroughs
- __킬 스위치 (Kill Switch):__ 맵에서 읽어온 대상 대역폭 값이 `0`일 경우, 커널 스케줄러로 패킷을 넘기지 않고 최하단에서 즉시 폐기(`TC_ACT_SHOT`)하는 강력한 하드웨어 격리 로직을 구현했습니다.
- __동적 지연 시간(Delay) 연산 엔진:__ 상수였던 지연 시간을 런타임 변수($R_{dynamic}$)를 받아서 처리하는 동적 방정식으로 진화시켰습니다.
$$\Delta t = \frac{L \times 8 \times 10^9\text{ ns}}{R_{dynamic}}$$
- __Zero-Overhead 메모리 제어 (Rust Native Syscall):__ 추상화된 고수준 라이브러리(`libbpf-rs`)의 한계를 버리고, `libbpf-sys`를 도입하여 커널에 핀(Pin)된 맵의 파일 디스크립터(fd)를 직접 획득, C 언어 수준의 속도로 메모리를 조작하는 완벽한 CLI를 구현했습니다.

### 최종 무결성 산출물 (Golden Code Reference)
1) 데이터 평면: `vantage_dynamic_edt.c` (eBPF C)
특정 테넌트 번호(5001) 하드코딩을 제거하고, 범용적인 동적 제어를 수행하는 최종 엔진입니다.

```c
// (헤더 및 기존 cilium_ipcache_v2, tenant_tstamp_map 선언부 생략...)

// [Phase 4: 동적 대역폭 설정 맵]
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);   // Identity (Tenant ID)
    __type(value, __u64); // Target Bandwidth in bps
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tenant_bw_map SEC(".maps");

SEC("tc_egress")
int vantage_dynamic_pacing(struct __sk_buff *skb) {
    // (이더넷/IP 헤더 검증 생략...)

    struct cilium_ipcache_key key = {};
    key.prefixlen = 64;
    key.pad_family[3] = 1;
    __builtin_memcpy(&key.ip_address, &ip->daddr, sizeof(ip->daddr));

    struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_v2, &key);
    
    // 식별된 모든 K8s 테넌트에 대해 통제 로직 수행
    if (val) {
        __u32 tenant_id = val->identity;
        
        // 해당 테넌트가 대역폭 통제 맵에 존재하는지 확인
        __u64 *bw_ptr = bpf_map_lookup_elem(&tenant_bw_map, &tenant_id);
        if (bw_ptr) {
            if (*bw_ptr == 0) return TC_ACT_SHOT; // 🛑 0Mbps 킬 스위치 (즉각 폐기)

            __u64 target_bps = *bw_ptr;
            __u64 delay_ns = ((__u64)skb->len * 8000000000ULL) / target_bps; // 🚀 동적 딜레이 계산

            __u64 now = bpf_ktime_get_ns();
            __u64 next_tstamp = now;
            __u64 *last_tstamp = bpf_map_lookup_elem(&tenant_tstamp_map, &tenant_id);

            if (last_tstamp) {
                if (*last_tstamp > now) next_tstamp = *last_tstamp;
            } else {
                bpf_map_update_elem(&tenant_tstamp_map, &tenant_id, &now, BPF_ANY);
                last_tstamp = bpf_map_lookup_elem(&tenant_tstamp_map, &tenant_id);
                if (!last_tstamp) return TC_ACT_OK;
            }

            next_tstamp += delay_ns;
            *last_tstamp = next_tstamp;
            skb->tstamp = next_tstamp; // FQ 스케줄러를 위한 타임스탬프 각인
        }
    }
    return TC_ACT_OK;
}
char _license[] SEC("license") = "GPL";
```

2) 제어 평면: `src/main.rs` (Rust CLI)
관리자가 직관적으로 시스템을 통제할 수 있도록 `libbpf-sys`를 래핑한 CLI 도구입니다.

```rust
use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use std::ffi::CString;

#[derive(Parser)]
#[command(name = "vantage-cli", about = "Controls 5G Tenant Bandwidth via Pinned eBPF Maps")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Set { #[arg(short, long)] tenant: u32, #[arg(short, long)] bw_mbps: u64 },
    Reset { #[arg(short, long)] tenant: u32 },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let map_path = CString::new("/sys/fs/bpf/tc/globals/tenant_bw_map")?;
    let fd = unsafe { libbpf_sys::bpf_obj_get(map_path.as_ptr()) };
    
    if fd < 0 { bail!("Failed to open pinned map."); }

    match &cli.command {
        Commands::Set { tenant, bw_mbps } => {
            let target_bps: u64 = bw_mbps * 1_000_000;
            let key = tenant.to_ne_bytes();
            let value = target_bps.to_ne_bytes();

            let ret = unsafe {
                libbpf_sys::bpf_map_update_elem(fd, key.as_ptr() as *const _, value.as_ptr() as *const _, libbpf_sys::BPF_ANY.into())
            };
            if ret != 0 { bail!("Update failed."); }
            println!("[Vantage-5G] Tenant {} bandwidth set to {} Mbps.", tenant, bw_mbps);
        }
        Commands::Reset { tenant } => {
            let key = tenant.to_ne_bytes();
            unsafe { libbpf_sys::bpf_map_delete_elem(fd, key.as_ptr() as *const _) };
            println!("[Vantage-5G] Tenant {} policy removed.", tenant);
        }
    }
    Ok(())
}
```
```bash
#파이프라인 재가동
cargo build --release

#글로벌 환경에서 편하게 쓰기 위해 /usr/local/bin으로 복사
sudo cp target/release/vantage-5G /usr/local/bin/vantage-cli
```

### 테스트
이제 bpftool이 아닌 Vantage CLI로 커널을 통제합니다.

- [터미널1]
```bash
# 1. 대역폭 10Mbps로 조이기 (지연 시간 1.15ms 확인)
sudo vantage-cli set --tenant 5001 --bw-mbps 10

# 2. 대역폭 100Mbps로 전격 개방 (지연 시간 0.11ms로 급감 확인)
sudo vantage-cli set --tenant 5001 --bw-mbps 100

# 3. 이상 감지: 킬 스위치 발동 (trace 로그 멈춤 및 ping 100% loss 체감)
sudo vantage-cli set --tenant 5001 --bw-mbps 0

# 4. 차단 해제 (원상 복구)
sudo vantage-cli reset --tenant 5001
```
- [터미널2]
```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe
```
- [터미널3]
```bash
ping -i 0.1 -s 1400 10.45.1.100
```


### 실전 운영 파이프라인 (Ops Pipeline)
향후 노드 재부팅이나 새로운 인프라 전개 시, 다음 명령어를 통해 데이터 평면을 부착하고 CLI로 통제합니다.

```bash
# 1. 인프라 준비 및 데이터 평면 컴파일/부착
sudo tc qdisc replace dev lo root fq
sudo clang -O2 -g -target bpf -c vantage_dynamic_edt.c -o vantage_dynamic_edt.o
sudo tc filter replace dev lo egress bpf da obj vantage_dynamic_edt.o sec tc_egress

# 2. Rust CLI 빌드 및 글로벌 배포
cargo build --release
sudo cp target/release/vantage-5G /usr/local/bin/vantage-cli

# 3. 실시간 트래픽 제어 (Run-time Commands)
sudo vantage-cli set --tenant 5001 --bw-mbps 100  # 100Mbps 할당
sudo vantage-cli set --tenant 5001 --bw-mbps 0    # 격리(Kill Switch)
sudo vantage-cli reset --tenant 5001              # 정책 해제
```
