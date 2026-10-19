# L4 설치 런북 — 물리 Ubuntu 서버 (22.04 / 24.04)

- 대상 커밋: `311ee1c` (브랜치 dev/harness-local-testbed). 아래 `<COMMIT>`을 이 해시로 바꾼다.
- 로컬 근거: L1 Docker와 L2 VirtualBox(Ubuntu 22.04)에서 전 단계 PASS. L2 24.04는 기능 단계 전부 PASS, 처리량은 호스트 부하로 판정 보류. 상세는 로컬 `_workspace/05_test_report.md`(커밋되지 않음).
- 형식: 각 단계는 **명령 / 기대 결과 / 실패 시** 순서다. `<IF>` = N6 쪽 NIC, `<UE_A>` = 10.45.1.23, `<UE_B>` = 10.45.1.24, `<SVC>` = 서비스 노드의 N6 IP.
- 결과 수집: 단계마다 출력을 `~/vt-l4/<단계>.txt`로 저장(`… 2>&1 | tee ~/vt-l4/<단계>.txt`)하고, 끝나면 디렉토리째 가져온다. 결과 분석은 `06_result_analysis.md`에서 한다.

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
- 실패 시(경고, 중단 아님): `nproc` > 128 이고 커널 < 6.16(22.04 5.15, 24.04 6.8)이면 LRU 상태 맵(16384)이 CPU별 로컬 free list(CPU당 128)로 소진되어 UE가 몇 개뿐이어도 활성 UE의 상태가 퇴출될 수 있다(README §3). 이 조건을 보고서에 명시하고 6장 X13을 반드시 관찰한다.

### 1.2 패키지 (README §3) — X12
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

### 1.4 N6에서 UE IP가 보이는가 (X5, 가장 먼저 확인)
- 명령: UE에서 `<SVC>`로 ping을 보내는 동안 `sudo tcpdump -ni <IF> host <UE_A> -c 5`
- 기대: 출발지가 UE IP(10.45.x.x)인 패킷이 보인다.
- 실패 시: UPF/코어 IP만 보이면 **중단**한다. 코어(Open5GS 등)의 `iptables -t nat -S POSTROUTING`에서 `MASQUERADE` 규칙을 확인하고, 서비스 대역을 NAT에서 제외하도록 코어 관리자에게 요청한다. 이 상태에서는 per-UE 정책이 걸리지 않는다.

### 1.5 NIC 정보 기록 (X2/X7/X8)
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
- 기대: 두 번 모두 rc=0(두 번째는 `already pinned, skipping load`). `/sys/fs/bpf/vantage`에 프로그램 2개와 맵 4개가 있다. 맵 타입은 `lru_hash` 3개(`max_entries 16384`), `ue_policy_map`은 `hash`(`max_entries 1024`)이다. LRU 3개는 load 시 전량 사전 할당되며 `memlock` 합계는 24.04(6.8)에서 약 4.5 MiB(로컬 4,721,856 B), 22.04(5.15)에서는 커널의 계산 방식 차이로 약 1.5 MiB(로컬 1,572,864 B)로 표시된다(05_test_report.md map-sizes-d25). 이 값을 기록한다.
- 실패 시: 2장(업그레이드)으로 간다. 출력 전체를 보고한다.

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

### 4.1 정책
- 명령:
  ```bash
  sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20
  sudo ./target/release/vantage-5G set --ue-ip 10.45.1.24 --rx-mbps 3  --tx-mbps 5
  sudo ./target/release/vantage-5G list
  ```
  (업그레이드였다면 2.1의 정책도 모두 다시 set한다.)
- 기대: 두 UE가 목록에 나온다.
- D26 확인: 같은 명령을 한 번 더 실행한다(`set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20`). 출력 끝에 `(unchanged; rx/tx state kept)`가 붙어야 한다 — 같은 값 재적용은 정책만 덮어쓰고 RX 토큰버킷·TX EDT 상태를 유지한다(주기적 재적용에도 버스트/백로그 망각 없음). 값이 바뀌면 이 문구가 없고 상태가 초기화된다. 상태를 강제로 초기화하려면 `reset` 후 `set`한다. 운영 스크립트가 주기적으로 `set`을 재적용한다면 그 동작이 이 의미를 전제로 하는지 확인한다.

