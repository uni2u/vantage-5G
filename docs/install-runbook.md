# L4 설치 런북 — 물리 Ubuntu 서버 (22.04 / 24.04)

- 대상 커밋: `main`의 `d80ee7b` 이후. 아래 `<COMMIT>`을 실제로 받은 해시로 바꾼다. `d80ee7b`에는 4.2의 판정 스크립트 `counter_verdict.py`가 들어 있다(`311ee1c`에는 없음).
- 로컬 근거: 로컬 L1/L2 실행은 `ddc00c8` + 미커밋 변경 상태의 작업 트리에서 했다(당시 결과의 `commit.txt`는 HEAD만 기록해 `ddc00c8`로 남아 있다). 그 미커밋 변경이 이후 `311ee1c`로 커밋되었고, `311ee1c`와 `d80ee7b`의 제품 코드(`*.c`, `src/`, `setup.sh`, `detach.sh`, `Makefile`)는 같다(`git diff --stat 311ee1c d80ee7b`). 결과: L1 Docker와 L2 VirtualBox(Ubuntu 22.04)에서 전 단계 PASS. L2 24.04는 기능 단계 전부 PASS, 처리량은 호스트 부하로 판정 보류. 상세 보고서는 개발자 로컬 기록이며 저장소에는 없다.
- 형식: 각 단계는 **명령 / 기대 결과 / 실패 시** 순서다.
- 기호(예시 값은 README §3.2와 같다. 실제 값으로 바꾼다):

  | 기호 | 예시 | 뜻 |
  |---|---|---|
  | `<IF>` | `enp1s0` | 서비스 노드의 N6 쪽 NIC (`setup.sh`에 넘기는 것) |
  | `<SVC>` | `192.168.100.20` | 서비스 노드의 N6 IP |
  | `<SVC_NET>` | `192.168.100.0/24` | UPF 호스트와 서비스 노드가 공유하는 N6 대역 |
  | `<UPF_N6_IP>` | `192.168.100.10` | UPF 호스트의 N6 IP |
  | `<UE_NET>` | `10.45.0.0/16` | UE 주소 풀 (Open5GS 레퍼런스 설치의 `ogstun` 대역) |
  | `<UE_A>`, `<UE_B>` | `10.45.1.23`, `10.45.1.24` | UE 2대의 IP. **4.0에서 실제 값(`uesimtunN` 주소)을 확인해 바꾼다** |
- 실행 위치: 단계마다 [서비스 노드] / [UPF 호스트] / [UE 호스트](UERANSIM)를 표시했다. 표시가 없으면 서비스 노드다.
- 결과 수집: 단계마다 출력을 `~/vt-l4/<단계>.txt`로 저장(`… 2>&1 | tee ~/vt-l4/<단계>.txt`)하고, 끝나면 디렉토리째 가져온다(7장). 가져온 결과는 개발 쪽에서 분석한다.

```bash
mkdir -p ~/vt-l4
```

## 1. 사전 조건

### 1.1 OS, 커널, BTF
- 명령: `lsb_release -ds; uname -r; ls -l /sys/kernel/btf/vmlinux; ip -V`
- 기대: Ubuntu 22.04.x 또는 24.04.x, 커널 5.15 이상, `/sys/kernel/btf/vmlinux` 존재.
- 실패 시: BTF가 없으면 중단한다(BTF 없는 커스텀 커널은 지원 범위 밖).

### 1.1a CPU 수 (V20, D25)
- 명령: `nproc; lscpu | grep -E '^CPU\(s\)|NUMA node\(s\)'`
- 기대: 기록한다. `nproc` ≤ 128이면 진행. 커널 6.16 이상이면 CPU 수와 무관하게 진행.
- 실패 시(경고, 중단 아님): `nproc` > 128 이고 커널 < 6.16(22.04 5.15, 24.04 6.8)이면 LRU 상태 맵(16384)이 CPU별 로컬 free list(CPU당 128)로 소진되어 UE가 몇 개뿐이어도 활성 UE의 상태가 퇴출될 수 있다(README §3.1). 이 조건을 보고서에 명시하고 6장 X13을 반드시 관찰한다.

### 1.2 패키지 (README §3.1) — X12
- 명령:
  ```bash
  sudo apt-get update
  sudo apt-get install -y build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config \
      linux-tools-common "linux-tools-$(uname -r)" iproute2 iperf3 tcpdump ethtool
  bpftool version
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 이후 새 셸 또는 . ~/.cargo/env
  ```
