# L4 설치 런북 — 물리 Ubuntu 서버 (22.04 / 24.04)

- 대상 커밋: `main`의 `61ab576`(PR #7 Grafana 대시보드까지) 이후. 아래 `<COMMIT>`을 실제로 받은 해시로 바꾼다. `setup.sh --xdp-mode`·멀티큐(3.3, 3.3a, 4.4a, 5.2), systemd 서비스(3.6), `apply`/`export`, Grafana 대시보드(3.7.3)가 모두 들어 있다.
- 로컬 근거(2026-10-21 최종 회귀, 제품 코드 `61ab576`. 실행 중 이 런북만 수정 중이라 일부 `commit.txt`가 `61ab576-dirty`). VirtualBox VM은 한 번에 하나만 켰고(L3는 구조상 2대), 처리량은 VM 타이머 점검(timer-health)이 OK일 때만 판정했다. 물리 서버에는 이 점검이 해당하지 않는다.
  - L1 Docker: `l1-20261021_073924` 26 PASS / 0 FAIL / 8 SKIP(sch_fq 없음 → L2).
  - L2 Ubuntu 22.04(5.15.0-198): timer OK에서 기본 `l2-jammy-20261021_075811` 36 PASS·SKIP 2, TX 큐 2(최대 8) `…_080048` 38 PASS, native + TX 큐 4 `…_080336` 37 PASS, 비root setup + TX 큐 2 `…_080548` 37 PASS. 4세션 counter 판정 전부 ±0.2% 이내, iperf goodput -0.8~-8.3%(UL은 헤더·ACK 몫).
  - L2 Ubuntu 24.04(6.8.0-147): 같은 4개 조합에서 기능 단계 FAIL 0. 처리량은 이번 실행 내내 VM 타이머 열화(p99 61~134 ms, 재기동 후에도)라 판정하지 않았다. 같은 VM의 커널 셰이퍼도 같은 폭으로 미달했다(`fq maxrate 20mbit` → 7.95 Mbps). cap 초과는 0건. 24.04 처리량의 근거는 이전 건강한 실행(`l2-noble-20261020_083018`, counter ±0.3%, B-UL만 -8.7%)이다 — 4.2의 B-UL 주의(X27).
  - systemd 서비스(`testbed/l2-systemd.sh`, 설치 → 재부팅 → 확인 → 제거): 22.04 `l2sd-jammy-20261021_080804`, 24.04 `l2sd-noble-20261021_082825` 모두 pre 3/3, post 38/38, cleanup 4/4 PASS(monitor `After=`만, monitor 재시작이 main을 끌어오지 않음, MONITOR_ARGS 재시작 대상, 하드닝 상태의 모듈 자동 로드 포함).
- L3 로컬 테스트베드(`testbed/l3-vbox.sh`: Open5GS 2.8 레퍼런스 설치 + UERANSIM v3.2.7 VM과 서비스 노드 Ubuntu 24.04 VM을 별도 N6로 연결)에서 문서 명령 그대로 확인한 범위: 1.4(방법 A·B, conntrack 삭제), 1.5(FORWARD 정책이 `ACCEPT`인 경우), 1.6(`ip route add`/`get`), 1.7(종단 확인, 귀환 경로가 없을 때의 진단), 4.0(`uesimtunN`), 4.1, 5.2. 최종 회귀 `l3-20261021_095653`(testbed 보강 후: RAN 생존 확인, 측정값 없는 단계는 INVALID)에서 위 범위와 4.2 counter 판정(4세션 모두 ±10%: +0.1 / -0.0 / -9.4 / -4.5%), 4.5 killswitch(UE-B TX_DROPS 0 → 12, UE-A 정상)가 PASS였다. iperf goodput은 A-DL만 -12.5%였는데, 같은 NIC의 커널 `fq maxrate`도 6 Mbit 중 3.0 Mbit에 그쳐 환경(UERANSIM 경로, VM 타이머 열화)으로 분류했다. 같은 날 앞선 실행(`l3-20261021_083236`·`_090118`·`_091722`)은 서비스 VM 잔여 설치물과 UERANSIM 무선 구간 끊김 때문에 무효다. **확인하지 않은 것**: 1.5의 `-P FORWARD DROP` 분기, 1.5a 영구화(ufw·iptables-persistent), 1.6의 netplan 영구화, 3.7(대시보드 UI, 원격 scrape), 4.4/4.4a(물리 멀티큐), 4.5 D4 — 6장과 함께 L4에서 확인한다.
- 설치 경로는 두 가지다(README §5, §5a). **(가) 수동**: 3.2 `load` → 3.3 `setup.sh` → 4.1 `set`. 단계마다 출력이 바로 보여 첫 설치·측정·진단에 맞다. 재부팅하면 핀·attach·정책이 모두 사라진다. **(나) systemd 서비스**: 3.6 `install.sh` → `/etc/vantage-5g/` 설정 → `systemctl start`. 부팅마다 load → `apply --replace`(policies.conf) → `setup.sh` 순으로 자동 실행된다. 권장 순서: (가)로 3~5장을 끝까지 한 번 측정한 뒤 3.6으로 (나)를 설치하고, 3.6.5 재부팅 확인 후 필요하면 4장을 서비스 상태에서 다시 측정한다. (나)의 로컬 근거는 위 systemd 서비스 줄이다(테스트 N6는 systemd-networkd veth).
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
      linux-tools-common "linux-tools-$(uname -r)" iproute2 iperf3 tcpdump ethtool curl git python3
  bpftool version
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 이후 새 셸 또는 . ~/.cargo/env
  rustc --version
  ```
- 기대: apt rc=0. `bpftool version`이 버전을 출력한다("WARNING: bpftool not found for kernel …"이 아님). `rustc` 1.89 이상(`Cargo.toml`의 `rust-version = "1.89"`; 잠금에 쓰는 `File::try_lock`). `curl`(rustup), `git`(1.3), `python3`(4.2 판정 스크립트)는 최소 설치 서버에 없을 수 있어 함께 설치한다.
- 실패 시: `rustc`가 1.89 미만이면 `rustup update stable`(apt의 `rustc`를 쓰지 않는다. 빌드는 `rust-version` 오류로 멈춘다). `linux-tools-$(uname -r)` 후보가 없으면(HWE·커스텀 커널) `apt-cache search linux-tools | grep $(uname -r)`로 flavour 패키지를 찾는다. `bpftool` 패키지를 따로 설치하려 하지 않는다(22.04/24.04 모두 설치 후보 없음, 로컬 확인).

### 1.3 소스
- 명령: `git clone https://github.com/uni2u/vantage-5G.git && cd vantage-5G && git checkout <COMMIT> && git log -1 --oneline && ls -l setup.sh detach.sh`
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
- 기대: 드라이버명, 큐 수, root qdisc(`mq`일 수 있음)를 기록한다. TX 큐 수는 `ls -d /sys/class/net/<IF>/queues/tx-* | wc -l`(사용 중 N)와 `ip -d link show dev <IF> | grep -o 'numtxqueues [0-9]*'`(할당 M)로도 기록한다(`setup.sh`가 쓰는 값, 3.3). `sysctl net.core.default_qdisc`도 기록한다(5.2에서 detach 후 복원될 자식 qdisc 종류). 드라이버명은 3.3a(native XDP 시도) 판단에 쓴다. 이미 붙은 `prog/xdp`나 egress 필터가 없어야 한다. `gro_max_size`/`gro_ipv4_max_size`는 65536 이하여야 한다(X15, BIG TCP 비활성).
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

### 2.4 서비스(3.6)로 설치된 서버의 업그레이드
- 명령:
  ```bash
  sudo vantage-5G export > /tmp/policies.conf && diff /tmp/policies.conf /etc/vantage-5g/policies.conf   # CLI로만 바꾼 정책 확인
  git fetch && git checkout <COMMIT> && make build
  sudo ./install.sh install 2>&1 | tail -8 | tee ~/vt-l4/2.4-install.txt; echo rc=${PIPESTATUS[0]}
  systemctl show -p MainPID --value vantage-5g-monitor
  sudo systemctl restart vantage-5g
  sudo systemctl restart vantage-5g-monitor
  systemctl is-active vantage-5g vantage-5g-monitor; systemctl show -p MainPID --value vantage-5g-monitor
  journalctl -u vantage-5g -n 20 --no-pager | tee ~/vt-l4/2.4-restart.txt
  ```
- 기대: diff가 주석 줄만 다르면 파일이 최신이다(다르면 `sudo mv /tmp/policies.conf /etc/vantage-5g/policies.conf`로 저장할지 결정). install rc=0이고 출력 끝에 다음 안내가 나온다:
  ```
  The running units still use the previous version; to switch:
    sudo systemctl restart vantage-5g.service    (re-attach, short shaping gap)
    sudo systemctl restart vantage-5g-monitor.service
  (each unit is restarted on its own; restarting one does not restart the other)
  ```
  두 유닛은 따로 재시작한다. `restart vantage-5g`만 하면 monitor는 옛 바이너리로 계속 돈다. vantage-5g의 restart는 detach → unload → load → apply → setup이므로 맵 정의가 바뀐 업그레이드(2.2의 거부)도 이것으로 끝난다. `active` 두 줄, monitor MainPID가 restart 전과 다르다. journal에 새 load와 `applied … (--replace)`가 있다.
- 실패 시: restart 후 `failed`이면 3.6.3의 실패 시 표로 단계를 판정한다. stop 단계 실패는 3.6.6의 실패 시를 따른다.

## 3. 빌드 → load → attach

### 3.1 빌드
- 명령: `make check && bpftool version && make build`
- 기대: `vantage_rx_policer.o`, `vantage_tx_pacer.o`, `target/release/vantage-5G`가 생성된다.
- 실패 시: `make check`가 `bpftool not usable (Ubuntu: apt install linux-tools-common linux-tools-<kver>)`로 끝나면 1.2의 `linux-tools-$(uname -r)`를 설치한다(P-N3: `make check`는 `bpftool version` 실행까지 확인한다). verifier/BTF 문제면 `make clean && make build`로 재시도한다.

### 3.2 load
- 명령: `sudo ./target/release/vantage-5G load; echo rc=$?; sudo ./target/release/vantage-5G load; echo rc=$?; sudo ls /sys/fs/bpf /sys/fs/bpf/vantage; for m in rx_state_map tx_tstamp_map ue_stats_map ue_policy_map; do sudo bpftool map show pinned /sys/fs/bpf/vantage/$m; done; free -m`
- 기대: 두 번 모두 rc=0, 첫 줄은 `[i] BPF objects from <저장소 절대 경로>`(두 번째 실행은 이어서 `already pinned, skipping load`). `/sys/fs/bpf/vantage`에 프로그램 2개와 맵 4개가 있다. 맵 타입은 `lru_hash` 3개(`max_entries 16384`), `ue_policy_map`은 `hash`(`max_entries 1024`)이다. LRU 3개는 load 시 전량 사전 할당되며 `memlock` 합계는 24.04(6.8)에서 약 4.5 MiB(로컬 4,721,856 B), 22.04(5.15)에서는 커널의 계산 방식 차이로 약 1.5 MiB(로컬 1,572,864 B)로 표시된다(로컬 L2 `map-sizes-d25` 단계 기록, README §3.1). 이 값을 기록한다.
- 실패 시: `pinned maps … do not match the object`이면 2장(업그레이드)으로 간다. `Error: BPF object files not found`이면 위에 나열된 디렉터리별 누락 파일을 보고 3.1(`make build`)을 확인한다(`load`는 `<exe>/../..`(저장소) → exe 디렉터리 → 현재 디렉터리(최후) 순으로 두 .o를 찾고, `--obj-dir <DIR>`이면 그 디렉터리만 본다. README §12.3). 출력 전체를 보고한다.

### 3.3 setup.sh (generic, 재실행 포함)
- 명령:
  ```bash
  sysctl net.core.default_qdisc
  sudo ./setup.sh <IF> 2>&1 | tee ~/vt-l4/3.3-setup1.txt; echo rc=${PIPESTATUS[0]}
  tc qdisc show dev <IF> | tee ~/vt-l4/3.3-qdisc1.txt
  sudo ./setup.sh <IF> 2>&1 | tee ~/vt-l4/3.3-setup2.txt; echo rc=${PIPESTATUS[0]}
  tc qdisc show dev <IF> | tee ~/vt-l4/3.3-qdisc2.txt
  ip -d link show dev <IF>; tc filter show dev <IF> egress; sysctl net.core.default_qdisc
  ```
- 기대: 두 번 모두 rc=0. 플래그 없이 실행하면 generic이다: `xdpgeneric` + `prog/xdp id <핀 id>`, `clsact`, egress `pref 1 … handle 0x1 … direct-action … id <핀 id>` 필터 1개. qdisc는 1.8에서 기록한 TX 큐 수 N에 따라 다르다.
  - N=1: root `fq`. 출력 끝 `TX qdisc  root fq`.
  - N≥2: root `mq 1:`이고 **모든 mq 클래스** `parent 1:1` … `parent 1:<M, 16진수>`(M = 1.8의 numtxqueues, 사용하지 않는 큐 포함)가 `fq`. 출력 끝 `TX qdisc  root mq 1: + fq on all M mq classes (N TX queues in use)`. 첫 실행 출력에 `current root: mq 0:; creating root mq 1:`(커널 기본 mq에서 전환)이 나오고, `net.core.default_qdisc`가 fq가 아니었으면 `net.core.default_qdisc <값> -> fq for the mq creation only`와 `… restored to <값>`이 나온다. M > N이면 `setting fq on mq classes: 1:<N+1> …`도 나온다. 두 번째 실행은 `… already in place (kept, no change)`이고 `3.3-qdisc1.txt`와 `3.3-qdisc2.txt`의 handle이 같다(재실행 시 qdisc 무변경). 마지막 `sysctl` 값이 처음 값과 같고 `ls /run/vantage-5g.default_qdisc`가 없다(No such file).
- 실패 시: rc=2이면 `bpftool version`을 확인한다(1.2). rc=3이면 출력의 `[-]` 줄을 확인한다: 남의 XDP 프로그램, 남의 필터, `ingress` qdisc, `has a qdisc using handle 1:`(멀티큐에서 root `prio 1:`/`htb 1:` 등 — 쓰는 곳이 없으면 `sudo tc qdisc del dev <IF> root` 후 재실행), `kernel module(s) not available`(`sch_fq`/`cls_bpf`/`sch_ingress`, `modinfo <모듈>` 결과를 기록). rc=5이면 `step failed … may be partially attached` 줄을 기록하고 `sudo ./detach.sh <IF>` 후 원인을 고쳐 재실행한다. 시작 시 `[!] /run/vantage-5g.default_qdisc exists` 경고가 나오면 이전 실행이 중단된 것이다 — 출력된 복구 명령(`sysctl -w net.core.default_qdisc=<원래값>`, 파일 삭제)을 실행하고 기록한다. rc=4이면 출력된 현재 상태(`[-] verify: …`)를 보고한다(예: `TX queue classes without fq under root …`). 마지막 `sysctl` 값이 처음과 다르면 보고하고 `sudo sysctl -w net.core.default_qdisc=<처음 값>`으로 되돌린다. 첫 전환(커널 기본 `mq` → `mq 1:`) 순간에 큐에 있던 패킷은 버려진다. 트래픽이 흐르는 중이었다면 링크 리셋 여부(`dmesg | tail`)와 함께 기록한다(X7).
- 비root 운영자: `./setup.sh <IF>`(sudo 권한 사용자)로 한 번 더 실행해 rc=0인지 확인한다.

### 3.3a native XDP 시도 (선택, 1.8의 드라이버가 XDP를 지원할 때 — X8)
1.8의 `ethtool -i <IF>` 드라이버가 native XDP를 지원하는 종류(예: ixgbe, i40e, ice, mlx5, virtio_net)이면 시도한다. 일부 드라이버는 native attach/detach 때 링을 재구성해 **링크가 잠깐 끊긴다** — 원격 SSH가 이 NIC를 거치지 않는지, 트래픽이 없는 시간인지 먼저 확인한다.
- 명령:
  ```bash
  sudo ./setup.sh <IF> --xdp-mode native 2>&1 | tee ~/vt-l4/3.3a-native.txt; echo rc=${PIPESTATUS[0]}
  ip -d link show dev <IF> | head -3; dmesg | tail -20 | tee ~/vt-l4/3.3a-dmesg.txt
  ```
- 기대(지원): rc=0, 출력에 `moving the Vantage program (id …) from 'xdpgeneric' to native mode`와 `RX policer (XDP native, id <핀 id>)`. `ip link` 첫 줄에 `xdp`(native 표시, `xdpgeneric` 아님). 이후 단계는 native로 진행해도 된다(4.2 판정 기준 같음).
- 기대(미지원): rc=3, `[-] XDP attach in native mode failed: …`(커널 메시지, 예: `Underlying driver does not support XDP in native mode`), 드라이버명, `Use '--xdp-mode generic'`. 이어서 `restoring the previous attach (xdpgeneric, …)`. `ip -d link`가 다시 `xdpgeneric` + 같은 핀 id다. 이 결과를 기록하고 generic으로 계속한다.
- 실패 시: rc=4와 `restore failed: <IF> has NO XDP RX policer now.`이면 즉시 `sudo ./setup.sh <IF>`(generic)를 실행해 rc=0인지 확인하고 보고한다. 링크가 끊긴 시간(`dmesg`의 `Link is Down/Up`)을 기록한다.
- generic으로 되돌리기(이후 단계를 generic으로 할 때): `sudo ./setup.sh <IF>; echo rc=$?` → rc=0, `xdpgeneric`.

### 3.4 잔여 루트 핀 정리 (X4/V14 — 이전에 구버전을 돌린 서버)
- 명령: `sudo ls /sys/fs/bpf`
- 기대: `vantage` 디렉토리만 있다(다른 도구의 핀은 무관).
- 실패 시: 루트에 `ue_policy_map`, `ue_stats_map`, `rx_state_map`, `tx_tstamp_map`이 있으면 구 빌드의 잔여물이다. `sudo bpftool map show pinned /sys/fs/bpf/rx_state_map`으로 확인한 뒤 `sudo rm -f /sys/fs/bpf/{ue_policy_map,ue_stats_map,rx_state_map,tx_tstamp_map}`를 실행하고 다시 `ls`로 확인한다. `/sys/fs/bpf/vantage/` 안은 건드리지 않는다.

### 3.5 bpftool 없는 상태의 거부 (선택, 22.04/24.04 확인용)
- 명령: `sudo mv /usr/sbin/bpftool /usr/sbin/bpftool.off; sudo ./setup.sh <IF>; echo rc=$?; sudo mv /usr/sbin/bpftool.off /usr/sbin/bpftool; ip -d link show dev <IF> | grep prog/xdp`
- 기대: rc=2와 `linux-tools-$(uname -r)` 안내가 나온다. attach 상태는 그대로다(xdp id 불변).
- 실패 시: 상태가 바뀌었으면 즉시 3.3을 다시 실행하고 보고한다.

### 3.6 [선택 (나)] systemd 서비스로 설치 (README §5a)
3.1의 빌드가 끝난 상태에서 진행한다. 3.2~3.3으로 이미 수동으로 붙여 둔 상태여도 된다(`load`는 멱등, `setup.sh` 재실행은 안전). 서비스는 **policies.conf가 기준**이다: 시작·reload·재부팅마다 `apply --replace`가 파일에 없는 UE의 정책을 지운다. 그래서 CLI(`set`)로 넣은 정책을 먼저 파일로 저장한다(3.6.2).

원격 SSH가 `<IF>`를 거치지 않는지 먼저 확인한다(3.6.5 재부팅, native XDP 링크 리셋).

#### 3.6.1 install
- 명령:
  ```bash
  sudo ./install.sh install --enable 2>&1 | tee ~/vt-l4/3.6.1-install.txt; echo rc=${PIPESTATUS[0]}
  systemctl is-enabled vantage-5g vantage-5g-monitor; ls -l /usr/local/bin/vantage-5G /usr/local/lib/vantage-5g /etc/vantage-5g
  sudo ./install.sh install 2>&1 | tail -4; echo rc=${PIPESTATUS[0]}     # 재실행: 설정 보존 확인
  ```
- 기대: 첫 실행 rc=0. `=== 1. /usr/local/lib/vantage-5g ===` 다음 줄에 `vantage-5G 0.2.0`, `/usr/local/bin/vantage-5G -> /usr/local/lib/vantage-5g/vantage-5G`, `vantage-5g.env created from the example`, `policies.conf created from the example`, `=== 5. enable ===`, `[+] Vantage-5G installed.`, `[!] set IFACE= in /etc/vantage-5g/vantage-5g.env`. 예시 env는 `MONITOR_ARGS=--bind 127.0.0.1`이라 `MONITOR_ARGS … has no --bind` 경고는 나오지 않는다(기존 env를 유지한 재설치에서 `--bind`가 없으면 나온다). `is-enabled`가 `enabled` 두 줄. 재실행도 rc=0이고 출력에 `vantage-5g.env exists (kept)`, `policies.conf exists (kept)`가 있다.
- 실패 시: rc=2와 `missing in <저장소>: …`이면 3.1(`make build`)을 확인한다. rc=1과 `run as root`이면 `sudo`로 실행한다. `[!] /usr/local/bin/vantage-5G is a regular file`이면 기록한다(그 파일은 건드리지 않음). 이 런북의 서비스 단계에서는 `/usr/local/lib/vantage-5g/vantage-5G`를 쓴다.

#### 3.6.2 설정과 정책 파일
- 명령:
  ```bash
  # 지금 맵에 있는 정책(수동 경로에서 set한 것)을 파일로 저장. 임시 파일 → mv (export 실패 시 빈 파일 방지)
  sudo vantage-5G export | tee ~/vt-l4/3.6.2-export.txt
  sudo vantage-5G export > /tmp/policies.conf && sudo mv /tmp/policies.conf /etc/vantage-5g/policies.conf
  sudoedit /etc/vantage-5g/vantage-5g.env     # IFACE=<IF>, XDP_MODE=generic|native(3.3a 결과), MONITOR_ARGS=
  sudoedit /etc/vantage-5g/policies.conf      # 필요하면 <UE_IPv4> <rx_mbps> <tx_mbps> 줄 편집
  grep -vE '^\s*(#|$)' /etc/vantage-5g/vantage-5g.env /etc/vantage-5g/policies.conf | tee ~/vt-l4/3.6.2-config.txt
  ```
  아무것도 load되지 않은 상태라면 `export`는 `open pinned ue_policy_map …`로 실패하고 `mv`는 실행되지 않는다(예시에서 만든 policies.conf 유지). 그때는 policies.conf를 직접 쓴다(형식: 파일 안 주석, README §6.1).
- 기대: export 첫 두 줄이 `# Vantage-5G policies (vantage-5G export): …` 주석이고 이어서 UE별 `<ip> <rx> <tx>` 줄이 주소 순으로 나온다(4.1의 정책과 같음). env에 `IFACE=<IF>`가 있다. `XDP_MODE=`는 비우지 않는다(비우면 preflight status=1, 줄을 지우면 generic). `IFACE_WAIT_SEC`는 최대 240(초과 값은 240으로 줄고 경고). 예시의 `MONITOR_ARGS=--bind 127.0.0.1`을 유지한다. `/metrics`에는 모든 UE의 IP·정책·카운터가 나오므로 원격 Prometheus가 필요하면 관리망 주소로만 `--bind`하고 방화벽으로 제한한다(`--bind`가 없으면 N6 쪽을 포함한 `0.0.0.0:9090`. 원격 scrape는 3.7.2). `--port`는 1024 이상을 쓴다(monitor 유닛의 capability에 `CAP_NET_BIND_SERVICE`가 없어 1024 미만이면 bind 권한 오류로 재시작을 반복하다가 failed가 된다).
- 서비스를 시작한 **뒤에** env를 바꾸면 키별로 재시작할 유닛이 다르다. 두 유닛은 서로를 재시작하지 않는다:
  - `IFACE`, `XDP_MODE`, `IFACE_WAIT_SEC` → `sudo systemctl restart vantage-5g`(재attach)
  - `MONITOR_ARGS` → `sudo systemctl restart vantage-5g-monitor`(`restart vantage-5g`로는 bind 주소가 바뀌지 않는다. 로컬 L2 jammy에서 재현)
- 실패 시: export가 stderr로 `[!] <ip>: … is not a whole Mbps; exported rounded down`을 내면 그 UE의 값을 기록한다(set/apply 외의 도구가 맵에 쓴 것).

#### 3.6.3 start
- 명령:
  ```bash
  sudo systemctl start vantage-5g vantage-5g-monitor; echo rc=$?
  systemctl status vantage-5g --no-pager | tee ~/vt-l4/3.6.3-status.txt
  journalctl -u vantage-5g -b --no-pager | tail -30 | tee ~/vt-l4/3.6.3-journal.txt
  sudo vantage-5G list; ip -d link show dev <IF> | grep -o 'prog/xdp[a-z]* id [0-9]*'; tc qdisc show dev <IF>
  ss -ltnp | grep 9090; curl -s http://127.0.0.1:9090/metrics | grep -c '^vantage_'
  ```
- 기대: rc=0, `Active: active (exited)`. journal 순서: `[i] BPF objects from /usr/local/lib/vantage-5g` → `[+] applied /etc/vantage-5g/policies.conf (--replace): added …` → `[+] Vantage-5G attached to <IF>.` → `Finished`. `list`가 policies.conf와 같고, XDP·qdisc는 3.3과 같다. `ss`의 9090 LISTEN이 MONITOR_ARGS의 주소 **하나뿐**이다(예시 그대로면 `127.0.0.1:9090`만 있고 `0.0.0.0:9090`이나 `*:9090`은 없다). 메트릭 줄 수 > 0.
- 실패 시: 서비스는 실패해도 **자동 정리하지 않는다**. `systemctl status`의 `ExecStartPre=…`/`ExecStart=… (code=exited, status=N)` 줄로 단계를 판정한다:
  - `vantage-5g-unit.sh preflight` status=1: env 오류(`IFACE is not set`, `not a valid interface name`, `XDP_MODE is empty`, `XDP_MODE … must be generic or native`) 또는 `policies.conf not found`. status=6: `interface <IF> did not appear within 90s`. `ip link`로 이름을 확인한다.
  - `vantage-5G load` status=1: 3.2의 실패 시와 같다(`pinned maps … do not match`이면 2장).
  - `vantage-5G apply` status=1: journal에 `line N: …` 오류 목록과 `nothing was changed`(또는 30초 잠금 대기 초과 `still holds /run/vantage-5g.lock`). 이때 아무것도 attach되지 않는다. 파일을 고치고 다시 start한다.
  - `setup.sh` status=2/3/4/5: 3.3의 실패 시와 같다. status=3이면 다른 도구의 상태는 그대로이므로 원인을 정리하고 다시 start한다. status=5이면 먼저 `sudo /usr/local/lib/vantage-5g/detach.sh <IF>`를 실행한다.
  - 원인을 고친 뒤 `sudo systemctl start vantage-5g vantage-5g-monitor`. 출력 전체(status, journal)를 기록한다.

#### 3.6.4 reload (정책 파일 변경)
- 명령: policies.conf에서 UE 하나의 값을 바꾼 뒤
  ```bash
  ip -d link show dev <IF> | grep -o 'prog/xdp[a-z]* id [0-9]*'
  sudo systemctl reload vantage-5g; echo rc=$?
  journalctl -u vantage-5g --no-pager -n 6 | tee ~/vt-l4/3.6.4-reload.txt
  sudo vantage-5G list; ip -d link show dev <IF> | grep -o 'prog/xdp[a-z]* id [0-9]*'
  ```
- 기대: rc=0, `[+] applied /etc/vantage-5g/policies.conf (--replace): added 0, changed 1, unchanged <나머지>, removed 0`과 바뀐 UE의 `~` 줄. 앞뒤 XDP prog id가 같다(재attach 없음). 바뀌지 않은 UE는 RX/TX 상태가 유지된다.
- 정책이 하나도 없는(빈·잘린) 파일로 reload하면 rc≠0, journal에 `has no policies; --replace would remove all N current policies (pass --allow-empty …)`, 정책은 그대로이고 유닛은 active다(선택 확인: `sudo cp /etc/vantage-5g/policies.conf /tmp/pol.keep; sudo truncate -s0 /etc/vantage-5g/policies.conf; sudo systemctl reload vantage-5g; echo rc=$?; sudo vantage-5G list; sudo cp /tmp/pol.keep /etc/vantage-5g/policies.conf`). 정말 모두 지우려면 `sudo vantage-5G apply -f /etc/vantage-5g/policies.conf --replace --allow-empty`.
- 실패 시: 파일 오류면 rc≠0이고 journal에 줄 번호 목록이 나오며 정책은 그대로다(동작 중인 셰이핑 영향 없음). 파일을 고치고 다시 reload한다. CLI로만 `set`한 UE가 `removed`로 나오면 정상 동작이다(파일이 기준) — 남겨야 했다면 3.6.2의 export로 다시 저장한다.

#### 3.6.5 재부팅 확인
- 명령:
  ```bash
  sudo systemctl reboot
  # 재접속 후
  systemctl is-active vantage-5g vantage-5g-monitor
  journalctl -b -u vantage-5g --no-pager | tee ~/vt-l4/3.6.5-boot-journal.txt
  systemd-analyze critical-chain vantage-5g.service --no-pager | head -12 | tee ~/vt-l4/3.6.5-chain.txt
  sudo vantage-5G export > /tmp/exp.txt
  diff <(grep -vE '^\s*(#|$)' /etc/vantage-5g/policies.conf | awk '{print $1,$2,$3}' | sort) \
       <(grep -v '^#' /tmp/exp.txt | awk '{print $1,$2,$3}' | sort) && echo policies-match
  ip -d link show dev <IF> | grep -o 'prog/xdp[a-z]* id [0-9]*'; tc qdisc show dev <IF>; tc filter show dev <IF> egress | head -2
  ss -ltnp | grep 9090
  ```
- 기대: `active` 두 줄. journal은 3.6.3과 같은 순서(load → applied … added N → attached to `<IF>`). `policies-match`. XDP·root qdisc·egress 필터가 3.3과 같다. 9090이 MONITOR_ARGS 주소에서 LISTEN. 이후 4장 측정을 이 상태에서 다시 해도 된다(4.1의 `set` 대신 policies.conf + 3.6.4 reload).
- 실패 시: preflight status=6(`did not appear within …s`)이면 NIC가 늦게 올라온 것이다. `journalctl -b | grep -iE '<IF>|link'`로 NIC가 나타난 시각을 기록하고 env의 `IFACE_WAIT_SEC`를 늘린다. 장치가 생길 때까지 시작을 미루려면 `sudo systemctl edit vantage-5g`로 `[Unit]`에 `BindsTo=sys-subsystem-net-devices-<IF>.device`와 `After=sys-subsystem-net-devices-<IF>.device`를 넣는 방법도 있다(로컬 미검증, 기록). 정책이 다르면 3.6.2의 파일 내용과 export를 함께 보고한다. 서비스가 `inactive`이고 `is-enabled`가 `disabled`이면 `sudo systemctl enable vantage-5g vantage-5g-monitor`.

#### 3.6.6 stop / start / restart
- 명령:
  ```bash
  sudo systemctl stop vantage-5g; echo rc=$?
  systemctl is-failed vantage-5g; systemctl is-active vantage-5g-monitor
  ls /sys/fs/bpf/vantage 2>&1 | head -1; ip -d link show dev <IF> | grep -c prog/xdp; tc qdisc show dev <IF>
  curl -s http://127.0.0.1:9090/metrics | grep -c '^vantage_ue_policy_'
  sudo systemctl start vantage-5g; systemctl is-active vantage-5g vantage-5g-monitor
  systemctl show -p MainPID --value vantage-5g-monitor
  sudo systemctl restart vantage-5g; systemctl is-active vantage-5g vantage-5g-monitor
  systemctl show -p MainPID --value vantage-5g-monitor; sleep 2; curl -s http://127.0.0.1:9090/metrics | grep -c '^vantage_ue_policy_'
  ```
- 선택 확인(monitor가 main을 끌어오지 않음, Q8-11): `sudo systemctl stop vantage-5g; sudo systemctl restart vantage-5g-monitor; systemctl is-active vantage-5g vantage-5g-monitor; ls /sys/fs/bpf/vantage 2>&1 | head -1; sudo systemctl start vantage-5g` → `inactive`, `active`, `No such file or directory`(점검 중 monitor를 재시작해도 load·attach가 일어나지 않는다). 마지막 start로 원래 상태로 돌린다.
- 기대: stop rc=0. `is-failed`가 `inactive`(failed 아님), monitor는 `active`로 남는다(monitor 유닛은 `After=vantage-5g.service`만 두고 의존 관계가 없다. 핀이 없는 동안 journal에 scrape 오류 1회, `/metrics`의 UE 시리즈 없음). `/sys/fs/bpf/vantage` 없음(`No such file or directory`), `prog/xdp` 0줄, root qdisc는 5.2와 같은 커널 기본값. start 후 두 유닛 모두 `active`(monitor는 처음부터 계속 실행 중). restart 후 둘 다 `active`이고 monitor PID는 **그대로**이며 `/metrics`에 UE 시리즈가 다시 나온다(새 맵을 다시 읽음). restart = detach → unload → load → apply → setup(짧은 셰이핑 공백). monitor까지 멈추려면 `sudo systemctl stop vantage-5g-monitor vantage-5g`.
- 실패 시: **stop은 정리에 실패해도 rc=0을 돌려준다.** `is-failed`가 `failed`이면 `journalctl -u vantage-5g -n 20`에서 `Vantage programs are still attached:` 아래 목록을 확인하고, 각 인터페이스에 `sudo /usr/local/lib/vantage-5g/detach.sh <iface>` → `sudo vantage-5G unload` → `sudo systemctl reset-failed vantage-5g`. 그 전까지 핀은 유지되고 CLI로 정책을 계속 바꿀 수 있다.

### 3.7 Prometheus exporter 노출과 Grafana 대시보드 (VERIFY-L4)
`/metrics`에는 모든 UE의 IP·정책·카운터가 나온다. 3.7.1은 서비스(3.6)를 설치했다면 반드시 하고, 3.7.2와 3.7.3은 원격 Prometheus나 Grafana를 쓸 때만 한다. 기호: `<MGMT_IP>`는 서비스 노드의 관리망 주소, `<PROM_IP>`는 Prometheus 호스트 주소다. 둘 다 N6 쪽이 아니어야 한다.

#### 3.7.1 N6·UE 쪽에서 9090이 보이지 않는가
- 명령:
  ```bash
  ss -ltnp | grep 9090 | tee ~/vt-l4/3.7.1-ss.txt
  # [UPF 호스트] (N6 쪽에서)
  curl -m3 -s -o /dev/null -w '%{http_code}\n' http://<SVC>:9090/metrics; echo rc=$?
  # [UE 호스트] (5G 경로로)
  curl -m3 --interface uesimtun0 -s -o /dev/null http://<SVC>:9090/metrics; echo rc=$?
  ```
- 기대: `ss`에는 `127.0.0.1:9090`(또는 3.7.2의 `<MGMT_IP>:9090`) 한 줄만 있다. UPF 호스트와 UE 쪽 curl은 둘 다 연결에 실패한다(`000`, rc=7 또는 28).
- 실패 시: 200이 나오면 `MONITOR_ARGS`에 `--bind`가 없거나 N6 주소로 bind된 것이다. env를 고친 뒤 `sudo systemctl restart vantage-5g-monitor`를 실행하고(3.6.2) 다시 확인한다. 수동으로 `vantage-5G monitor`를 띄운 경우에는 기본값이 `0.0.0.0`이므로 `--bind`를 붙여 다시 띄운다.

#### 3.7.2 원격 scrape: 관리망 bind + 방화벽 (선택)
- 명령:
  ```bash
  sudoedit /etc/vantage-5g/vantage-5g.env         # MONITOR_ARGS=--bind <MGMT_IP> --port 9090
  sudo systemctl restart vantage-5g-monitor
  ss -ltnp | grep 9090 | tee ~/vt-l4/3.7.2-ss.txt
  sudo ufw status | head -1
  ```
  방화벽으로 `<PROM_IP>`만 허용한다.
  - **ufw가 이미 active이면:** `sudo ufw allow from <PROM_IP> to <MGMT_IP> port 9090 proto tcp`
  - **ufw가 inactive이면:** 이 목적만으로 `ufw enable`을 하지 않는다. 기본 정책(default deny incoming)이 SSH와 4장의 iperf3 5201~5204를 막는다. 꼭 켜야 하면 `sudo ufw allow OpenSSH; sudo ufw allow 5201:5204/tcp`와 위 규칙을 **먼저** 넣고 켠다. 아니면 9090만 막는다: `sudo iptables -A INPUT -p tcp --dport 9090 ! -s <PROM_IP> -j DROP`(영구화는 1.5a (B)와 같은 방법).
  - 확인: [Prometheus 호스트] `curl -m3 -s http://<MGMT_IP>:9090/metrics | grep -c '^vantage_'`, [UPF 호스트] `curl -m3 http://<MGMT_IP>:9090/metrics; echo rc=$?`
- 기대: `ss`에 `<MGMT_IP>:9090` 한 줄만 있다. Prometheus 호스트에서는 줄 수가 0보다 크고, UPF 호스트에서는 실패한다. 3.7.1을 다시 실행해도 같은 결과다.
- 실패 시: `ss`가 바뀌지 않았으면 `restart vantage-5g`를 실행한 것이다. `vantage-5g-monitor`를 재시작한다. monitor가 `failed`이면 `journalctl -u vantage-5g-monitor -n 20`에서 bind 오류(주소가 이 호스트에 없음, 포트 사용 중)를 확인한다.

#### 3.7.3 Grafana 대시보드 (선택, `dashboards/README.md`)
대시보드는 로컬에서 Grafana 11.2.0 / Prometheus 2.54.1로 provisioning과 모든 패널 쿼리가 오류 없이 도는 것까지 확인했다. 정책 표 transformation은 브라우저 밖에서 `@grafana/data` 11.2.0으로만 실행했다. **Grafana UI 렌더링은 확인하지 않았고, 이 절에서 확인한다.** `schemaVersion` 39라 Grafana 10.4 이상이면 로드될 것으로 예상하지만 검증하지 않았다.
- 명령: 관리망 호스트의 Prometheus에 `job_name: vantage-5g`, `targets: ["<MGMT_IP>:9090"]`를 넣는다(서비스 노드 자체에서 돌리면 `127.0.0.1:9090`). 4장 측정 중에는 `scrape_interval: 1s`로 둔다. Grafana에서 Dashboards → Import → `dashboards/vantage-5g.json`을 올리고 *Prometheus* 드롭다운에서 데이터 소스를 고른다. Grafana·Prometheus 버전을 기록한다.
- 기대: Prometheus Targets에서 `vantage-5g` 타깃이 UP이다. 대시보드의 *Exporter* 변수에 서비스 노드가, *UE* 변수에 policies.conf(또는 4.1)의 UE가 나온다. *UEs with a policy*가 정책 수와 같고, *Exporter scrape*가 1이다. 정책 표는 UE마다 한 행이고 exporter 열이 있다.
- 실패 시: *Exporter scrape*가 No data이면 `job_name`이 `vantage-5g`가 아닌 것이다(패널 쿼리가 `up{job="vantage-5g"}`). 처리량 패널이 비어 있으면 rate window를 scrape 간격의 3배 이상으로 고른다(`dashboards/README.md` §1). 화면 이상(표 열 순서, `KILLSWITCH`/`uncapped` 표시, ±10% 선)은 스크린샷과 함께 보고한다.

## 4. README §8 측정 (4세션 동시)

### 4.0 [UE 호스트] UE IP 확인과 5G 경로 바인딩 확인 (README §8.1)
- 명령:
  ```bash
  ip -br -4 addr show | grep uesimtun | tee ~/vt-l4/4.0-ue-ips.txt
  ip -4 addr show uesimtun0
  ip route get <SVC> from <UE_A>
  ip route get <SVC> from <UE_B>
  ```
- 기대: PDU 세션마다 `uesimtunN`이 하나씩 있고 주소가 `<UE_NET>` 안에 있다(UERANSIM 기본 설정이면 `10.45.0.2/24`처럼 `/24`로 표시된다. UE IP는 `/24`를 뺀 주소. Open5GS 레퍼런스 설치는 등록 순서대로 `10.45.0.2`, `10.45.0.3`, …을 준다 — L3 로컬 확인). 이 주소로 런북 전체의 `<UE_A>`, `<UE_B>`(`spec.csv`의 `ue_ip` 포함)를 바꾼다. `ip route get … from <UE_x>`가 `dev uesimtunN`을 출력한다.
- 실패 시: `uesimtun`이 없으면 UE가 등록·PDU 세션 수립을 못 한 것이다(UERANSIM `nr-ue` 로그 확인). `ip route get … from`이 `uesimtunN`이 아닌 LAN NIC를 출력하면 `-B`만으로는 5G 경로를 타지 않는다 — 4.2에서 UERANSIM `build/`의 `nr-binder`를 쓴다.

### 4.1 정책
- 명령:
  ```bash
  sudo ./target/release/vantage-5G set --ue-ip <UE_A> --rx-mbps 10 --tx-mbps 20
  sudo ./target/release/vantage-5G set --ue-ip <UE_B> --rx-mbps 3  --tx-mbps 5
  sudo ./target/release/vantage-5G list
  ```
  (업그레이드였다면 2.1의 정책도 모두 다시 set한다.)
  서비스(3.6)로 운영 중이면 `set` 대신 policies.conf에 두 줄을 쓰고 `sudo systemctl reload vantage-5g`(3.6.4)로 적용해도 된다. `set`으로 바꾼 정책은 reload·restart·재부팅 때 사라지므로, 측정 후에도 남길 정책은 3.6.2처럼 `export`로 저장한다.
- 기대: `[+] policy set: UE <UE_A> rx=10 Mbps tx=20 Mbps` 등이 출력되고, `list`에 두 UE가 나온다.
- 실패 시: `open pinned ue_policy_map (run `vantage-5G load` first; needs root)`이면 3.2(load)와 `sudo`를 확인한다. `invalid value … for '--ue-ip <UE_IP>'`(rc=2)이면 4.0의 주소를 접두사 길이 없이(`10.45.0.2/24`가 아니라 `10.45.0.2`) 넣었는지 확인한다.
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
  4.0에서 `ip route get … from`이 `uesimtunN`이 아니었다면 `-B` 대신 UERANSIM `build/` 디렉토리의 `nr-binder`로 실행한다. `nr-binder`는 `./libdevbnd.so`를 상대 경로로 preload하므로 `build/`에서 실행한다(예: `cd ~/UERANSIM/build && ./nr-binder <UE_A> iperf3 -c <SVC> -p 5201 -t 30 -J > ~/vt-l4/a_ul.json &`).
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
- Ubuntu 24.04 서버라면 B-UL(3 Mbps) 행을 따로 기록한다. 로컬 24.04 VM에서는 이 행만 counter -9~-12%로 미달한 적이 있다(X10b, 미분류. 22.04는 ±0.4%). 미달이면 B-UL 단독(`iperf3 -c <SVC> -B <UE_B> -p 5202 -t 30 -J > b_ul_solo.json`, 같은 방식의 stats 스냅샷)을 한 번 더 측정해 4세션 결과와 비교한다.
- 실패 시: cap **초과**면 즉시 보고한다(`tc qdisc show dev <IF>`, `stats` 증가 여부, 1.4/1.7 NAT, 4.0 바인딩, `ip route get <UE_A>`가 `dev <IF>`인지). 미달이면 4.3과 서버 CPU(`mpstat -P ALL 1`)를 함께 기록한다.

### 4.3 측정 직후 상태
- 명령: `sudo ./target/release/vantage-5G stats; tc -s qdisc show dev <IF>; ethtool -S <IF> | grep -iE 'drop|miss' | head`
- 기대: 정상 TCP에서는 tx_drops가 0 근처다. fq `dropped`는 작다.

### 4.3a 미달 분류용 커널 셰이퍼 대조 (선택, 4.2에서 DL이 cap보다 10% 넘게 낮을 때)
경로 자체가 cap을 못 내는 것인지, 페이서 문제인지를 가른다. 같은 NIC에서 커널 `fq maxrate`(플로우당 상한)로 같은 속도를 걸어 단일 DL 플로우를 잰다. 로컬 VM에서 쓰던 timer-health 점검은 VM 전용이라 물리 서버에서는 하지 않는다. 대조 중에는 `<UE_A>`가 셰이핑되지 않으니 트래픽이 없는 시간에 한다.
- 명령:
  ```bash
  sudo ./target/release/vantage-5G reset --ue-ip <UE_A>
  sudo tc qdisc del dev <IF> root; sudo tc qdisc add dev <IF> root fq maxrate 20mbit
  # [UE 호스트] iperf3 -c <SVC> -B <UE_A> -p 5203 -t 30 -R -J > ~/vt-l4/a_dl_kfq.json
  # 복구 — replace root fq로는 maxrate가 남으므로 반드시 del 후 setup.sh
  sudo tc qdisc del dev <IF> root; sudo ./setup.sh <IF>; echo rc=$?     # 서비스로 운영 중이면: sudo systemctl restart vantage-5g
  sudo ./target/release/vantage-5G set --ue-ip <UE_A> --rx-mbps 10 --tx-mbps 20
  tc qdisc show dev <IF>
  ```
- 기대: 커널 fq도 4.2의 A-DL과 같은 폭으로 미달하면 경로·환경 문제로 기록한다(서버 CPU, NIC 오프로드, 무선 구간). 커널 fq는 20에 맞는데 Vantage만 미달하면 datapath로 보고한다. 복구 뒤 `setup.sh` rc=0이고 qdisc가 3.3과 같다.
- 실패 시: 복구 후 `tc qdisc show`에 `maxrate`가 남아 있으면 del과 `setup.sh`를 다시 실행한다.

### 4.4 멀티큐 UL 경합 (X14)
- 명령: [UE 호스트] `iperf3 -c <SVC> -B <UE_A> -p 5201 -t 30 -P 8 -J > a_ul_p8.json`, 동시에 4.2처럼 stats 스냅샷을 남긴다.
- 기대: counter 판정 A-UL이 +10% 이하다.
- 실패 시: 초과 폭과 큐 수(`ethtool -l`)를 기록한다(D5a 잔여 경합, datapath로 이관).

### 4.4a 멀티큐 DL 다중 플로우 (X20, TX 큐 ≥ 2일 때)
- 명령: [UE 호스트] `iperf3 -c <SVC> -B <UE_A> -p 5203 -t 30 -R -P 4 -J > a_dl_p4.json`, 동시에 4.2처럼 stats 스냅샷을 남긴다. 측정 전후 [서비스 노드] `tc -s qdisc show dev <IF> | tee ~/vt-l4/4.4a-qdisc-before.txt`(끝나면 `…-after.txt`).
- 기대: counter 판정 A-DL(cap 20)이 ±10%. 큐별 `fq`의 `Sent` 증가분이 2개 이상의 큐에 나뉜다(플로우가 여러 큐로 퍼진 상태에서도 UE 합계가 cap).
- 실패 시: cap 초과면 즉시 보고한다(큐별 `fq` 여부 — 3.3의 qdisc 출력). 모든 증가가 한 큐에만 있으면 기록만 한다(플로우 해시 결과).

### 4.5 killswitch, D4 (선택)
- killswitch: `sudo ./target/release/vantage-5G set --ue-ip <UE_B> --rx-mbps 3 --tx-mbps 0`(출력 끝 `(killswitch: DL blocked)`) 후 [UE 호스트]에서 `ping -I <UE_B의 uesimtunN> -c3 <SVC>`가 실패하고, `ping -I <UE_A의 uesimtunN> -c3 <SVC>`는 정상이어야 한다. `stats`에서 `<UE_B>`의 TX_DROPS가 증가한다. 이어서 `set … --tx-mbps 5`로 복구한다.
- D4: UE-A를 tx 1 Mbps로 두고 서비스 노드 뒤(포워딩되는 쪽) 호스트에서 UE-A로 UDP 100M을 10 s 보낸다. 직후 TCP DL이 연결되고 1 Mbps 근처가 나와야 한다. tx_drops 증가는 정상이다. 끝나면 정책을 원래대로 돌린다.

### 4.6 측정 중 대시보드 판독 (선택, 3.7.3을 했을 때 — VERIFY-L4)
- 명령: 4.2 실행 중, 4.5 killswitch 중, `reset` 직후, 5.2 unload 직후에 Grafana 화면을 캡처한다(`~/vt-l4/4.6-*.png`). rate window는 15s(scrape 1s면 5s도 된다).
- 기대:
  - 4.2: *DL/UL throughput vs cap*에서 UE별 선이 cap 점선 근처에 있다. *realized / cap (%)*는 90~110% 선 안에 있고, 그 값이 `counter_verdict.py`의 err%와 몇 % 안에서 맞는다(둘 다 L2 바이트 기준). 정책 표의 행 수는 UE 수와 같다.
  - 4.5 killswitch: 정책 표의 TX cap이 `KILLSWITCH`, *Killswitch UEs* = 1, *DL drops/s*가 증가한다. 복구 후에는 0으로 돌아간다.
  - `sudo ./target/release/vantage-5G reset --ue-ip <UE_B>` 후: *UEs with counters but no policy* = 1이고, `<UE_B>`가 정책 표에서 빠진다. 확인했으면 다시 `set`한다.
  - 5.2 unload 후: vantage 시리즈가 모두 사라지고 *Exporter scrape*는 1이다.
- 실패 시: 비율이 counter 판정과 크게 다르면 rate window와 scrape 간격을 기록한다. 화면 이상(표 열·값 매핑·임계선)은 스크린샷과 함께 보고한다.

## 5. detach → unload → 잔존물

(나) 서비스(3.6)로 운영 중이면 5.2의 수동 detach/unload 대신 `sudo systemctl stop vantage-5g`(3.6.6)를 쓰고, 5.2와 같은 잔존물 확인을 한다. 서버에서 빼려면 5.3을 쓴다. 서비스가 active인 상태에서 수동으로 unload하면 유닛은 `active (exited)`로 남고, 이후 `reload`는 맵이 없어 실패한다. 5.1의 unload 가드 확인은 서비스 상태에서도 그대로 할 수 있다.

### 5.1 unload 가드
- 명령: `sudo ./target/release/vantage-5G unload; echo rc=$?`
- 기대: attach 상태이므로 rc=1이고, `<IF>: xdpgeneric prog id … (vantage_rx_poli)`(native로 붙였으면 `xdp(native) prog id …`)와 `run: sudo ./detach.sh <IF>`가 출력된다. 핀은 그대로다.

### 5.2 detach + unload
- 명령: `sudo ./detach.sh <IF>; echo rc=$?; ip -d link show dev <IF> | grep -c prog/xdp; tc filter show dev <IF> egress; tc qdisc show dev <IF>; sudo ./target/release/vantage-5G unload; echo rc=$?; sudo ls /sys/fs/bpf`
- 기대: detach rc=0, `prog/xdp` 0줄(generic·native 슬롯 모두), egress 필터 없음, clsact 없음. root는 커널 기본 qdisc다: 1.8의 TX 큐 N≥2이면 **`mq 0:`**(handle 0, setup.sh의 `mq 1:`이 아님)에 자식이 1.8의 `net.core.default_qdisc` 종류(Ubuntu 기본 `fq_codel`), N=1이면 그 default qdisc 하나. 이전에 직접 넣은 custom qdisc는 복원되지 않는다. unload rc=0, `/sys/fs/bpf`에 `vantage` 없음.
- 실패 시: detach rc=4이면 남은 목록을 보고한다(native 드라이버에서 xdp 잔존은 X2, `setup.sh's root qdisc (mq 1:, per-queue fq) still present`는 root 삭제 실패). root가 `mq 0:`이 아니거나 자식이 default qdisc와 다르면 `tc qdisc show dev <IF>` 출력을 보고한다(X18).

### 5.3 서비스(3.6)를 설치했다면: uninstall
- 명령:
  ```bash
  sudo ./install.sh uninstall 2>&1 | tee ~/vt-l4/5.3-uninstall.txt; echo rc=${PIPESTATUS[0]}
  systemctl list-unit-files | grep -E '^vantage-5g'; ls /usr/local/lib/vantage-5g /usr/local/bin/vantage-5G /sys/fs/bpf/vantage 2>&1; ls /etc/vantage-5g
  sudo ./install.sh uninstall --purge; echo rc=$?; ls /etc/vantage-5g 2>&1
  ```
- 기대: rc=0, `[+] Vantage-5G uninstalled.`, 유닛 파일 없음, lib·심볼릭 링크·핀 없음(`No such file or directory`), `/etc/vantage-5g`는 남아 있다(`removed /usr/local/lib/vantage-5g; kept /etc/vantage-5g`). 설정까지 지우려면 `--purge` → rc=0, `/etc/vantage-5g` 없음. 서버에 계속 둘 것이면 이 단계는 하지 않는다.
- 실패 시: rc=4와 `did not stop cleanly`이면 아무것도 지워지지 않았다. 출력된 대로 `sudo /usr/local/lib/vantage-5g/detach.sh <iface>` 후 다시 `uninstall`한다. rc=5이면 파일은 지워졌지만 핀이 남았고 지울 바이너리가 없다(앞서 `--force`를 쓴 경우): 저장소 빌드로 `sudo ./detach.sh <IF>; sudo ./target/release/vantage-5G unload`.

## 6. 로컬에서 재현하지 못한 항목 체크리스트 (L4에서만 확인 가능)

| # | 항목 | 확인 위치 |
|---|---|---|
| X1 | 새 clone 실행 권한 | 1.3 |
| X2 | native XDP 지원 드라이버(ixgbe/i40e/mlx5 등)에서 detach 후 xdp 잔존 없음 | 5.2 |
| X5 | 실 코어 경로에서 UE IP 노출(NAT 없음), 귀환 경로 | 1.4~1.7 |
| X7 | 멀티큐 NIC: 커널 기본 `mq 0:` → `mq 1:` + 큐별 fq 전환(첫 실행), 재실행 시 qdisc 무변경(handle 동일), 전환 순간 손실·링크 리셋 여부, `net.core.default_qdisc` 원복 | 3.3 |
| X8 | native XDP: 지원 드라이버에서 `--xdp-mode native` rc=0과 `xdp` 표시, 미지원 시 rc=3·generic 복원, attach/detach 시 링크 플랩 시간. 남의 native XDP가 있으면 rc=3 | 3.3a |
| X18 | detach 후 커널 기본 root 복원: 멀티큐 `mq 0:` + default_qdisc 자식, 단일 큐 default_qdisc | 5.2 |
| X19 | `ethtool -L`로 채널을 늘린 뒤 **재실행 없이** 새 큐가 fq인지(`tc qdisc show`), 줄인 뒤 재실행 시 숨은 클래스를 다시 graft하는지(≥5.16), numtxqueues ≫ 사용 큐(예: mlx5 64+)에서 최초 setup 소요 시간·손실 | 3.3 재실행(선택) |
| X21 | `sch_fq`가 builtin인 커널에서 모듈 검사 통과(rc=0) | 3.3 |
| X20 | 큐가 여러 개(수십 개)인 NIC에서 큐별 `fq`의 EDT: 4.2 DL counter 판정, `-P 4` DL에서 UE 합계 cap | 4.2, 4.4a |
| X12 | 22.04/24.04 설치 명령, `bpftool version` | 1.2 |
| X14 | RSS 멀티큐 UL `-P 8` 과다 허용 | 4.4 |
| X15 | BIG TCP 비활성(gro_max_size ≤ 65536), native XDP에서 rx_packets 의미 | 1.8, 4.3 |
| X16 | 다른 netns(컨테이너 등)에 attach된 경우 unload 가드 미검출 | 해당 시 |
| X13 | LRU 조기 퇴출 — 조건은 UE 수가 아니라 CPU 수(nproc > 128 & 커널 < 6.16, 1.1a). stats에서 활성 UE 카운터가 0으로 돌아가는지 | 1.1a, 장기 운영 관찰 |
| X22 | systemd 서비스: 실제 NIC(드라이버 로드 시간, bond/VLAN, netplan)에서 부팅 시 `network-online.target` 이후 `IFACE`가 제때 있는지(preflight 대기 시간), 재부팅 후 attach·정책 복원. 로컬은 systemd-networkd veth로만 확인 | 3.6.5 |
| X23 | systemd 서비스와 native XDP(`XDP_MODE=native`)의 부팅·restart 시 링크 리셋 | 3.6.5, 3.6.6 |
| V20 | 맵 메모리(LRU 3개 memlock 합계 ≈ 4.5 MiB, 커널별 표시 차이) | 3.2 |
| X24 | Grafana UI 렌더링: 정책 표(merge/organize, exporter 열), 값 매핑(`KILLSWITCH`/`uncapped`), ±10% 선, rate window `$__rate_interval` 선택. 로컬은 쿼리와 transformation 로직만 확인했다 | 3.7.3, 4.6 |
| X25 | exporter 노출: N6·UE 쪽에서 9090 불가, 관리망 bind + 방화벽으로 원격 scrape | 3.7.1, 3.7.2 |
| X26 | 실제 다중 노드: Vantage 노드 2대 이상(또는 UPF 2대가 같은 UE 풀 10.45.0.0/16을 쓰는 경우)을 한 Prometheus로 수집 — 정책 표가 exporter 열로 구분되는지, *Exporter scrape*가 `min(up{job="vantage-5g"})`. 로컬은 가짜 exporter 2개로만 확인 | 3.7.3 (해당 시) |
| X27 | 24.04의 B-UL(3 Mbps, 4세션) 미달(X10b, 로컬 VM에서 미분류) | 4.2 |

## 7. 가져올 것
`~/vt-l4/` 전체(서비스 노드와 UE 호스트 양쪽, UPF 호스트의 1.4 출력 포함. 단계별 출력, `nproc`, 3.2의 `bpftool map show` 출력), `*.json` 4~5개, `spec.csv`, 3.6을 했다면 `3.6.*`·`2.4`·`5.3` 출력과 `journalctl -b -u vantage-5g --no-pager` 전체, `stats_t1.txt`, `stats_t2.txt`, `ethtool -i`/`-l` 출력, 커밋 해시, `uname -r`. 3.7을 했다면 `3.7.*` 출력, Prometheus Targets 화면, Grafana 스크린샷(`4.6-*.png`: 4.2 측정 중, killswitch, reset, unload), Grafana·Prometheus 버전. 4.3a를 했다면 `a_dl_kfq.json`, 24.04에서 B-UL 단독을 쟀다면 `b_ul_solo.json`과 그때의 stats 스냅샷.