### 4.2 서버와 클라이언트
- 서비스 노드: `for p in 5201 5202 5203 5204; do iperf3 -s -p $p -D; done`
- UE-A: `iperf3 -c <SVC> -p 5201 -t 30 -J > a_ul.json & iperf3 -c <SVC> -p 5203 -t 30 -R -J > a_dl.json & wait`
- UE-B: `iperf3 -c <SVC> -p 5202 -t 30 -J > b_ul.json & iperf3 -c <SVC> -p 5204 -t 30 -R -J > b_dl.json & wait`
- 네 세션을 **같은 순간**에 시작한다.
- 서비스 노드에서 동시에 counter 스냅샷(X3 B안)을 남긴다:
  ```bash
  ( sleep 5;  { echo "t=$(date +%s.%N)"; sudo ./target/release/vantage-5G stats; } > ~/vt-l4/stats_t1.txt
    sleep 24; { echo "t=$(date +%s.%N)"; sudo ./target/release/vantage-5G stats; } > ~/vt-l4/stats_t2.txt ) &
  ```
- spec.csv(json 4개와 같은 디렉토리):
  ```
  label,ue_ip,direction,cap_mbps,json_path
  A-UL,10.45.1.23,UL,10,a_ul.json
  B-UL,10.45.1.24,UL,3,b_ul.json
  A-DL,10.45.1.23,DL,20,a_dl.json
  B-DL,10.45.1.24,DL,5,b_dl.json
  ```
- 판정(가져와서 로컬): `python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py spec.csv`와 `python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py spec.csv stats_t1.txt stats_t2.txt`
- 기대: counter 판정 4세션 모두 ±10%(로컬 jammy 기준 ±0.3%). iperf goodput ±10%(UL은 헤더와 ACK 때문에 -1~-7%가 정상).
- 실패 시: cap **초과**면 즉시 보고한다(`tc qdisc show dev <IF>`, `stats` 증가 여부, 1.4 NAT). 미달이면 4.3과 서버 CPU(`mpstat -P ALL 1`)를 함께 기록한다.

### 4.3 측정 직후 상태
- 명령: `sudo ./target/release/vantage-5G stats; tc -s qdisc show dev <IF>; ethtool -S <IF> | grep -iE 'drop|miss' | head`
- 기대: 정상 TCP에서는 tx_drops가 0 근처다. fq `dropped`는 작다.

### 4.4 멀티큐 UL 경합 (X14)
- 명령: UE-A에서 `iperf3 -c <SVC> -p 5201 -t 30 -P 8 -J > a_ul_p8.json`, 동시에 4.2처럼 stats 스냅샷을 남긴다.
- 기대: counter 판정 A-UL이 +10% 이하다.
- 실패 시: 초과 폭과 큐 수(`ethtool -l`)를 기록한다(D5a 잔여 경합, datapath로 이관).

### 4.5 killswitch, D4 (선택)
- killswitch: `sudo ./target/release/vantage-5G set --ue-ip 10.45.1.24 --rx-mbps 3 --tx-mbps 0` 후 UE-B에서 `ping -c3 <SVC>`가 실패하고 UE-A는 정상이어야 한다. 이어서 `set … --tx-mbps 5`로 복구한다.
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
| X5 | 실 코어 경로에서 UE IP 노출(NAT 없음) | 1.4 |
| X7 | 멀티큐 NIC(root `mq`)에서 setup.sh 재실행 rc=0, 공백 없음 | 3.3 |
| X8 | native XDP NIC에서 generic attach 동작 / 수동 `xdpdrv` attach 시 exit 3 | 3.3 |
| X12 | 22.04/24.04 설치 명령, `bpftool version` | 1.2 |
| X14 | RSS 멀티큐 UL `-P 8` 과다 허용 | 4.4 |
| X15 | BIG TCP 비활성(gro_max_size ≤ 65536), native XDP에서 rx_packets 의미 | 1.5, 4.3 |
| X16 | 다른 netns(컨테이너 등)에 attach된 경우 unload 가드 미검출 | 해당 시 |
| X13 | LRU 조기 퇴출 — 조건은 UE 수가 아니라 CPU 수(nproc > 128 & 커널 < 6.16, 1.1a). stats에서 활성 UE 카운터가 0으로 돌아가는지 | 1.1a, 장기 운영 관찰 |
| V20 | 맵 메모리(LRU 3개 memlock 합계 ≈ 4.5 MiB, 커널별 표시 차이) | 3.2 |

## 7. 가져올 것
`~/vt-l4/` 전체(단계별 출력, `nproc`, 3.2의 `bpftool map show` 출력), `*.json` 4~5개, `spec.csv`, `stats_t1.txt`, `stats_t2.txt`, `ethtool -i`/`-l` 출력, 커밋 해시, `uname -r`.