- 기대: apt rc=0. `bpftool version`이 버전을 출력한다("WARNING: bpftool not found for kernel …"이 아님).
- 실패 시: `linux-tools-$(uname -r)` 후보가 없으면(HWE·커스텀 커널) `apt-cache search linux-tools | grep $(uname -r)`로 flavour 패키지를 찾는다. `bpftool` 패키지를 따로 설치하려 하지 않는다(22.04/24.04 모두 설치 후보 없음, 로컬 확인).

### 1.3 소스
- 명령: `git clone https://github.com/uni2u/vantage-5g.git && cd vantage-5g && git checkout <COMMIT> && git log -1 --oneline && ls -l setup.sh detach.sh`
- 기대: 해시가 일치하고 두 스크립트가 `-rwxr-xr-x`이다(X1/D18).
- 실패 시: 실행 권한이 없으면 중단하고 보고한다(`bash setup.sh`로 우회하지 않는다).

### 1.4 [UPF 호스트] 서비스 대역 NAT 제외 (X5, README §3.2 (1))
Open5GS quickstart의 MASQUERADE 규칙이 남아 있으면 모든 UE가 N6에서 `<UPF_N6_IP>`로 보여 per-UE 정책이 하나도 맞지 않는다.
- 명령:
  ```bash
  sudo iptables -t nat -S POSTROUTING | tee ~/vt-l4/1.4-nat-before.txt
  # 예: -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
  # 방법 A — 예외를 맨 앞에 삽입 (nat 테이블은 첫 종단 규칙에서 멈추므로 ACCEPT = 주소 변환 안 함)
  sudo iptables -t nat -I POSTROUTING 1 -s <UE_NET> -d <SVC_NET> -j ACCEPT
  # 방법 B — 규칙 자체를 서비스 대역 제외로 교체 (A 대신)
  #   sudo iptables -t nat -D POSTROUTING -s <UE_NET> ! -o ogstun -j MASQUERADE
  #   sudo iptables -t nat -A POSTROUTING -s <UE_NET> ! -d <SVC_NET> ! -o ogstun -j MASQUERADE
  sudo iptables -t nat -L POSTROUTING -n -v --line-numbers | tee ~/vt-l4/1.4-nat-after.txt
  ```
- 기대: 방법 A면 `ACCEPT … <UE_NET> <SVC_NET>` 줄이 `MASQUERADE` 줄보다 위(번호가 작음)에 있다. 방법 B면 MASQUERADE 줄에 `!<SVC_NET>` 목적지 조건이 있다.
- 기존 연결: 예외는 **새 연결**에만 적용된다. 이미 NAT된 연결은 conntrack 항목이 남아(established TCP는 며칠) 계속 `<UPF_N6_IP>`로 보인다. UE 세션을 다시 시작하거나 `sudo apt-get install -y conntrack && sudo conntrack -D -s <UE_NET>`로 지운다(지울 항목이 없으면 `0 flow entries have been deleted`와 rc=1, 정상).
- 실패 시: 규칙이 `iptables`에 안 보이면 `sudo nft list ruleset | grep -n -B3 masquerade`로 nftables 쪽을 확인하고 같은 의미의 예외를 넣는다. 코어를 직접 바꿀 수 없으면 코어 관리자에게 이 규칙을 요청하고 1.7까지 진행하지 않는다.
- 영구화는 1.5까지 끝낸 뒤 **1.5a에서 한 번에** 한다(여기서 저장하지 않는다).

### 1.5 [UPF 호스트] IP 포워딩 (README §3.2 (2))
- 명령:
  ```bash
  sysctl net.ipv4.ip_forward
  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-ue-forward.conf && sudo sysctl --system >/dev/null
  sysctl net.ipv4.ip_forward
  sudo iptables -S FORWARD | head -1
  ip route get <SVC>
  ```
- 기대: `net.ipv4.ip_forward = 1`. FORWARD 정책이 `-P FORWARD ACCEPT`. `ip route get <SVC>`가 N6 NIC로 나간다.
- 실패 시: `-P FORWARD DROP`(Docker 설치 시 흔함)이면 `sudo iptables -I FORWARD -s <UE_NET> -d <SVC_NET> -j ACCEPT; sudo iptables -I FORWARD -s <SVC_NET> -d <UE_NET> -j ACCEPT`를 넣는다. `<SVC>`로 가는 경로가 없으면 UPF 호스트에 `<SVC_NET>` 경로를 추가한다.

### 1.5a [UPF 호스트] 1.4·1.5 규칙 영구화 (README §3.2 "Making (1) and (2) survive a reboot")
`sysctl.d` 파일은 이미 영구적이다. iptables 규칙은 재부팅하면 사라지므로 1.4와 1.5를 **모두** 마친 뒤 한 번 저장한다.
- 명령: `sudo ufw status | tee ~/vt-l4/1.5a-ufw.txt`
  - **ufw가 active이면 (A)** — `iptables-persistent`를 설치하지 않는다. **Ubuntu 24.04에서 `apt-get install iptables-persistent`는 ufw를 묻지 않고 제거한다**(ufw 0.36.2의 `Breaks: iptables-persistent, netfilter-persistent`. 22.04의 ufw 0.36.1에는 이 충돌이 없다). 대신 `/etc/ufw/before.rules` 맨 위(`*filter` 줄 앞)에 아래 `*nat` 블록을 넣고(이미 `*nat` 블록이 있으면 그 안의 MASQUERADE 줄 위에 ACCEPT 줄만 추가), 포워딩을 허용한 뒤 reload한다.
    ```
    *nat
    :POSTROUTING ACCEPT [0:0]
    -A POSTROUTING -s <UE_NET> -d <SVC_NET> -j ACCEPT
    -A POSTROUTING -s <UE_NET> ! -o ogstun -j MASQUERADE
    COMMIT
    ```
    ```bash
    sudo ufw route allow from <UE_NET> to <SVC_NET>
    sudo ufw route allow from <SVC_NET> to <UE_NET>
    sudo ufw reload
    sudo iptables -t nat -L POSTROUTING -n --line-numbers | tee ~/vt-l4/1.5a-nat.txt
    ```
  - **ufw를 쓰지 않으면 (B)** — 제거 대상을 먼저 확인하고 설치·저장한다.
    ```bash
    sudo apt-get -s install iptables-persistent | grep -A3 REMOVED | tee ~/vt-l4/1.5a-apt-dryrun.txt
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    sudo netfilter-persistent save
    ```
- 기대: (A) `ACCEPT` 줄이 `MASQUERADE` 줄보다 위에 있고 `ufw status`가 계속 active. (B) dry run 출력이 비어 있고(제거 대상 없음) `/etc/iptables/rules.v4`에 1.4의 nat 예외와 1.5의 FORWARD 규칙이 들어 있다(`sudo grep -E 'ACCEPT|MASQUERADE' /etc/iptables/rules.v4`).
- 실패 시: (B)의 dry run에 `ufw`가 REMOVED로 나오면 설치하지 말고 (A)로 간다(ufw가 필요 없을 때만 그대로 진행). `DEBIAN_FRONTEND` 없이 설치하면 `-y`여도 debconf 대화상자("Save current IPv4 rules?")에서 멈춘다. 어느 답이든 이어서 `netfilter-persistent save`를 실행하면 된다. 가능하면 재부팅 후 1.4 `-L` 출력과 1.5 `sysctl`을 다시 확인한다(VERIFY-L4).

### 1.6 [서비스 노드] UE 대역 귀환 경로 (README §3.2 (3))
DL 응답이 Vantage가 붙은 `<IF>`로 나가야 TX 페이서와 killswitch가 적용된다(tc egress 훅은 그 NIC에만 있다).
- 명령:
  ```bash
  ip route get 10.45.0.2 | tee ~/vt-l4/1.6-route-before.txt
  sudo ip route add <UE_NET> via <UPF_N6_IP> dev <IF>
  ip route get 10.45.0.2 | tee ~/vt-l4/1.6-route-after.txt
  ```
- 기대: `10.45.0.2 via <UPF_N6_IP> dev <IF> …`. (기본 경로가 이미 `<UPF_N6_IP>`·`<IF>`이면 `ip route add`는 필요 없다.)
- 영구화(netplan): 기존 `/etc/netplan/` 파일을 **덮어쓰지 않는다**(DHCP·게이트웨이·DNS·다른 인터페이스 설정이 사라진다). 경로만 담은 별도 drop-in 파일을 만든다. netplan은 `/etc/netplan/`의 파일을 이름순으로 병합한다. `enp1s0` 자리에는 기존 파일이 N6 NIC에 쓰는 것과 같은 키를 쓴다.
  ```bash
  printf '%s\n' 'network:' '  version: 2' '  ethernets:' '    enp1s0:' '      routes:' \
      '        - to: 10.45.0.0/16' '          via: 192.168.100.10' \
      | sudo tee /etc/netplan/90-vantage-ue-route.yaml
  sudo chmod 600 /etc/netplan/90-vantage-ue-route.yaml
  sudo netplan get ethernets.enp1s0 | tee ~/vt-l4/1.6-netplan-get.txt
  sudo netplan try
  ip route show <UE_NET>
  ```
  기존 파일에 그 인터페이스의 `routes:` 목록이 이미 있으면 drop-in을 쓰지 말고 그 목록에 `- to: … via: …` 항목을 추가한다(뒤 파일의 같은 키는 덧붙지 않고 대체한다).
- 기대: `netplan get` 출력에 기존 주소(또는 `dhcp4`)와 새 경로가 함께 있다. `netplan try`에서 시간 안에 Enter를 누르면 그대로 적용된다(별도 `netplan apply` 불필요). `ip route show <UE_NET>`이 `via <UPF_N6_IP> dev <IF>`.
- 실패 시: `RTNETLINK answers: File exists`면 이미 경로가 있다 — `ip route show <UE_NET>`의 `via`/`dev`가 맞는지 보고, 다르면 `sudo ip route replace <UE_NET> via <UPF_N6_IP> dev <IF>`. `netplan get`에 기존 주소가 없으면 키 이름이 다른 것이다. `netplan try`가 되돌려지면(시간 초과, SSH 끊김) **`netplan apply`를 실행하지 말고** 파일을 먼저 고친다.

### 1.7 N6에서 UE IP가 보이는가 (X5, Vantage 설치 전 종단 확인)
1.4~1.6을 마친 뒤 확인한다. UE 주소와 인터페이스(`uesimtunN`)는 4.0의 명령을 먼저 실행해 확인한다.
- 명령: [UE 호스트] `ping -I uesimtun0 -c 5 <SVC>` 를 보내는 동안 [서비스 노드] `sudo tcpdump -ni <IF> net <UE_NET> -c 10 | tee ~/vt-l4/1.7-tcpdump.txt`
- 기대: `IP <UE_A> > <SVC>: ICMP echo request`와 `IP <SVC> > <UE_A>: ICMP echo reply`가 **둘 다** `<IF>`에서 보이고, UE 쪽 ping이 응답을 받는다.
- 실패 시: 출발지가 `<UPF_N6_IP>`만 보이면 **중단**하고 1.4(NAT)로 돌아간다 — 이 상태에서는 per-UE 정책이 걸리지 않는다. request만 보이고 reply가 `<IF>`로 나가지 않으면 1.6. 아무것도 안 보이면 1.5와 UE의 PDU 세션(4.0)을 확인한다. UE 호스트에서 `-I uesimtun0` 없이 ping하면 5G 경로를 타지 않으므로 이 확인에 쓰지 않는다.

### 1.8 NIC 정보 기록 (X2/X7/X8)
- 명령: `ethtool -i <IF>; ethtool -l <IF>; tc qdisc show dev <IF>; ip -d link show dev <IF>; ethtool -k <IF> | grep -E 'generic-receive|large-receive'; ip -d link show dev <IF> | grep -oE 'gro_max_size [0-9]+|gro_ipv4_max_size [0-9]+'`
- 기대: 드라이버명, 큐 수, root qdisc(`mq`일 수 있음)를 기록한다. 이미 붙은 `prog/xdp`나 egress 필터가 없어야 한다. `gro_max_size`/`gro_ipv4_max_size`는 65536 이하여야 한다(X15, BIG TCP 비활성).
- 실패 시: 다른 도구의 XDP/tc가 붙어 있으면 그 소유자와 먼저 조율한다(setup.sh가 exit 3으로 거부함). gro 값이 65536보다 크면 기록하고 계속 진행한다. UL에서 큰 프레임 영구 드롭이 의심되면 보고한다.

## 2. 업그레이드인 경우 (이전 버전이 이 서버에서 돌고 있었다면)

맵 3개(`rx_state_map`, `tx_tstamp_map`, `ue_stats_map`)가 HASH 1024에서 LRU_HASH 16384로 바뀌었다(3차 테스트 빌드를 올린 서버는 LRU_HASH 1024 → 16384). 기존 핀 위에서는 새 `load`가 거부된다.

### 2.1 현재 정책 백업
- 명령: `sudo ./target/release/vantage-5G list | tee ~/vt-l4/policies-before.txt` (이전 빌드의 바이너리로 실행)
- 기대: UE별 RX/TX Mbps 목록이 나온다.

### 2.2 새 빌드로 load 시도 → 거부 확인
- 명령: `make build && sudo ./target/release/vantage-5G load; echo rc=$?`
- 기대: `rc=1`, `pinned maps under /sys/fs/bpf/vantage do not match the object:`, `rx_state_map (pinned -> .o): type Hash -> LruHash, max_entries 1024 -> 16384`(3차 빌드에서 올 때는 `max_entries 1024 -> 16384`만), 그리고 업그레이드 절차 안내. 이전 버전은 계속 동작한다(아무것도 바뀌지 않음).
- 실패 시: rc=0이면 핀이 이미 새 정의라는 뜻이다(업그레이드 불필요). 그 밖의 에러는 출력 전체를 보고한다.

### 2.3 절차 (README §10)
- 명령:
  ```bash
  sudo ./detach.sh <IF>; echo detach_rc=$?
  sudo ./target/release/vantage-5G unload; echo unload_rc=$?
  ```
- 기대: `detach_rc=0`, `unload_rc=0`(`[+] Vantage-5G pins removed.`).
- 실패 시: detach가 rc=4이면 남은 훅 목록을 보고 sudo/root로 다시 실행한다. unload가 `Vantage programs are still attached`이면 출력된 각 인터페이스에 `detach.sh`를 실행한다. 다른 netns에 붙은 것은 가드가 보지 못한다(X16).
- 이어서 3장(load → setup)을 진행하고, 4.1에서 2.1의 정책을 모두 다시 `set`한다.

## 3. 빌드 → load → attach

### 3.1 빌드
- 명령: `make check && bpftool version && make build`
- 기대: `vantage_rx_policer.o`, `vantage_tx_pacer.o`, `target/release/vantage-5G`가 생성된다.
- 실패 시: `make check`가 `bpftool not usable (Ubuntu: apt install linux-tools-common linux-tools-<kver>)`로 끝나면 1.2의 `linux-tools-$(uname -r)`를 설치한다(P-N3: `make check`는 `bpftool version` 실행까지 확인한다). verifier/BTF 문제면 `make clean && make build`로 재시도한다.

### 3.2 load
- 명령: `sudo ./target/release/vantage-5G load; echo rc=$?; sudo ./target/release/vantage-5G load; echo rc=$?; sudo ls /sys/fs/bpf /sys/fs/bpf/vantage; for m in rx_state_map tx_tstamp_map ue_stats_map ue_policy_map; do sudo bpftool map show pinned /sys/fs/bpf/vantage/$m; done; free -m`
- 기대: 두 번 모두 rc=0, 첫 줄은 `[i] BPF objects from <저장소 절대 경로>`(두 번째 실행은 이어서 `already pinned, skipping load`). `/sys/fs/bpf/vantage`에 프로그램 2개와 맵 4개가 있다. 맵 타입은 `lru_hash` 3개(`max_entries 16384`), `ue_policy_map`은 `hash`(`max_entries 1024`)이다. LRU 3개는 load 시 전량 사전 할당되며 `memlock` 합계는 24.04(6.8)에서 약 4.5 MiB(로컬 4,721,856 B), 22.04(5.15)에서는 커널의 계산 방식 차이로 약 1.5 MiB(로컬 1,572,864 B)로 표시된다(로컬 L2 `map-sizes-d25` 단계 기록, README §3.1). 이 값을 기록한다.
- 실패 시: `pinned maps … do not match the object`이면 2장(업그레이드)으로 간다. `Error: BPF object files not found`이면 위에 나열된 디렉터리별 누락 파일을 보고 3.1(`make build`)을 확인한다(`load`는 `<exe>/../..`(저장소) → exe 디렉터리 → 현재 디렉터리(최후) 순으로 두 .o를 찾고, `--obj-dir <DIR>`이면 그 디렉터리만 본다. README §12.3). 출력 전체를 보고한다.

### 3.3 setup.sh (재실행 포함)
- 명령: `sudo ./setup.sh <IF>; echo rc=$?; sudo ./setup.sh <IF>; echo rc=$?; ip -d link show dev <IF>; tc qdisc show dev <IF>; tc filter show dev <IF> egress`
- 기대: 두 번 모두 rc=0. `xdpgeneric` + `prog/xdp id <핀 id>`, root `fq`, `clsact`, egress `pref 1 … handle 0x1 … direct-action … id <핀 id>` 필터 1개.
- 실패 시: rc=2이면 `bpftool version`을 확인한다(1.2). rc=3이면 출력에 나온 충돌 훅을 확인한다(native XDP는 X8, 남의 필터, `ingress` qdisc). rc=4이면 출력된 현재 상태를 보고한다. root qdisc가 `mq`였던 멀티큐 NIC에서는 `fq`로 바뀌는 것이 정상이다(X7). 재실행 rc와 공백 여부를 기록한다.
- 비root 운영자: `./setup.sh <IF>`(sudo 권한 사용자)로 한 번 더 실행해 rc=0인지 확인한다.

### 3.4 잔여 루트 핀 정리 (X4/V14 — 이전에 구버전을 돌린 서버)
- 명령: `sudo ls /sys/fs/bpf`
- 기대: `vantage` 디렉토리만 있다(다른 도구의 핀은 무관).
- 실패 시: 루트에 `ue_policy_map`, `ue_stats_map`, `rx_state_map`, `tx_tstamp_map`이 있으면 구 빌드의 잔여물이다. `sudo bpftool map show pinned /sys/fs/bpf/rx_state_map`으로 확인한 뒤 `sudo rm -f /sys/fs/bpf/{ue_policy_map,ue_stats_map,rx_state_map,tx_tstamp_map}`를 실행하고 다시 `ls`로 확인한다. `/sys/fs/bpf/vantage/` 안은 건드리지 않는다.

### 3.5 bpftool 없는 상태의 거부 (선택, 22.04/24.04 확인용)
- 명령: `sudo mv /usr/sbin/bpftool /usr/sbin/bpftool.off; sudo ./setup.sh <IF>; echo rc=$?; sudo mv /usr/sbin/bpftool.off /usr/sbin/bpftool; ip -d link show dev <IF> | grep prog/xdp`
- 기대: rc=2와 `linux-tools-$(uname -r)` 안내가 나온다. attach 상태는 그대로다(xdp id 불변).
- 실패 시: 상태가 바뀌었으면 즉시 3.3을 다시 실행하고 보고한다.

## 4. README §8 측정 (4세션 동시)

### 4.0 [UE 호스트] UE IP 확인과 5G 경로 바인딩 확인 (README §8.1)
- 명령:
  ```bash
  ip -br -4 addr show | grep uesimtun | tee ~/vt-l4/4.0-ue-ips.txt
  ip -4 addr show uesimtun0
  ip route get <SVC> from <UE_A>
  ip route get <SVC> from <UE_B>
  ```
- 기대: PDU 세션마다 `uesimtunN`이 하나씩 있고 주소가 `<UE_NET>` 안에 있다. 이 주소로 런북 전체의 `<UE_A>`, `<UE_B>`(`spec.csv`의 `ue_ip` 포함)를 바꾼다. `ip route get … from <UE_x>`가 `dev uesimtunN`을 출력한다.
- 실패 시: `uesimtun`이 없으면 UE가 등록·PDU 세션 수립을 못 한 것이다(UERANSIM `nr-ue` 로그 확인). `ip route get … from`이 `uesimtunN`이 아닌 LAN NIC를 출력하면 `-B`만으로는 5G 경로를 타지 않는다 — 4.2에서 UERANSIM `build/`의 `nr-binder`를 쓴다.

### 4.1 정책
- 명령:
  ```bash
  sudo ./target/release/vantage-5G set --ue-ip <UE_A> --rx-mbps 10 --tx-mbps 20
  sudo ./target/release/vantage-5G set --ue-ip <UE_B> --rx-mbps 3  --tx-mbps 5
  sudo ./target/release/vantage-5G list
  ```
  (업그레이드였다면 2.1의 정책도 모두 다시 set한다.)
- 기대: `[+] policy set: UE <UE_A> rx=10 Mbps tx=20 Mbps` 등이 출력되고, `list`에 두 UE가 나온다.
- 실패 시: `open pinned ue_policy_map (run `vantage-5G load` first; needs root)`이면 3.2(load)와 `sudo`를 확인한다. `invalid value … for '--ue-ip <UE_IP>'`(rc=2)이면 4.0의 주소를 `/32` 없이 넣었는지 확인한다.
- D26 확인: 같은 명령을 한 번 더 실행한다(`set --ue-ip <UE_A> --rx-mbps 10 --tx-mbps 20`). 출력 끝에 `(unchanged; rx/tx state kept)`가 붙어야 한다 — 같은 값 재적용은 정책만 덮어쓰고 RX 토큰버킷·TX EDT 상태를 유지한다(주기적 재적용에도 버스트/백로그 망각 없음). 값이 바뀌면 이 문구가 없고 상태가 초기화된다. 상태를 강제로 초기화하려면 `reset` 후 `set`한다. 운영 스크립트가 주기적으로 `set`을 재적용한다면 그 동작이 이 의미를 전제로 하는지 확인한다.

### 4.2 서버와 클라이언트
- [서비스 노드]: `for p in 5201 5202 5203 5204; do iperf3 -s -p $p -D; done`
- [UE 호스트] 각 클라이언트를 해당 UE 주소에 바인딩한다(`-B`). 바인딩하지 않으면 UE 호스트의 일반 NIC로 나가 코어를 거치지 않고, Vantage는 UE가 아닌 UE 호스트의 LAN 주소를 보게 된다:
  ```bash
  mkdir -p ~/vt-l4 && cd ~/vt-l4
  iperf3 -c <SVC> -B <UE_A> -p 5201 -t 30    -J > a_ul.json &
  iperf3 -c <SVC> -B <UE_A> -p 5203 -t 30 -R -J > a_dl.json &
  iperf3 -c <SVC> -B <UE_B> -p 5202 -t 30    -J > b_ul.json &
  iperf3 -c <SVC> -B <UE_B> -p 5204 -t 30 -R -J > b_dl.json &
  wait
  ```
  4.0에서 `ip route get … from`이 `uesimtunN`이 아니었다면 `-B` 대신 UERANSIM `build/` 디렉토리의 `nr-binder`로 실행한다(예: `./nr-binder <UE_A> iperf3 -c <SVC> -p 5201 -t 30 -J > ~/vt-l4/a_ul.json &`).
- 기대(실행 중): [서비스 노드] `sudo ./target/release/vantage-5G stats`에 `<UE_A>`, `<UE_B>` 행이 있고 rx_bytes/tx_bytes가 증가한다.
- 실패 시: `stats`에 UE 행이 없으면 1.7(NAT)과 바인딩을 다시 확인한다. iperf3가 `unable to connect`이면 1.6(귀환 경로)·1.5(포워딩)를 확인한다.
- 네 세션을 **같은 순간**에 시작한다.
- [서비스 노드] 클라이언트 시작 직후 counter 스냅샷(X3 B안)을 남긴다. t2는 시작 후 약 25 s로, 30 s 세션이 끝나기 전에 여유를 둔다(README §8.4와 같다). `counter_verdict.py`는 `t=<epoch>` 줄 + `stats` 출력 형식을 읽는다:
  ```bash
  ( sleep 5;  { echo "t=$(date +%s.%N)"; sudo ./target/release/vantage-5G stats; } > ~/vt-l4/stats_t1.txt
    sleep 20; { echo "t=$(date +%s.%N)"; sudo ./target/release/vantage-5G stats; } > ~/vt-l4/stats_t2.txt ) &
  ```
- 모으기: [UE 호스트]의 json 4개를 [서비스 노드]의 `~/vt-l4/`로 복사한다(예: UE 호스트에서 `scp ~/vt-l4/*.json <user>@<SVC>:vt-l4/`). 판정은 json, `stats_t*.txt`, `spec.csv`가 한 디렉토리에 있으면 어디서든 된다.
- spec.csv(json 4개와 같은 디렉토리, `ue_ip`는 4.0의 실제 주소, `cap_mbps`는 UL 행이 `--rx-mbps`, DL 행이 `--tx-mbps` 값):
  ```
  label,ue_ip,direction,cap_mbps,json_path
  A-UL,<UE_A>,UL,10,a_ul.json
  B-UL,<UE_B>,UL,3,b_ul.json
  A-DL,<UE_A>,DL,20,a_dl.json
  B-DL,<UE_B>,DL,5,b_dl.json
  ```
- 판정(저장소 디렉토리에서, 서비스 노드 또는 결과를 가져온 PC): `python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py ~/vt-l4/spec.csv`와 `python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py ~/vt-l4/spec.csv ~/vt-l4/stats_t1.txt ~/vt-l4/stats_t2.txt` (출력 해석: README §8.5)
- 기대: counter 판정 4세션 모두 ±10%(로컬 jammy 기준 ±0.3%). iperf goodput ±10%(UL은 헤더와 ACK 때문에 -1~-7%가 정상).
- 실패 시: cap **초과**면 즉시 보고한다(`tc qdisc show dev <IF>`, `stats` 증가 여부, 1.4/1.7 NAT, 4.0 바인딩, `ip route get <UE_A>`가 `dev <IF>`인지). 미달이면 4.3과 서버 CPU(`mpstat -P ALL 1`)를 함께 기록한다.

### 4.3 측정 직후 상태
- 명령: `sudo ./target/release/vantage-5G stats; tc -s qdisc show dev <IF>; ethtool -S <IF> | grep -iE 'drop|miss' | head`
- 기대: 정상 TCP에서는 tx_drops가 0 근처다. fq `dropped`는 작다.

### 4.4 멀티큐 UL 경합 (X14)
- 명령: [UE 호스트] `iperf3 -c <SVC> -B <UE_A> -p 5201 -t 30 -P 8 -J > a_ul_p8.json`, 동시에 4.2처럼 stats 스냅샷을 남긴다.
- 기대: counter 판정 A-UL이 +10% 이하다.
- 실패 시: 초과 폭과 큐 수(`ethtool -l`)를 기록한다(D5a 잔여 경합, datapath로 이관).

### 4.5 killswitch, D4 (선택)
- killswitch: `sudo ./target/release/vantage-5G set --ue-ip <UE_B> --rx-mbps 3 --tx-mbps 0`(출력 끝 `(killswitch: DL blocked)`) 후 [UE 호스트]에서 `ping -I <UE_B의 uesimtunN> -c3 <SVC>`가 실패하고, `ping -I <UE_A의 uesimtunN> -c3 <SVC>`는 정상이어야 한다. `stats`에서 `<UE_B>`의 TX_DROPS가 증가한다. 이어서 `set … --tx-mbps 5`로 복구한다.
- D4: UE-A를 tx 1 Mbps로 두고 서비스 노드 뒤(포워딩되는 쪽) 호스트에서 UE-A로 UDP 100M을 10 s 보낸다. 직후 TCP DL이 연결되고 1 Mbps 근처가 나와야 한다. tx_drops 증가는 정상이다. 끝나면 정책을 원래대로 돌린다.

## 5. detach → unload → 잔존물

### 5.1 unload 가드
- 명령: `sudo ./target/release/vantage-5G unload; echo rc=$?`
- 기대: attach 상태이므로 rc=1이고, `<IF>: xdpgeneric prog id … (vantage_rx_poli)`와 `run: sudo ./detach.sh <IF>`가 출력된다. 핀은 그대로다.

### 5.2 detach + unload
- 명령: `sudo ./detach.sh <IF>; echo rc=$?; ip -d link show dev <IF> | grep -c prog/xdp; tc filter show dev <IF> egress; tc qdisc show dev <IF>; sudo ./target/release/vantage-5G unload; echo rc=$?; sudo ls /sys/fs/bpf`
- 기대: detach rc=0, `prog/xdp` 0줄, egress 필터 없음, clsact 없음, root는 커널 기본 qdisc(멀티큐 NIC이면 `mq` + 자식 기본 qdisc. 이전에 직접 넣은 custom qdisc는 복원되지 않음). unload rc=0, `/sys/fs/bpf`에 `vantage` 없음.
- 실패 시: detach rc=4이면 남은 목록을 보고한다(native 드라이버에서 xdp 잔존은 X2).

## 6. 로컬에서 재현하지 못한 항목 체크리스트 (L4에서만 확인 가능)

| # | 항목 | 확인 위치 |
|---|---|---|
| X1 | 새 clone 실행 권한 | 1.3 |
| X2 | native XDP 지원 드라이버(ixgbe/i40e/mlx5 등)에서 detach 후 xdp 잔존 없음 | 5.2 |
| X5 | 실 코어 경로에서 UE IP 노출(NAT 없음), 귀환 경로 | 1.4~1.7 |
| X7 | 멀티큐 NIC(root `mq`)에서 setup.sh 재실행 rc=0, 공백 없음 | 3.3 |
| X8 | native XDP NIC에서 generic attach 동작 / 수동 `xdpdrv` attach 시 exit 3 | 3.3 |
| X12 | 22.04/24.04 설치 명령, `bpftool version` | 1.2 |
| X14 | RSS 멀티큐 UL `-P 8` 과다 허용 | 4.4 |
| X15 | BIG TCP 비활성(gro_max_size ≤ 65536), native XDP에서 rx_packets 의미 | 1.8, 4.3 |
| X16 | 다른 netns(컨테이너 등)에 attach된 경우 unload 가드 미검출 | 해당 시 |
| X13 | LRU 조기 퇴출 — 조건은 UE 수가 아니라 CPU 수(nproc > 128 & 커널 < 6.16, 1.1a). stats에서 활성 UE 카운터가 0으로 돌아가는지 | 1.1a, 장기 운영 관찰 |
| V20 | 맵 메모리(LRU 3개 memlock 합계 ≈ 4.5 MiB, 커널별 표시 차이) | 3.2 |

## 7. 가져올 것
`~/vt-l4/` 전체(서비스 노드와 UE 호스트 양쪽, UPF 호스트의 1.4 출력 포함. 단계별 출력, `nproc`, 3.2의 `bpftool map show` 출력), `*.json` 4~5개, `spec.csv`, `stats_t1.txt`, `stats_t2.txt`, `ethtool -i`/`-l` 출력, 커밋 해시, `uname -r`.
