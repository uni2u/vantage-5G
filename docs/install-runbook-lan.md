# L4 설치 런북 (LAN) — 5G 코어 없는 첫 배포: 서비스 노드 + 노트북 2대

5G 코어(Open5GS·UERANSIM) 없이 물리 서비스 노드에 Vantage-5G를 설치하고, 같은 서브넷의 노트북 2대를 UE-A·UE-B로 써서 측정한다. 5G 경로(UPF NAT, 귀환 경로, `uesimtun`)는 다른 파트가 코어를 설치한 뒤 [`install-runbook.md`](install-runbook.md)로 확인한다(14장).

- **복사·붙여넣기만으로 진행한다.** 손으로 고치는 것은 0.2의 변수 파일 한 번뿐이다. 이후 모든 명령은 `"$IF"`, `"$SVC"`, `"$UE_A"`, `"$UE_B"` 같은 변수만 쓴다.
- 대상 커밋: `main`의 `3971b36`(PR #8) 이후. 제품 코드(src/, *.c, setup.sh, detach.sh, install.sh, systemd/)는 `3971b36`과 같다. `COMMIT`(0.2)에는 이 문서가 들어간 뒤의 main 해시를 쓴다.
- 로컬 근거(2026-10-21): 이 문서의 코드 블록 51개를 그대로 추출해 Ubuntu 22.04 VM(5.15.0-198) 안의 같은 서브넷 토폴로지에서 처음부터 끝까지 수정 없이 실행했다 — 51/51 PASS, 잔여물 없음, VM 타이머 점검 내내 OK. 4세션 counter 판정 +0.2 / +0.0 / -0.1 / +0.0%. 상세와 한계는 15장.
- 형식: 각 단계는 **명령 / 기대 / 실패 시** 순서다. 명령 블록 위의 굵은 글씨가 그 블록을 붙여넣을 호스트다: **[서비스 노드]**, **[노트북 A]**, **[노트북 B]**. 한 블록은 한 호스트에서만 실행한다.

## 구성

```
 [노트북 A]  UE_A ──┐
                    ├── 스위치 (라우터·NAT 없이 같은 서브넷) ── IF [서비스 노드 SVC]
 [노트북 B]  UE_B ──┘                                           Vantage: XDP RX 폴리서(UL) + tc EDT TX 페이서(DL)
```

- UL = 노트북 → 서비스 노드(iperf3 기본 방향, 정책의 `rx`). DL = 서비스 노드 → 노트북(iperf3 `-R`, 정책의 `tx`).
- 정책 키는 패킷의 노트북 IP다. 노트북과 서비스 노드 사이에 라우터나 NAT가 있으면 정책이 맞지 않는다(2장에서 확인).
- 4세션 측정은 **서비스 노드가 SSH로 두 노트북의 iperf3 클라이언트를 구동**한다(5.2, 아래 "동시 시작 방식").

## 붙여넣기 규칙 (먼저 읽기)

1. **블록 하나씩** 붙여넣고 끝날 때까지 기다린다. 블록은 새 터미널에서 붙여도 되도록 첫 줄에서 변수 파일을 읽고(`source ~/vt-l4/vars.sh`) 저장소로 이동한다(`cd ~/vantage-5G`).
2. 블록이 출력하는 `OK   …` / `FAIL …` 줄이 판정이다. `FAIL`이 하나라도 나오면 다음 블록으로 가지 말고 그 단계의 "실패 시"를 본다.
3. **sudo 비밀번호:** 붙여넣은 블록 중간에 sudo가 비밀번호를 물으면, 터미널에 따라 붙여넣은 나머지 줄이 비밀번호 입력으로 먹힐 수 있다. 각 호스트에서 시작할 때와 15분 넘게 쉰 뒤에는 **먼저 아래 한 줄만** 실행해 비밀번호를 넣는다. 블록 첫머리의 `sudo -v`는 이 캐시를 연장할 뿐이다.
   ```
   sudo -v
   ```
4. 출력은 각 호스트의 `~/vt-l4/`에 쌓인다. 끝나면 11장에서 서비스 노드 한 곳으로 모은다.
5. 측정 블록(5.2, 5.4, 5.5)은 30~70초 걸린다. 그동안 다른 블록을 붙여넣지 않는다.

### 동시 시작 방식과 근거

4세션(UE별 UL·DL)을 같은 순간에 시작해야 한다. 두 가지 방법을 비교했다.

| | (가) 서비스 노드에서 SSH로 구동 — **채택** | (나) NTP 동기화 후 같은 epoch까지 대기 |
|---|---|---|
| 붙여넣기 | 측정 1회 = 서비스 노드에서 블록 1개 | 측정 1회 = 노트북 2대 + 서비스 노드에 블록 3개를 시간 안에 |
| 시계 | 서비스 노드 시계 하나. stats 스냅샷(t1·t2)과 클라이언트 시작이 같은 셸에서 순서대로 | 세 호스트 시계가 수백 ms 안으로 맞아야 함. 라우터 없는 LAN에서는 NTP 서버에 닿지 않아 `timedatectl`이 `System clock synchronized: no`로 남기 쉽다 |
| 결과 | iperf3 JSON이 SSH 표준출력으로 서비스 노드에 바로 저장 → spec.csv·판정까지 같은 블록 | 노트북마다 JSON을 만들고 나중에 scp로 모아야 함 |
| 준비 | 노트북에 `openssh-server`, 서비스 노드 키를 노트북에 한 번 등록(2.6, 비밀번호 2번 입력) | 노트북 NTP 설정(인터넷 또는 LAN NTP 서버) |
| 실패 모드 | SSH 연결 실패는 즉시 보이고(BatchMode, 5 s 제한) 그 세션 JSON이 비어 판정이 FAIL | 시작 시각을 놓친 호스트는 늦게 시작해 겹치는 구간이 줄어도 조용히 진행됨 |

SSH 시작 지연은 세션당 수백 ms라 판정(앞 5 s 제외, counter 창 t1≈+5 s~t2≈+25 s)에 영향이 없다. SSH 제어 트래픽도 UE의 정책에 포함되지만 측정 중에는 거의 없다. 단, **killswitch(6장) 동안에는 노트북 B로 SSH가 되지 않으므로** 6장은 각 노트북에서 직접 붙여넣는다.

## 0. 변수 파일 (호스트마다 한 번)

### 0.1 변수 파일 만들기
같은 내용을 세 호스트에 만든다. 블록마다 `ROLE`만 미리 채워져 있다. 이미 파일이 있으면 덮어쓰지 않는다(0.2에서 고친 값 보호).

<!-- rh: id=0.1-svc host=svc -->
**[서비스 노드]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G LAN runbook variables (docs/install-runbook-lan.md)
# Replace every CHANGE_ME once, on this host:  nano ~/vt-l4/vars.sh
ROLE=svc              # this host: svc | a | b  (pre-filled by the block)
IF=CHANGE_ME          # THIS host's wired LAN NIC name (ip -br -4 addr), e.g. enp1s0
SVC=CHANGE_ME         # service node LAN IP, no prefix, e.g. 192.168.77.10
UE_A=CHANGE_ME        # laptop A wired LAN IP, e.g. 192.168.77.21
UE_B=CHANGE_ME        # laptop B wired LAN IP, e.g. 192.168.77.22
# --- service node only (leave CHANGE_ME on the laptops) ---
UE_A_USER=CHANGE_ME   # login user on laptop A (the service node runs iperf3 there over SSH)
UE_B_USER=CHANGE_ME   # login user on laptop B
COMMIT=CHANGE_ME      # commit hash to install (main after the LAN runbook PR)
# --- measurement policy (README section 8 values; no need to change) ---
A_RX=10; A_TX=20; B_RX=3; B_TX=5
XDP_MODE=generic      # systemd service XDP mode (8.2): generic, or native if 3.4 gave rc=0
# --- do not edit below ---
case "$ROLE" in svc) ME=$SVC ;; a) ME=$UE_A ;; b) ME=$UE_B ;; *) ME= ;; esac
SSHO=(-i "$HOME/.ssh/vt_l4" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
vt_snap() { { echo "t=$(date +%s.%N)"; sudo "$HOME/vantage-5G/target/release/vantage-5G" stats; } > "$1"; }
if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
if grep -qE '^(IF|SVC|UE_A|UE_B)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook 0.2)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```

<!-- rh: id=0.1-a host=a -->
**[노트북 A]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G LAN runbook variables (docs/install-runbook-lan.md)
# Replace every CHANGE_ME once, on this host:  nano ~/vt-l4/vars.sh
ROLE=a                # this host: svc | a | b  (pre-filled by the block)
IF=CHANGE_ME          # THIS host's wired LAN NIC name (ip -br -4 addr), e.g. enp0s31f6
SVC=CHANGE_ME         # service node LAN IP, no prefix, e.g. 192.168.77.10
UE_A=CHANGE_ME        # laptop A wired LAN IP, e.g. 192.168.77.21
UE_B=CHANGE_ME        # laptop B wired LAN IP, e.g. 192.168.77.22
# --- service node only (leave CHANGE_ME on the laptops) ---
UE_A_USER=CHANGE_ME
UE_B_USER=CHANGE_ME
COMMIT=CHANGE_ME
# --- measurement policy (README section 8 values; no need to change) ---
A_RX=10; A_TX=20; B_RX=3; B_TX=5
XDP_MODE=generic
# --- do not edit below ---
case "$ROLE" in svc) ME=$SVC ;; a) ME=$UE_A ;; b) ME=$UE_B ;; *) ME= ;; esac
SSHO=(-i "$HOME/.ssh/vt_l4" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
if grep -qE '^(IF|SVC|UE_A|UE_B)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook 0.2)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```

<!-- rh: id=0.1-b host=b -->
**[노트북 B]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G LAN runbook variables (docs/install-runbook-lan.md)
# Replace every CHANGE_ME once, on this host:  nano ~/vt-l4/vars.sh
ROLE=b                # this host: svc | a | b  (pre-filled by the block)
IF=CHANGE_ME          # THIS host's wired LAN NIC name (ip -br -4 addr), e.g. enp0s31f6
SVC=CHANGE_ME         # service node LAN IP, no prefix, e.g. 192.168.77.10
UE_A=CHANGE_ME        # laptop A wired LAN IP, e.g. 192.168.77.21
UE_B=CHANGE_ME        # laptop B wired LAN IP, e.g. 192.168.77.22
# --- service node only (leave CHANGE_ME on the laptops) ---
UE_A_USER=CHANGE_ME
UE_B_USER=CHANGE_ME
COMMIT=CHANGE_ME
# --- measurement policy (README section 8 values; no need to change) ---
A_RX=10; A_TX=20; B_RX=3; B_TX=5
XDP_MODE=generic
# --- do not edit below ---
case "$ROLE" in svc) ME=$SVC ;; a) ME=$UE_A ;; b) ME=$UE_B ;; *) ME= ;; esac
SSHO=(-i "$HOME/.ssh/vt_l4" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
if grep -qE '^(IF|SVC|UE_A|UE_B)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook 0.2)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```
- 기대: `[+] created ~/vt-l4/vars.sh`(다시 붙이면 `already exists`).

### 0.2 값 채우기 (유일한 수동 편집)
세 호스트 각각에서 연다. `CHANGE_ME`를 실제 값으로 바꾸고 저장한다(nano: Ctrl+O, Enter, Ctrl+X).

<!-- rh: id=0.2-svc host=svc mode=edit -->
**[서비스 노드]**
```bash
nano ~/vt-l4/vars.sh
```

<!-- rh: id=0.2-a host=a mode=edit -->
**[노트북 A]**
```bash
nano ~/vt-l4/vars.sh
```

<!-- rh: id=0.2-b host=b mode=edit -->
**[노트북 B]**
```bash
nano ~/vt-l4/vars.sh
```
- 값 찾기: 그 호스트에서 `ip -br -4 addr`. LAN 케이블이 꽂힌 NIC 이름이 `IF`, 그 주소(`/24` 앞)가 `SVC`(서비스 노드) 또는 `UE_A`/`UE_B`(노트북)다. `SVC`, `UE_A`, `UE_B`는 세 호스트에 **같은 값**을 쓴다. `IF`는 호스트마다 다르다(각자의 유선 NIC).
- 노트북의 유선 IP가 DHCP면 측정이 끝날 때까지 바뀌지 않게 고정한다(NetworkManager 수동 주소 또는 DHCP 예약). 바뀌면 정책이 맞지 않는다.
- 서비스 노드의 `UE_A_USER`/`UE_B_USER`는 각 노트북에서 `whoami`로 확인한다. `COMMIT`은 설치할 main 커밋 해시다(이 문서를 포함한 PR이 머지된 뒤의 해시).

### 0.3 값 검증
`FAIL vars:` 줄이 나오면 0.2로 돌아가 고치고 이 블록을 다시 붙인다. 블록 전체가 괄호 하나로 묶여 있어 실패해도 셸이 닫히지 않는다.

<!-- rh: id=0.3-svc host=svc -->
**[서비스 노드]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  for v in ROLE IF SVC UE_A UE_B; do eval "x=\$$v"; if [ "$x" = CHANGE_ME ]; then echo "FAIL vars: $v is still CHANGE_ME"; bad=1; fi; done
  case "$ROLE" in svc|a|b) ;; *) echo "FAIL vars: ROLE=$ROLE (must be svc, a or b)"; bad=1 ;; esac
  for v in SVC UE_A UE_B; do eval "x=\$$v"; echo "$x" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: $v=$x is not an IPv4 address"; bad=1; }; done
  if [ "$SVC" = "$UE_A" ] || [ "$SVC" = "$UE_B" ] || [ "$UE_A" = "$UE_B" ]; then echo "FAIL vars: SVC, UE_A, UE_B must all differ"; bad=1; fi
  if ip link show dev "$IF" >/dev/null 2>&1; then
    ip -4 -o addr show dev "$IF" | grep -qF " $ME/" || { echo "FAIL vars: $IF has no address $ME (check: ip -4 addr show dev $IF)"; bad=1; }
  else echo "FAIL vars: interface IF=$IF does not exist (check: ip -br link)"; bad=1; fi
  if [ "$ROLE" = svc ]; then for v in UE_A_USER UE_B_USER COMMIT; do eval "x=\$$v"; if [ "$x" = CHANGE_ME ]; then echo "FAIL vars: $v is still CHANGE_ME"; bad=1; fi; done; fi
  if [ $bad = 0 ]; then echo "OK   vars: ROLE=$ROLE IF=$IF ME=$ME SVC=$SVC UE_A=$UE_A UE_B=$UE_B"; else echo "FAIL vars: edit ~/vt-l4/vars.sh (0.2) and paste this block again"; fi )
```

<!-- rh: id=0.3-a host=a -->
**[노트북 A]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  for v in ROLE IF SVC UE_A UE_B; do eval "x=\$$v"; if [ "$x" = CHANGE_ME ]; then echo "FAIL vars: $v is still CHANGE_ME"; bad=1; fi; done
  case "$ROLE" in svc|a|b) ;; *) echo "FAIL vars: ROLE=$ROLE (must be svc, a or b)"; bad=1 ;; esac
  for v in SVC UE_A UE_B; do eval "x=\$$v"; echo "$x" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: $v=$x is not an IPv4 address"; bad=1; }; done
  if [ "$SVC" = "$UE_A" ] || [ "$SVC" = "$UE_B" ] || [ "$UE_A" = "$UE_B" ]; then echo "FAIL vars: SVC, UE_A, UE_B must all differ"; bad=1; fi
  if ip link show dev "$IF" >/dev/null 2>&1; then
    ip -4 -o addr show dev "$IF" | grep -qF " $ME/" || { echo "FAIL vars: $IF has no address $ME (check: ip -4 addr show dev $IF)"; bad=1; }
  else echo "FAIL vars: interface IF=$IF does not exist (check: ip -br link)"; bad=1; fi
  if [ $bad = 0 ]; then echo "OK   vars: ROLE=$ROLE IF=$IF ME=$ME SVC=$SVC UE_A=$UE_A UE_B=$UE_B"; else echo "FAIL vars: edit ~/vt-l4/vars.sh (0.2) and paste this block again"; fi )
```

<!-- rh: id=0.3-b host=b -->
**[노트북 B]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  for v in ROLE IF SVC UE_A UE_B; do eval "x=\$$v"; if [ "$x" = CHANGE_ME ]; then echo "FAIL vars: $v is still CHANGE_ME"; bad=1; fi; done
  case "$ROLE" in svc|a|b) ;; *) echo "FAIL vars: ROLE=$ROLE (must be svc, a or b)"; bad=1 ;; esac
  for v in SVC UE_A UE_B; do eval "x=\$$v"; echo "$x" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: $v=$x is not an IPv4 address"; bad=1; }; done
  if [ "$SVC" = "$UE_A" ] || [ "$SVC" = "$UE_B" ] || [ "$UE_A" = "$UE_B" ]; then echo "FAIL vars: SVC, UE_A, UE_B must all differ"; bad=1; fi
  if ip link show dev "$IF" >/dev/null 2>&1; then
    ip -4 -o addr show dev "$IF" | grep -qF " $ME/" || { echo "FAIL vars: $IF has no address $ME (check: ip -4 addr show dev $IF)"; bad=1; }
  else echo "FAIL vars: interface IF=$IF does not exist (check: ip -br link)"; bad=1; fi
  if [ $bad = 0 ]; then echo "OK   vars: ROLE=$ROLE IF=$IF ME=$ME SVC=$SVC UE_A=$UE_A UE_B=$UE_B"; else echo "FAIL vars: edit ~/vt-l4/vars.sh (0.2) and paste this block again"; fi )
```
- 기대: 호스트마다 `OK   vars: ROLE=… IF=… ME=<이 호스트의 IP> …` 한 줄.
- 실패 시: `has no address`면 `IF`가 다른 NIC이거나(무선 NIC를 적은 경우 등) IP 오타다. `does not exist`면 NIC 이름 오타다.

## 1. 서비스 노드 사전 조건

### 1.1 OS, 커널, BTF, CPU 수 (V20, X13)

<!-- rh: id=1.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
{ lsb_release -ds; uname -r; ls -l /sys/kernel/btf/vmlinux; ip -V; nproc; lscpu | grep -E '^CPU\(s\)|NUMA node\(s\)'; } 2>&1 | tee ~/vt-l4/1.1-os.txt
test -f /sys/kernel/btf/vmlinux; vt_ck $? "1.1 BTF present"
```
- 기대: Ubuntu 22.04.x 또는 24.04.x, 커널 5.15 이상, `OK   1.1 BTF present`. `nproc`을 기록한다.
- 실패 시: BTF가 없으면 중단한다(지원 범위 밖). `nproc` > 128 이고 커널 < 6.16이면 LRU 상태 맵이 CPU별 free list로 소진될 수 있다(README §3.1) — 보고서에 적고 X13을 관찰한다(중단 아님).

### 1.2 패키지 (X12)
비대화형으로 설치한다(`iperf3`의 "데몬으로 시작?" 질문, needrestart 대화상자를 건너뜀).

<!-- rh: id=1.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -q 2>&1 | tail -1
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config linux-tools-common "linux-tools-$(uname -r)" iproute2 iperf3 tcpdump ethtool curl git python3 openssh-client 2>&1 | tail -2
bpftool version | tee ~/vt-l4/1.2-bpftool.txt; vt_ck ${PIPESTATUS[0]} "1.2 bpftool usable"
```
- 기대: `OK   1.2 bpftool usable`(`bpftool version`이 버전을 출력, "WARNING: bpftool not found for kernel"이 아님).
- 실패 시: `linux-tools-$(uname -r)` 후보가 없으면(HWE·커스텀 커널) `apt-cache search linux-tools | grep "$(uname -r)"`로 flavour 패키지를 찾는다. `bpftool` 패키지를 따로 찾지 않는다(22.04/24.04 모두 없음).

### 1.3 Rust (rustup, 비대화형)
apt의 `rustc`는 쓰지 않는다(`rust-version = "1.89"`). 변수 파일이 `~/.cargo/env`를 읽으므로 이후 새 셸에서도 `cargo`가 잡힌다.

<!-- rh: id=1.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal 2>&1 | tail -2
source ~/vt-l4/vars.sh
rustc --version | tee ~/vt-l4/1.3-rustc.txt
rustc --version | awk '{split($2, v, "."); exit (v[1] > 1 || v[2] >= 89) ? 0 : 1}'; vt_ck $? "1.3 rustc >= 1.89"
```
- 기대: `rustc 1.xx.x …`와 `OK   1.3 rustc >= 1.89`. 설치 출력의 마지막 두 줄(`tail -2`)은 rustup 버전에 따라 `cargo:rerun-if-env-changed=…` 같은 줄일 수 있다 — 판정은 `OK` 줄로 한다.
- 실패 시: `rustc: command not found`면 `ls ~/.cargo/bin`을 확인한다(설치 실패면 위 출력의 오류를 보고). 1.89 미만이면 `rustup update stable` 후 이 블록을 다시 붙인다.

### 1.4 소스 (X1)

<!-- rh: id=1.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
cd ~ && if [ -d vantage-5G/.git ]; then echo "[i] ~/vantage-5G exists"; else git clone -q https://github.com/uni2u/vantage-5G.git; fi
cd ~/vantage-5G && git fetch -q origin && git checkout -q "$COMMIT"; git log -1 --oneline | tee ~/vt-l4/1.4-commit.txt
ls -l setup.sh detach.sh install.sh | tee -a ~/vt-l4/1.4-commit.txt
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$COMMIT^{commit}" 2>/dev/null)" ]; vt_ck $? "1.4 checked out $COMMIT"
test -x setup.sh && test -x detach.sh && test -x install.sh; vt_ck $? "1.4 scripts executable (X1)"
```
- 기대: `OK` 두 줄. 세 스크립트가 `-rwxr-xr-x`.
- 실패 시: 실행 권한이 없으면 중단하고 보고한다(`bash setup.sh`로 우회하지 않는다). `checkout` 실패면 `COMMIT` 값(0.2)을 확인한다.

### 1.5 NIC 정보 기록 (X2, X7, X8, X15)

<!-- rh: id=1.5 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
{ ethtool -i "$IF"; ethtool -l "$IF"; tc qdisc show dev "$IF"; ip -d link show dev "$IF"; ethtool -k "$IF" | grep -E 'generic-receive|large-receive'; echo "tx queues in use: $(ls -d /sys/class/net/"$IF"/queues/tx-* | wc -l)"; sysctl net.core.default_qdisc; } 2>&1 | tee ~/vt-l4/1.5-nic.txt
ip -d link show dev "$IF" | grep -oE 'gro_max_size [0-9]+|gro_ipv4_max_size [0-9]+' | tee -a ~/vt-l4/1.5-nic.txt
ip -d link show dev "$IF" | grep -q 'prog/xdp'; [ $? = 1 ]; vt_ck $? "1.5 no XDP on $IF yet"
[ -z "$(tc filter show dev "$IF" egress 2>/dev/null)" ]; vt_ck $? "1.5 no egress filter on $IF yet"
```
- 기대: 드라이버(`driver:`), 큐 수, root qdisc, `tx queues in use: N`, `net.core.default_qdisc`가 기록되고 `OK` 두 줄. `gro_max_size`/`gro_ipv4_max_size`가 나오면 65536 이하(X15).
- 실패 시: 다른 도구의 XDP나 egress 필터가 있으면 그 소유자와 먼저 조율한다(`setup.sh`가 rc=3으로 거부한다). gro 값이 65536보다 크면 기록하고 계속한다.

## 2. 노트북 준비와 같은 서브넷 확인

### 2.1 노트북 패키지, SSH 서버, 방화벽
노트북에 `iperf3`, `openssh-server`, `curl`을 설치한다. ufw가 켜져 있으면 서비스 노드의 SSH만 허용한다.

<!-- rh: id=2.1-a host=a -->
**[노트북 A]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -q 2>&1 | tail -1
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q iperf3 openssh-server curl 2>&1 | tail -2
sudo systemctl enable --now ssh 2>&1 | tail -1
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then sudo ufw allow from "$SVC" to any port 22 proto tcp; fi
iperf3 --version | head -1; vt_ck ${PIPESTATUS[0]} "2.1 $ROLE: iperf3 installed"
```

<!-- rh: id=2.1-b host=b -->
**[노트북 B]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -q 2>&1 | tail -1
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q iperf3 openssh-server curl 2>&1 | tail -2
sudo systemctl enable --now ssh 2>&1 | tail -1
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then sudo ufw allow from "$SVC" to any port 22 proto tcp; fi
iperf3 --version | head -1; vt_ck ${PIPESTATUS[0]} "2.1 $ROLE: iperf3 installed"
```
- 기대: `OK   2.1 a: iperf3 installed`(B는 `b`). SSH가 실제로 되는지는 2.6에서 서비스 노드가 확인한다.
- 실패 시: apt가 인터넷에 닿지 않으면(노트북의 인터넷은 보통 Wi-Fi) Wi-Fi를 켠 채로 다시 실행한다. 유선 LAN에 기본 경로가 잡혀 있으면 인터넷이 안 될 수 있다 — 2.2의 `ip route` 출력으로 확인.

### 2.2 노트북 → 서비스 노드 경로 (같은 서브넷, 라우터 없음)
노트북에 Wi-Fi 등 다른 NIC가 있어도 된다. 서비스 노드로 가는 경로만 유선 `IF`로, `via` 없이 나가면 된다. 이후 iperf3는 `-B <노트북 유선 IP>`로 바인딩한다.

<!-- rh: id=2.2-a host=a -->
**[노트북 A]**
```bash
source ~/vt-l4/vars.sh
{ ip -br -4 addr; ip route; ip route get "$SVC"; ip route get "$SVC" from "$ME"; } 2>&1 | tee ~/vt-l4/2.2-route-$ROLE.txt
for r in "$(ip route get "$SVC")" "$(ip route get "$SVC" from "$ME")"; do case "$r" in *" via "*) false ;; *"dev $IF "*) true ;; *) false ;; esac; vt_ck $? "2.2 $ROLE: $SVC on-link via $IF, no gateway"; done
ping -c 3 -W 2 -I "$ME" "$SVC" | tail -2; vt_ck ${PIPESTATUS[0]} "2.2 $ROLE: ping $SVC from $ME"
```

<!-- rh: id=2.2-b host=b -->
**[노트북 B]**
```bash
source ~/vt-l4/vars.sh
{ ip -br -4 addr; ip route; ip route get "$SVC"; ip route get "$SVC" from "$ME"; } 2>&1 | tee ~/vt-l4/2.2-route-$ROLE.txt
for r in "$(ip route get "$SVC")" "$(ip route get "$SVC" from "$ME")"; do case "$r" in *" via "*) false ;; *"dev $IF "*) true ;; *) false ;; esac; vt_ck $? "2.2 $ROLE: $SVC on-link via $IF, no gateway"; done
ping -c 3 -W 2 -I "$ME" "$SVC" | tail -2; vt_ck ${PIPESTATUS[0]} "2.2 $ROLE: ping $SVC from $ME"
```
- 기대: `OK` 세 줄. `ip route get "$SVC"`가 `… dev <IF> src <ME> …`이고 `via`가 없다.
- 실패 시: `via`가 있으면 노트북과 서비스 노드가 다른 서브넷이다(라우터 경유 — 이 구성의 전제가 깨짐). `dev`가 Wi-Fi NIC이면 Wi-Fi가 같은 대역을 쓰는 것이다 — Wi-Fi를 끄거나 다른 네트워크에 연결한다. ping 실패면 케이블·스위치·주소(0.3)와 서비스 노드 방화벽을 본다.

### 2.3 서비스 노드 → 노트북 경로, iperf3 포트

<!-- rh: id=2.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
{ ip -br -4 addr; ip route get "$UE_A"; ip route get "$UE_B"; } 2>&1 | tee ~/vt-l4/2.3-route-svc.txt
for u in "$UE_A" "$UE_B"; do case "$(ip route get "$u")" in *" via "*) false ;; *"dev $IF "*) true ;; *) false ;; esac; vt_ck $? "2.3 $u on-link via $IF, no gateway"; done
for u in "$UE_A" "$UE_B"; do ping -c 3 -W 2 "$u" | tail -1; vt_ck ${PIPESTATUS[0]} "2.3 ping $u"; done
sudo ufw status 2>/dev/null | head -1
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then for u in "$UE_A" "$UE_B"; do sudo ufw allow from "$u" to any port 5201:5204 proto tcp; done; fi
```
- 기대: `OK` 네 줄. ufw가 active이면 `Rule added` 두 줄(5201~5204/tcp, 노트북 주소에서만).
- 실패 시: `ip route get`이 `via`이거나 다른 `dev`이면 DL이 Vantage가 붙은 `IF`로 나가지 않는다(TX 페이서·killswitch 미적용) — 0.2의 `IF`와 서비스 노드 주소 설정을 확인한다.

### 2.4 SSH 키 등록 (서비스 노드 → 노트북, 한 번)
노트북 로그인 비밀번호를 A, B 순서로 한 번씩 묻는다. 호스트 키는 자동으로 받아들인다(`accept-new`).

<!-- rh: id=2.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
mkdir -p -m 700 ~/.ssh; test -f ~/.ssh/vt_l4 || ssh-keygen -q -t ed25519 -N '' -C vantage-vt-l4 -f ~/.ssh/vt_l4
ssh-copy-id -i ~/.ssh/vt_l4.pub -o StrictHostKeyChecking=accept-new "$UE_A_USER@$UE_A" </dev/null 2>&1 | tail -2
ssh-copy-id -i ~/.ssh/vt_l4.pub -o StrictHostKeyChecking=accept-new "$UE_B_USER@$UE_B" </dev/null 2>&1 | tail -2
for h in "$UE_A_USER@$UE_A" "$UE_B_USER@$UE_B"; do ssh "${SSHO[@]}" -n "$h" true; vt_ck $? "2.4 key login to $h"; done
```
- 기대: 노트북마다 비밀번호를 한 번 입력한 뒤 ssh-copy-id 출력 끝(`… make sure that only the key(s) you wanted were added.`, 이미 등록되어 있으면 `All keys were skipped because they already exist`)과 `OK` 두 줄.
- 실패 시: `Connection refused`/`timed out`이면 노트북 sshd(2.1)와 노트북 ufw를 본다. `Permission denied`면 사용자 이름(`UE_A_USER`)이나 비밀번호를 확인한다.

### 2.5 SSH 구동 확인

<!-- rh: id=2.5 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
for h in "$UE_A_USER@$UE_A" "$UE_B_USER@$UE_B"; do ssh "${SSHO[@]}" -n "$h" 'hostname; iperf3 --version | head -1'; vt_ck $? "2.5 ssh $h without password"; done
ssh "${SSHO[@]}" -n "$UE_A_USER@$UE_A" "ip route get $SVC from $UE_A" | tee ~/vt-l4/2.5-route-a.txt
ssh "${SSHO[@]}" -n "$UE_B_USER@$UE_B" "ip route get $SVC from $UE_B" | tee ~/vt-l4/2.5-route-b.txt
```
- 기대: `OK` 두 줄(비밀번호를 묻지 않음), 노트북마다 `… dev <노트북 IF> src <UE IP>`.
- 실패 시: 비밀번호를 묻거나 `Permission denied (publickey…)`이면 2.4를 다시 붙인다.

## 3. 빌드 → load → setup.sh

### 3.1 빌드

<!-- rh: id=3.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
make check && make build 2>&1 | tail -3
ls -l vantage_rx_policer.o vantage_tx_pacer.o target/release/vantage-5G; vt_ck $? "3.1 build artifacts"
```
- 기대: `OK: all required tools and BTF are available.`, `Finished release …`, `OK   3.1 build artifacts`.
- 실패 시: `bpftool not usable`이면 1.2. `cargo not found`면 1.3(이 블록은 변수 파일이 `~/.cargo/env`를 읽는다). verifier/BTF 오류면 `make clean && make build`로 재시도하고 출력 전체를 보고한다.

### 3.2 load (V20)

<!-- rh: id=3.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./target/release/vantage-5G load 2>&1 | tee ~/vt-l4/3.2-load1.txt; vt_ck ${PIPESTATUS[0]} "3.2 load"
sudo ./target/release/vantage-5G load 2>&1 | tee ~/vt-l4/3.2-load2.txt; vt_ck ${PIPESTATUS[0]} "3.2 load again (idempotent)"
grep -q 'already pinned' ~/vt-l4/3.2-load2.txt; vt_ck $? "3.2 second load skipped"
for m in rx_state_map tx_tstamp_map ue_stats_map ue_policy_map; do sudo bpftool map show pinned /sys/fs/bpf/vantage/$m; done 2>&1 | tee ~/vt-l4/3.2-maps.txt
[ "$(grep -c lru_hash ~/vt-l4/3.2-maps.txt)" = 3 ] && [ "$(grep -c 'max_entries 16384' ~/vt-l4/3.2-maps.txt)" = 3 ]; vt_ck $? "3.2 three LRU maps x16384 (V20)"
```
- 기대: `OK` 네 줄. 첫 load 출력 첫 줄이 `[i] BPF objects from /home/<user>/vantage-5G`. `memlock` 합계는 24.04에서 약 4.5 MiB, 22.04에서 약 1.5 MiB로 표시된다(README §3.1) — `3.2-maps.txt`에 기록된다.
- 실패 시: `pinned maps … do not match the object`이면 이전 버전이 이 서버에 있었다 — [`install-runbook.md`](install-runbook.md) 2장(업그레이드)을 따른다. `BPF object files not found`면 3.1.

### 3.3 setup.sh (generic, 재실행, 비root) — X7, X21

<!-- rh: id=3.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sysctl net.core.default_qdisc | tee ~/vt-l4/3.3-dq-before.txt
sudo ./setup.sh "$IF" 2>&1 | tee ~/vt-l4/3.3-setup1.txt; vt_ck ${PIPESTATUS[0]} "3.3 setup.sh"
tc qdisc show dev "$IF" | tee ~/vt-l4/3.3-qdisc1.txt
sudo ./setup.sh "$IF" > ~/vt-l4/3.3-setup2.txt 2>&1; vt_ck $? "3.3 setup.sh re-run"
tc qdisc show dev "$IF" > ~/vt-l4/3.3-qdisc2.txt; diff ~/vt-l4/3.3-qdisc1.txt ~/vt-l4/3.3-qdisc2.txt; vt_ck $? "3.3 re-run kept the qdiscs (same handles)"
./setup.sh "$IF" > ~/vt-l4/3.3-setup-nonroot.txt 2>&1; vt_ck $? "3.3 setup.sh as sudo user (non-root)"
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*' | tee ~/vt-l4/3.3-xdp.txt; tc filter show dev "$IF" egress | head -2
sysctl net.core.default_qdisc | diff - ~/vt-l4/3.3-dq-before.txt; vt_ck $? "3.3 net.core.default_qdisc unchanged"
```
- 기대: `OK` 다섯 줄. 출력 끝 `TX qdisc  root fq`(TX 큐 1개) 또는 `root mq 1: + fq on all M mq classes (N TX queues in use)`(큐 N≥2, 1.5에서 기록). `prog/xdpgeneric id <n>`과 egress 필터 `… direct-action …` 한 개.
- 실패 시: rc=2면 `bpftool version`(1.2). rc=3이면 출력의 `[-]` 줄(남의 XDP/필터, `ingress` qdisc, `has a qdisc using handle 1:`이면 쓰는 곳이 없을 때 `sudo tc qdisc del dev "$IF" root` 후 재실행, `kernel module(s) not available`). rc=5면 `sudo ./detach.sh "$IF"` 후 원인을 고쳐 재실행. rc=4면 `[-] verify:` 줄을 보고한다. 큐 N≥2에서 첫 실행 순간(커널 기본 `mq 0:` → `mq 1:`) 큐에 있던 패킷은 버려진다 — 트래픽이 흐르던 중이면 `sudo dmesg | tail`과 함께 기록한다(X7).

### 3.4 native XDP 시도 (선택) — X8
`1.5-nic.txt`의 드라이버가 native XDP를 지원하면(예: ixgbe, i40e, ice, mlx5, virtio_net) 결과를 기록한다. 일부 드라이버는 attach/detach 때 **링크가 잠깐 끊긴다** — 서비스 노드에 접속한 SSH가 `IF`를 거치지 않는지 먼저 확인한다. 블록은 마지막에 generic으로 되돌린다.

<!-- rh: id=3.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./setup.sh "$IF" --xdp-mode native 2>&1 | tee ~/vt-l4/3.4-native.txt; echo "native_rc=${PIPESTATUS[0]}" | tee -a ~/vt-l4/3.4-native.txt
ip -d link show dev "$IF" | head -3 | tee -a ~/vt-l4/3.4-native.txt; sudo dmesg | tail -5 > ~/vt-l4/3.4-dmesg.txt
sudo ./setup.sh "$IF" > ~/vt-l4/3.4-generic.txt 2>&1; vt_ck $? "3.4 back to generic"
ip -d link show dev "$IF" | grep -qw xdpgeneric; vt_ck $? "3.4 xdpgeneric again"
```
- 기대(지원): `native_rc=0`, 출력에 `RX policer (XDP native, id <n>)`, `ip link` 첫 줄에 `xdp`. 기대(미지원): `native_rc=3`, `XDP attach in native mode failed: …`와 `restoring the previous attach (xdpgeneric, …)`. 둘 다 정상이며 마지막 `OK` 두 줄.
- 실패 시: `native_rc=4`와 `restore failed`이면 바로 `sudo ./setup.sh "$IF"`를 실행하고 보고한다. 링크 끊김 시간(`3.4-dmesg.txt`의 `Link is Down/Up`)을 기록한다. 서비스(8장)를 native로 돌리려면 `native_rc=0`일 때만 `vars.sh`의 `XDP_MODE=native`로 바꾼다.

## 4. 정책

### 4.1 set, list, 같은 값 재적용 (D26)

<!-- rh: id=4.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./target/release/vantage-5G set --ue-ip "$UE_A" --rx-mbps "$A_RX" --tx-mbps "$A_TX"
sudo ./target/release/vantage-5G set --ue-ip "$UE_B" --rx-mbps "$B_RX" --tx-mbps "$B_TX"
sudo ./target/release/vantage-5G list | tee ~/vt-l4/4.1-list.txt
[ "$(grep -cE "^($UE_A|$UE_B) " ~/vt-l4/4.1-list.txt)" = 2 ]; vt_ck $? "4.1 two policies listed"
sudo ./target/release/vantage-5G set --ue-ip "$UE_A" --rx-mbps "$A_RX" --tx-mbps "$A_TX" | tee ~/vt-l4/4.1-d26.txt | grep -q 'unchanged; rx/tx state kept'; vt_ck $? "4.1 same set keeps rx/tx state (D26)"
```
- 기대: `[+] policy set: UE <UE_A> rx=10 Mbps tx=20 Mbps` 등, `list`에 두 UE, `OK` 두 줄.
- 실패 시: `open pinned ue_policy_map (run vantage-5G load first …)`이면 3.2. `invalid value … --ue-ip`이면 0.2의 IP에 `/24`가 붙었는지 본다.

## 5. 측정 (README §8, 4세션 동시)

### 5.1 iperf3 서버

<!-- rh: id=5.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
pkill -x iperf3; sleep 1
for p in 5201 5202 5203 5204; do iperf3 -s -B "$SVC" -p "$p" -D; done
sleep 1; ss -ltn | grep -E "$SVC:520[1-4] " | tee ~/vt-l4/5.1-servers.txt
[ "$(grep -c . ~/vt-l4/5.1-servers.txt)" = 4 ]; vt_ck $? "5.1 four iperf3 servers on $SVC"
```
- 기대: `LISTEN … <SVC>:5201`~`5204` 네 줄, `OK`.
- 실패 시: `Address already in use`면 다른 iperf3가 있다(`ss -ltnp | grep 520`).

### 5.2 4세션 동시 측정과 판정 (약 35초)
서비스 노드가 SSH로 노트북 A·B에서 UL·DL 클라이언트 4개를 동시에 시작하고, 시작 후 약 5초(t1)와 25초(t2)에 `stats` 스냅샷을 남긴다(X3 B안 counter 판정용). 결과는 `~/vt-l4/m4-<시각>/`에 쌓이므로 다시 붙여도 이전 결과를 덮지 않는다.

<!-- rh: id=5.2 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/m4-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
ssh "${SSHO[@]}" -n "$UE_A_USER@$UE_A" "iperf3 -c $SVC -B $UE_A -p 5201 -t 30 -J"    > "$D/a_ul.json" &
ssh "${SSHO[@]}" -n "$UE_A_USER@$UE_A" "iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -J" > "$D/a_dl.json" &
ssh "${SSHO[@]}" -n "$UE_B_USER@$UE_B" "iperf3 -c $SVC -B $UE_B -p 5202 -t 30 -J"    > "$D/b_ul.json" &
ssh "${SSHO[@]}" -n "$UE_B_USER@$UE_B" "iperf3 -c $SVC -B $UE_B -p 5204 -t 30 -R -J" > "$D/b_dl.json" &
sleep 5;  vt_snap "$D/stats_t1.txt"
sleep 20; vt_snap "$D/stats_t2.txt"
wait
cat > "$D/spec.csv" <<EOF
label,ue_ip,direction,cap_mbps,json_path
A-UL,$UE_A,UL,$A_RX,a_ul.json
B-UL,$UE_B,UL,$B_RX,b_ul.json
A-DL,$UE_A,DL,$A_TX,a_dl.json
B-DL,$UE_B,DL,$B_TX,b_dl.json
EOF
python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py "$D/spec.csv" "$D/stats_t1.txt" "$D/stats_t2.txt" | tee "$D/counter_verdict.txt"; vt_ck ${PIPESTATUS[0]} "5.2 counter verdict (4 sessions within 10%)"
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py "$D/spec.csv" | tee "$D/iperf_verdict.txt"; vt_ck ${PIPESTATUS[0]} "5.2 iperf goodput verdict"
```
- 기대: counter 판정 4행 모두 `PASS`(±10%, 로컬 22.04 VM 기준 ±1% 안팎)와 `OK   5.2 counter verdict`. iperf goodput 판정도 대개 PASS지만 UL은 헤더·ACK 몫만큼 -1~-7% 낮게 읽히는 것이 정상이다(README §8.5). **처리량 판정의 기준은 counter 판정이다.**
- Ubuntu 24.04 서버라면 B-UL(3 Mbps) 행을 따로 기록한다(X27: 로컬 24.04 VM에서 이 행만 -9~-12% 미달한 적이 있음, 미분류).
- 실패 시:
  - cap **초과**(counter `over cap`)는 즉시 보고한다. 함께: `tc qdisc show dev "$IF"`(root가 fq/mq+fq인지), `stats`에 UE 행이 있는지, 2.3의 `ip route get`.
  - `FAIL (no counters for UE)` 또는 iperf `cannot read`/`iperf3 error`이면 그 세션이 돌지 않았다. `$D/*.json`이 비었으면 SSH(2.5)나 5.1 서버를 확인한다.
  - 미달이면 5.4(커널 셰이퍼 대조)를 하고 `mpstat -P ALL 1 5`(sysstat)를 기록한다.

### 5.3 측정 직후 상태

<!-- rh: id=5.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
{ sudo ./target/release/vantage-5G stats; tc -s qdisc show dev "$IF"; ethtool -S "$IF" 2>&1 | grep -iE 'drop|miss' | head; } 2>&1 | tee ~/vt-l4/5.3-after.txt
```
- 기대: 두 UE 행. 정상 TCP에서는 `TX_DROPS`가 0 근처, fq `dropped`가 작다.

### 5.4 커널 셰이퍼 대조 (선택, 5.2에서 DL이 cap보다 10% 넘게 낮을 때)
같은 NIC에서 커널 `fq maxrate`로 같은 속도를 걸고 UE-A의 DL 한 세션을 잰다. 대조 중 UE-A는 Vantage 정책이 없다. 블록 끝에서 복구한다(`replace root fq`로는 maxrate가 남으므로 반드시 del 후 `setup.sh`).

<!-- rh: id=5.4 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/kfq-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
sudo ./target/release/vantage-5G reset --ue-ip "$UE_A"
sudo tc qdisc del dev "$IF" root; sudo tc qdisc add dev "$IF" root fq maxrate "${A_TX}mbit"; tc qdisc show dev "$IF" | tee "$D/qdisc-control.txt"
ssh "${SSHO[@]}" -n "$UE_A_USER@$UE_A" "iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -J" > "$D/a_dl_kfq.json"
sudo tc qdisc del dev "$IF" root; sudo ./setup.sh "$IF" > "$D/setup-restore.txt" 2>&1; vt_ck $? "5.4 restore: setup.sh"
sudo ./target/release/vantage-5G set --ue-ip "$UE_A" --rx-mbps "$A_RX" --tx-mbps "$A_TX"
tc qdisc show dev "$IF" | tee "$D/qdisc-restored.txt" | grep -q maxrate; [ $? = 1 ]; vt_ck $? "5.4 restore: no maxrate left"
cat > "$D/spec.csv" <<EOF
label,ue_ip,direction,cap_mbps,json_path
A-DL-kernel-fq,$UE_A,DL,$A_TX,a_dl_kfq.json
EOF
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py "$D/spec.csv" | tee "$D/iperf_verdict.txt"
```
- 기대: 복구 `OK` 두 줄. 판정 행은 참고값이다: 커널 fq도 5.2의 A-DL과 같은 폭으로 미달하면 경로·환경 문제(서버 CPU, NIC 오프로드, 노트북)로, 커널 fq는 cap에 맞는데 Vantage만 미달하면 datapath 문제로 보고한다.
- 실패 시: `maxrate`가 남아 있으면 `sudo tc qdisc del dev "$IF" root; sudo ./setup.sh "$IF"`를 다시 실행한다. 이어서 4.1의 A `set`이 들어갔는지 `sudo ./target/release/vantage-5G list`로 본다.

### 5.5 멀티 플로우: UL `-P 8` (X14), DL `-P 4` (X20) (약 70초)
UE-A 하나에 플로우 여러 개를 걸어도 UE 합계가 cap인지 본다. RSS 멀티큐 NIC에서는 UL 플로우가 여러 RX 큐(여러 CPU)로, DL 플로우가 여러 TX 큐의 fq로 나뉜다.

<!-- rh: id=5.5 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/mq-ul-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
ssh "${SSHO[@]}" -n "$UE_A_USER@$UE_A" "iperf3 -c $SVC -B $UE_A -p 5201 -t 30 -P 8 -J" > "$D/a_ul_p8.json" &
sleep 5;  vt_snap "$D/stats_t1.txt"
sleep 20; vt_snap "$D/stats_t2.txt"
wait
cat > "$D/spec.csv" <<EOF
label,ue_ip,direction,cap_mbps,json_path
A-UL-P8,$UE_A,UL,$A_RX,a_ul_p8.json
EOF
python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py "$D/spec.csv" "$D/stats_t1.txt" "$D/stats_t2.txt" | tee "$D/counter_verdict.txt"; vt_ck ${PIPESTATUS[0]} "5.5 UL -P 8 counter verdict (X14)"
D=~/vt-l4/mq-dl-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
tc -s qdisc show dev "$IF" > "$D/qdisc-before.txt"
ssh "${SSHO[@]}" -n "$UE_A_USER@$UE_A" "iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -P 4 -J" > "$D/a_dl_p4.json" &
sleep 5;  vt_snap "$D/stats_t1.txt"
sleep 20; vt_snap "$D/stats_t2.txt"
wait
tc -s qdisc show dev "$IF" > "$D/qdisc-after.txt"
cat > "$D/spec.csv" <<EOF
label,ue_ip,direction,cap_mbps,json_path
A-DL-P4,$UE_A,DL,$A_TX,a_dl_p4.json
EOF
python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py "$D/spec.csv" "$D/stats_t1.txt" "$D/stats_t2.txt" | tee "$D/counter_verdict.txt"; vt_ck ${PIPESTATUS[0]} "5.5 DL -P 4 counter verdict (X20)"
```
- 기대: `OK` 두 줄(counter 판정 ±10%). TX 큐가 2개 이상이면 `qdisc-before/after.txt`의 큐별 `fq` `Sent` 증가가 2개 이상의 큐에 나뉜다(모두 한 큐면 플로우 해시 결과로 기록만).
- 실패 시: UL cap **초과**면 초과 폭과 `ethtool -l "$IF"`(RX 큐 수)를 기록해 보고한다(D5a 잔여 경합, X14). DL cap 초과면 즉시 보고한다(`tc qdisc show dev "$IF"`로 모든 큐가 fq인지).

## 6. killswitch (노트북에서 직접)
UE-B의 DL을 막는 동안 서비스 노드에서 노트북 B로 SSH가 되지 않으므로 6.2와 6.3은 각 노트북에서 붙인다.

### 6.1 UE-B DL 차단

<!-- rh: id=6.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
vt_snap ~/vt-l4/6-stats-before.txt
sudo ./target/release/vantage-5G set --ue-ip "$UE_B" --rx-mbps "$B_RX" --tx-mbps 0 | tee ~/vt-l4/6.1-set.txt | grep -q 'killswitch: DL blocked'; vt_ck $? "6.1 killswitch set on $UE_B"
```
- 기대: `OK   6.1 killswitch set on <UE_B>`.

### 6.2 노트북 B: 서비스 노드 ping 실패

<!-- rh: id=6.2 host=b -->
**[노트북 B]**
```bash
source ~/vt-l4/vars.sh
ping -c 3 -W 1 -I "$ME" "$SVC" > ~/vt-l4/6.2-ping-b.txt 2>&1; rc=$?; tail -2 ~/vt-l4/6.2-ping-b.txt; [ $rc != 0 ]; vt_ck $? "6.2 $ROLE: ping $SVC fails under killswitch"
```
- 기대: `3 packets transmitted, 0 received, 100% packet loss`, `OK`.
- 실패 시: 응답이 오면 6.1의 `set` 출력과 2.3의 `ip route get "$UE_B"`(DL이 `IF`로 나가는지)를 확인해 보고한다.

### 6.3 노트북 A: 정상

<!-- rh: id=6.3 host=a -->
**[노트북 A]**
```bash
source ~/vt-l4/vars.sh
ping -c 3 -W 1 -I "$ME" "$SVC" > ~/vt-l4/6.3-ping-a.txt 2>&1; vt_ck $? "6.3 $ROLE: ping $SVC works"; tail -2 ~/vt-l4/6.3-ping-a.txt
```
- 기대: `0% packet loss`, `OK`.

### 6.4 드롭 카운터 확인과 복구

<!-- rh: id=6.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
vt_snap ~/vt-l4/6-stats-after.txt; cat ~/vt-l4/6-stats-after.txt
d0=$(awk -v ip="$UE_B" '$1 == ip {print $7}' ~/vt-l4/6-stats-before.txt); d1=$(awk -v ip="$UE_B" '$1 == ip {print $7}' ~/vt-l4/6-stats-after.txt)
echo "UE_B TX_DROPS ${d0:-0} -> ${d1:-0}"; [ "${d1:-0}" -gt "${d0:-0}" ]; vt_ck $? "6.4 UE_B TX_DROPS increased"
sudo ./target/release/vantage-5G set --ue-ip "$UE_B" --rx-mbps "$B_RX" --tx-mbps "$B_TX"
ssh "${SSHO[@]}" -n "$UE_B_USER@$UE_B" true; vt_ck $? "6.4 laptop B reachable again"
```
- 기대: `TX_DROPS`가 늘었고 복구 후 노트북 B로 SSH가 된다. `OK` 두 줄.

## 7. 수동 경로 정리: unload 가드 → detach → unload (X2, X18)
8장(systemd 서비스)을 깨끗한 상태에서 시작하기 위해 수동으로 붙인 것을 먼저 걷는다.

<!-- rh: id=7 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./target/release/vantage-5G unload > ~/vt-l4/7-unload-guard.txt 2>&1; rc=$?; cat ~/vt-l4/7-unload-guard.txt; [ $rc = 1 ]; vt_ck $? "7 unload refused while attached"
sudo test -d /sys/fs/bpf/vantage; vt_ck $? "7 pins kept after refused unload"
sudo ./detach.sh "$IF" 2>&1 | tee ~/vt-l4/7-detach.txt; vt_ck ${PIPESTATUS[0]} "7 detach.sh"
{ ip -d link show dev "$IF"; tc qdisc show dev "$IF"; tc filter show dev "$IF" egress; } 2>&1 | tee ~/vt-l4/7-after-detach.txt
ip -d link show dev "$IF" | grep -q 'prog/xdp'; [ $? = 1 ]; vt_ck $? "7 no XDP left on $IF (X2)"
[ -z "$(tc qdisc show dev "$IF" | grep -E 'clsact|root' | grep -v ' 0: root')" ]; vt_ck $? "7 kernel default root qdisc, no clsact (X18)"
sudo ./target/release/vantage-5G unload; vt_ck $? "7 unload"
sudo test -e /sys/fs/bpf/vantage; [ $? = 1 ]; vt_ck $? "7 /sys/fs/bpf/vantage removed"
```
- 기대: 첫 unload가 `Vantage programs are still attached:`와 `run: sudo …/detach.sh <IF>`로 거부(rc=1)되고 핀은 유지된다. detach 후 `prog/xdp` 없음, root는 커널 기본(`mq 0:`+기본 qdisc 자식, 큐 1개면 기본 qdisc 하나, handle `0:`), clsact 없음. `OK` 일곱 줄.
- 실패 시: detach rc=4면 남은 목록을 보고한다(native 드라이버에서 xdp 잔존은 X2). root가 `0:`이 아니면 `7-after-detach.txt`를 보고한다(X18).

## 8. systemd 서비스 (부팅 시 자동 load → apply → setup.sh)
서비스는 `policies.conf`가 기준이다(시작·reload·재부팅마다 `apply --replace`). 정책은 변수 파일 값으로 파일에 쓴다. 재부팅(8.5) 전에 서비스 노드 접속이 `IF`를 거치지 않는지 확인한다.

### 8.1 설치

<!-- rh: id=8.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./install.sh install --enable 2>&1 | tee ~/vt-l4/8.1-install.txt; vt_ck ${PIPESTATUS[0]} "8.1 install --enable"
[ "$(systemctl is-enabled vantage-5g vantage-5g-monitor | grep -c '^enabled$')" = 2 ]; vt_ck $? "8.1 both units enabled"
sudo ./install.sh install > ~/vt-l4/8.1-install2.txt 2>&1; vt_ck $? "8.1 install re-run"
grep -E 'exists \(kept\)|installed\.' ~/vt-l4/8.1-install2.txt; [ "$(grep -c 'exists (kept)' ~/vt-l4/8.1-install2.txt)" = 2 ]; vt_ck $? "8.1 re-run keeps vantage-5g.env and policies.conf"
```
- 기대: `OK` 네 줄. 첫 설치 출력에 `vantage-5G 0.2.0`, `vantage-5g.env created from the example`, `policies.conf created from the example`, `[+] Vantage-5G installed.`, `[!] set IFACE= in /etc/vantage-5g/vantage-5g.env`(8.2에서 설정). 재실행 출력에 `vantage-5g.env exists (kept)`, `policies.conf exists (kept)`.
- 실패 시: rc=2와 `missing in …`이면 3.1. `[!] /usr/local/bin/vantage-5G is a regular file`이면 기록한다(이후 `sudo vantage-5G` 대신 `sudo /usr/local/lib/vantage-5g/vantage-5G`).

### 8.2 설정과 정책 파일 (변수에서 생성)

<!-- rh: id=8.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo sed -i -e "s/^IFACE=.*/IFACE=$IF/" -e "s/^XDP_MODE=.*/XDP_MODE=$XDP_MODE/" /etc/vantage-5g/vantage-5g.env
sudo tee /etc/vantage-5g/policies.conf > /dev/null <<EOF
# Vantage-5G policies (LAN runbook 8.2): <UE_IPv4> <rx_mbps> <tx_mbps>
$UE_A $A_RX $A_TX
$UE_B $B_RX $B_TX
EOF
grep -vE '^\s*(#|$)' /etc/vantage-5g/vantage-5g.env /etc/vantage-5g/policies.conf | tee ~/vt-l4/8.2-config.txt
grep -qx "IFACE=$IF" /etc/vantage-5g/vantage-5g.env && grep -qx "XDP_MODE=$XDP_MODE" /etc/vantage-5g/vantage-5g.env; vt_ck $? "8.2 env IFACE=$IF XDP_MODE=$XDP_MODE"
grep -qx 'MONITOR_ARGS=--bind 127.0.0.1' /etc/vantage-5g/vantage-5g.env; vt_ck $? "8.2 exporter bound to 127.0.0.1 only (X25)"
```
- 기대: `OK` 두 줄. env에 `IFACE=<IF>`, `XDP_MODE=generic`(또는 3.4에서 고른 native), `IFACE_WAIT_SEC=90`, `MONITOR_ARGS=--bind 127.0.0.1`. policies.conf에 두 줄.
- `/metrics`에는 모든 UE의 IP·정책·카운터가 나오므로 `--bind 127.0.0.1`을 유지한다. 원격 Prometheus가 필요하면 [`install-runbook.md`](install-runbook.md) 3.7.2(관리망 bind + 방화벽).

### 8.3 시작

<!-- rh: id=8.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo systemctl start vantage-5g vantage-5g-monitor; vt_ck $? "8.3 start"
systemctl status vantage-5g --no-pager > ~/vt-l4/8.3-status.txt 2>&1; grep -E 'Active:' ~/vt-l4/8.3-status.txt
sudo journalctl -u vantage-5g -b --no-pager | tail -30 > ~/vt-l4/8.3-journal.txt; grep -E 'BPF objects|applied|attached to' ~/vt-l4/8.3-journal.txt
sudo vantage-5G list | tee ~/vt-l4/8.3-list.txt; [ "$(grep -cE "^($UE_A|$UE_B) " ~/vt-l4/8.3-list.txt)" = 2 ]; vt_ck $? "8.3 policies from policies.conf"
ip -d link show dev "$IF" | grep -q 'prog/xdp'; vt_ck $? "8.3 XDP attached to $IF"
tc qdisc show dev "$IF"; tc filter show dev "$IF" egress | grep -q direct-action; vt_ck $? "8.3 egress filter on $IF"
sleep 2; [ "$(curl -s http://127.0.0.1:9090/metrics | grep -c '^vantage_')" -gt 0 ]; vt_ck $? "8.3 exporter metrics on 127.0.0.1:9090"
```
- 기대: `Active: active (exited)`, journal에 `[i] BPF objects from /usr/local/lib/vantage-5g` → `[+] applied /etc/vantage-5g/policies.conf (--replace): added 2, …` → `[+] Vantage-5G attached to <IF>.`, `OK` 다섯 줄.
- 실패 시: 서비스는 실패해도 자동 정리하지 않는다. `8.3-status.txt`의 `ExecStartPre=…`/`ExecStart=… (code=exited, status=N)` 줄로 단계를 판정한다 — preflight status=1(env 오류)/6(`IF`가 90 s 안에 안 나타남), `load` status=1(3.2 실패 시), `apply` status=1(`line N: …`, 아무것도 attach 안 됨), `setup.sh` status=2/3/4/5(3.3 실패 시, 5면 먼저 `sudo /usr/local/lib/vantage-5g/detach.sh "$IF"`). 원인을 고친 뒤 이 블록을 다시 붙인다.

### 8.4 reload (정책 파일 변경)
UE-B의 tx를 1 올려 reload하고(재attach 없음 확인), 원래 값으로 되돌려 한 번 더 reload한다.

<!-- rh: id=8.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*' > ~/vt-l4/8.4-xdp-before.txt
sudo tee /etc/vantage-5g/policies.conf > /dev/null <<EOF
# Vantage-5G policies (LAN runbook 8.4: UE_B tx + 1)
$UE_A $A_RX $A_TX
$UE_B $B_RX $((B_TX + 1))
EOF
sudo systemctl reload vantage-5g; vt_ck $? "8.4 reload"
sudo journalctl -u vantage-5g --no-pager -n 6 | tee ~/vt-l4/8.4-reload.txt | grep 'applied'
grep -q 'added 0, changed 1, unchanged 1, removed 0' ~/vt-l4/8.4-reload.txt; vt_ck $? "8.4 one policy changed"
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*' | diff - ~/vt-l4/8.4-xdp-before.txt; vt_ck $? "8.4 same XDP program (no re-attach)"
sudo tee /etc/vantage-5g/policies.conf > /dev/null <<EOF
# Vantage-5G policies (LAN runbook 8.2): <UE_IPv4> <rx_mbps> <tx_mbps>
$UE_A $A_RX $A_TX
$UE_B $B_RX $B_TX
EOF
sudo systemctl reload vantage-5g; vt_ck $? "8.4 reload back to the 8.2 values"
```
- 기대: `[+] applied /etc/vantage-5g/policies.conf (--replace): added 0, changed 1, unchanged 1, removed 0`, `OK` 네 줄.
- 실패 시: reload rc≠0이면 journal에 줄 번호 오류 목록이 있고 정책은 그대로다. 파일을 고치고 다시 reload한다.

### 8.5 재부팅
`IF`를 거치지 않는 경로로 접속해 있는지 확인한 뒤 실행한다. 접속이 끊긴다.

<!-- rh: id=8.5 host=svc mode=reboot -->
**[서비스 노드]**
```bash
sudo systemctl reboot
```

### 8.6 재접속 후 확인 (X22)
서비스 노드에 다시 접속해 붙인다(새 셸이어도 된다).

<!-- rh: id=8.6 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
systemctl is-system-running --wait
systemctl is-active vantage-5g vantage-5g-monitor | tee ~/vt-l4/8.6-active.txt; [ "$(grep -c '^active$' ~/vt-l4/8.6-active.txt)" = 2 ]; vt_ck $? "8.6 both units active after reboot"
sudo journalctl -b -u vantage-5g --no-pager > ~/vt-l4/8.6-boot-journal.txt; grep -E 'waiting|appeared|BPF objects|applied|attached to' ~/vt-l4/8.6-boot-journal.txt
systemd-analyze critical-chain vantage-5g.service --no-pager 2>&1 | head -12 > ~/vt-l4/8.6-chain.txt
sudo vantage-5G export > ~/vt-l4/8.6-export.txt
diff <(grep -vE '^\s*(#|$)' /etc/vantage-5g/policies.conf | awk '{print $1, $2, $3}' | sort) <(grep -v '^#' ~/vt-l4/8.6-export.txt | awk '{print $1, $2, $3}' | sort); vt_ck $? "8.6 policies restored = policies.conf"
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*'; vt_ck ${PIPESTATUS[1]} "8.6 XDP attached to $IF after boot"
tc filter show dev "$IF" egress | grep -q direct-action; vt_ck $? "8.6 egress filter after boot"
ss -ltn | grep ':9090 '
for u in "$UE_A" "$UE_B"; do ping -c 2 -W 2 "$u" > /dev/null; vt_ck $? "8.6 ping $u after reboot"; done
```
- 기대: `running`(또는 `degraded` — 다른 유닛 문제, 기록), `OK` 여섯 줄. journal 순서는 8.3과 같다(NIC가 늦게 뜨면 `waiting up to 90s for interface …`와 `appeared after ~Ns`가 앞에 나온다). 9090은 `127.0.0.1:9090`만.
- 실패 시: preflight status=6(`did not appear within …s`)이면 NIC가 늦게 올라온 것이다 — `sudo journalctl -b | grep -iE "$IF|link"`로 NIC가 나타난 시각을 기록하고 `/etc/vantage-5g/vantage-5g.env`의 `IFACE_WAIT_SEC`를 늘린다(최대 240). 서비스가 `inactive`이고 `systemctl is-enabled vantage-5g`가 `disabled`이면 `sudo systemctl enable vantage-5g vantage-5g-monitor`. 정책이 다르면 `8.6-export.txt`와 policies.conf를 함께 보고한다.

### 8.7 stop / start / restart

<!-- rh: id=8.7 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo systemctl stop vantage-5g; vt_ck $? "8.7 stop"
[ "$(systemctl is-failed vantage-5g)" = inactive ]; vt_ck $? "8.7 stopped cleanly (inactive, not failed)"
[ "$(systemctl is-active vantage-5g-monitor)" = active ]; vt_ck $? "8.7 monitor keeps running"
sudo test -e /sys/fs/bpf/vantage; [ $? = 1 ]; vt_ck $? "8.7 pins removed by stop"
ip -d link show dev "$IF" | grep -q 'prog/xdp'; [ $? = 1 ]; vt_ck $? "8.7 detached by stop"
sudo systemctl start vantage-5g; vt_ck $? "8.7 start"
P1=$(systemctl show -p MainPID --value vantage-5g-monitor)
sudo systemctl restart vantage-5g; vt_ck $? "8.7 restart"
[ "$(systemctl show -p MainPID --value vantage-5g-monitor)" = "$P1" ]; vt_ck $? "8.7 monitor PID unchanged by restart"
sleep 2; [ "$(curl -s http://127.0.0.1:9090/metrics | grep -c '^vantage_ue_policy_')" -gt 0 ]; vt_ck $? "8.7 UE metrics back after restart"
```
- 기대: `OK` 아홉 줄. restart = detach → unload → load → apply → setup(짧은 셰이핑 공백).
- 실패 시: **stop은 정리에 실패해도 rc=0이다.** `is-failed`가 `failed`이면 `sudo journalctl -u vantage-5g -n 20`의 `Vantage programs are still attached:` 목록에 `sudo /usr/local/lib/vantage-5g/detach.sh <iface>` → `sudo vantage-5G unload` → `sudo systemctl reset-failed vantage-5g`.

## 9. exporter 노출 (X25)과 Grafana (선택, X24)

### 9.1 서비스 노드: 127.0.0.1에만 열림

<!-- rh: id=9.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
ss -ltn | grep ':9090 ' | tee ~/vt-l4/9.1-ss.txt
[ "$(grep -c ':9090 ' ~/vt-l4/9.1-ss.txt)" = 1 ] && grep -q '127.0.0.1:9090 ' ~/vt-l4/9.1-ss.txt; vt_ck $? "9.1 exporter listens on 127.0.0.1:9090 only"
curl -s http://127.0.0.1:9090/metrics | grep -E '^vantage_ue_policy_(rx|tx)_bps' | tee ~/vt-l4/9.1-metrics.txt
```

### 9.2 노트북 A: 9090이 보이지 않음

<!-- rh: id=9.2 host=a -->
**[노트북 A]**
```bash
source ~/vt-l4/vars.sh
code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://$SVC:9090/metrics"); echo "http_code=$code"; [ "$code" = 000 ]; vt_ck $? "9.2 $ROLE: $SVC:9090 not reachable from the LAN"
```
- 기대: 9.1 `OK`, 정책 메트릭 4줄(UE 2개 × rx/tx). 9.2 `http_code=000`, `OK`.
- 실패 시: 9.2에서 `200`이면 `MONITOR_ARGS`에 `--bind`가 없거나 LAN 주소로 bind된 것이다 — 8.2를 다시 붙이고 `sudo systemctl restart vantage-5g-monitor`(`restart vantage-5g`로는 bind가 바뀌지 않는다).

### 9.3 Grafana 대시보드 (선택)
Prometheus·Grafana를 서비스 노드 자체(`127.0.0.1:9090` scrape)나 관리망 호스트에서 돌릴 때만 한다. 절차와 판독 기준은 [`install-runbook.md`](install-runbook.md) 3.7.3·4.6과 [`dashboards/README.md`](../dashboards/README.md)를 따른다(`job_name: vantage-5g`, 측정 중 `scrape_interval: 1s`). 이 문서의 5.2를 대시보드를 보면서 다시 붙이면 4.6의 판독(UE별 선이 cap 근처, realized/cap 90~110%)을 할 수 있다. 화면과 Grafana·Prometheus 버전을 `~/vt-l4/9.3-*.png`로 남긴다. 로컬 리허설은 이 절을 실행하지 않았다(X24는 L4 전용).

## 10. 제거 (서버에서 뺄 때만)
계속 운영할 것이면 10장은 건너뛰고 11장으로 간다.

<!-- rh: id=10 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./install.sh uninstall 2>&1 | tee ~/vt-l4/10-uninstall.txt; vt_ck ${PIPESTATUS[0]} "10 uninstall"
[ -z "$(systemctl list-unit-files 'vantage-5g*' --no-legend)" ]; vt_ck $? "10 unit files removed"
test -e /usr/local/lib/vantage-5g || test -e /usr/local/bin/vantage-5G; [ $? = 1 ]; vt_ck $? "10 /usr/local files removed"
test -d /etc/vantage-5g; vt_ck $? "10 /etc/vantage-5g kept by plain uninstall"
sudo ./install.sh uninstall --purge > ~/vt-l4/10-purge.txt 2>&1; vt_ck $? "10 uninstall --purge"
test -e /etc/vantage-5g; [ $? = 1 ]; vt_ck $? "10 /etc/vantage-5g removed by --purge"
sudo test -e /sys/fs/bpf/vantage; [ $? = 1 ]; vt_ck $? "10 no pins left"
ip -d link show dev "$IF" | grep -q 'prog/xdp'; [ $? = 1 ]; vt_ck $? "10 no XDP left on $IF"
[ -z "$(tc qdisc show dev "$IF" | grep -E 'clsact|root' | grep -v ' 0: root')" ]; vt_ck $? "10 kernel default root qdisc, no clsact"
pkill -x iperf3; tc qdisc show dev "$IF" | tee ~/vt-l4/10-qdisc.txt
```
- 기대: `[+] Vantage-5G uninstalled.`, `OK` 아홉 줄. `/run/vantage-5g.lock`(CLI의 쓰기 잠금 파일, tmpfs)은 남아도 정상이다(재부팅 때 사라진다).
- 실패 시: rc=4와 `did not stop cleanly`이면 아무것도 지워지지 않았다 — 출력된 대로 `sudo /usr/local/lib/vantage-5g/detach.sh <iface>` 후 이 블록을 다시 붙인다. rc=5면 `sudo ./detach.sh "$IF"; sudo ./target/release/vantage-5G unload`.

## 11. 결과 수집

### 11.1 서비스 노드로 모으고 묶기
노트북의 `~/vt-l4/`를 SSH로 가져와 서비스 노드의 `~/vt-l4/laptop-a`, `laptop-b`에 넣고 전체를 tar로 묶는다. 마지막에 개발 PC에서 붙일 `scp` 명령을 출력한다.

<!-- rh: id=11.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
{ git log -1 --oneline; uname -r; lsb_release -ds; date -Is; } > ~/vt-l4/11-meta.txt
rm -rf ~/vt-l4/laptop-a ~/vt-l4/laptop-b
scp "${SSHO[@]}" -q -r "$UE_A_USER@$UE_A:vt-l4" ~/vt-l4/laptop-a < /dev/null; vt_ck $? "11.1 collected laptop A"
scp "${SSHO[@]}" -q -r "$UE_B_USER@$UE_B:vt-l4" ~/vt-l4/laptop-b < /dev/null; vt_ck $? "11.1 collected laptop B"
T=~/vt-l4-$(hostname)-$(date +%Y%m%d-%H%M).tgz; tar czf "$T" -C ~ vt-l4; vt_ck $? "11.1 archive $T"
for ip in $(hostname -I); do case "$ip" in *:*) ;; *) echo "scp $(id -un)@$ip:$(basename "$T") ." ;; esac; done
```
- 기대: `OK` 세 줄. 마지막 줄들이 개발 PC에서 붙일 명령이다(서비스 노드의 주소마다 한 줄 — PC에서 닿는 주소의 줄을 쓴다).
- 가져올 것: 이 tar 하나(서비스 노드와 두 노트북의 단계별 출력, `m4-*`·`mq-*`·`kfq-*` 측정 디렉토리, 8장 journal). 3.4나 9.3을 했다면 그 출력과 스크린샷도 들어 있다.

### 11.2 SSH 키 정리 (선택)
측정을 다시 할 계획이 없으면 노트북에서 서비스 노드 키를 지우고, 서비스 노드에서 키를 지운다.

<!-- rh: id=11.2-a host=a -->
**[노트북 A]**
```bash
sed -i '/vantage-vt-l4/d' ~/.ssh/authorized_keys; grep -c vantage-vt-l4 ~/.ssh/authorized_keys
```

<!-- rh: id=11.2-b host=b -->
**[노트북 B]**
```bash
sed -i '/vantage-vt-l4/d' ~/.ssh/authorized_keys; grep -c vantage-vt-l4 ~/.ssh/authorized_keys
```

<!-- rh: id=11.2-svc host=svc -->
**[서비스 노드]**
```bash
rm -f ~/.ssh/vt_l4 ~/.ssh/vt_l4.pub; ls ~/.ssh
```
- 기대: 노트북에서 `0`. 서비스 노드 `~/.ssh`에 `vt_l4`가 없다.

## 12. 판정 다시 하기
tar를 푼 디렉토리 또는 서비스 노드에서, 저장소(`~/vantage-5G`)의 판정 스크립트로 모든 측정 디렉토리를 다시 판정한다. 개발 PC에서는 `R=~/vt-l4` 대신 tar를 푼 `vt-l4` 경로를 쓴다.

<!-- rh: id=12 host=svc -->
**[서비스 노드]**
```bash
cd ~/vantage-5G; R=~/vt-l4
for d in "$R"/m4-* "$R"/mq-* "$R"/kfq-*; do [ -f "$d/spec.csv" ] || continue; echo "=== $d"; python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py "$d/spec.csv"; if [ -f "$d/stats_t2.txt" ]; then python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py "$d/spec.csv" "$d/stats_t1.txt" "$d/stats_t2.txt"; fi; done
```
- 해석: README §8.5. counter 판정(L2 바이트, ACK 포함)이 cap 기준이고, iperf goodput은 헤더·반대 방향 ACK만큼 낮게 읽힌다. `kfq-*`는 iperf 판정만 있다(5.4 참고값).

## 13. 체크리스트 (이 구성에서 확인하는 L4 항목)

| # | 항목 | 확인 위치 |
|---|---|---|
| X1 | 새 clone의 스크립트 실행 권한 | 1.4 |
| X2 | native XDP 지원 드라이버에서 detach 후 xdp 잔존 없음 | 3.4 → 7, 10 |
| X7 | 멀티큐 NIC: 커널 기본 `mq 0:` → `mq 1:` + 큐별 fq(첫 실행), 재실행 시 qdisc 무변경, 전환 순간 손실·링크 리셋, `default_qdisc` 원복 | 3.3 |
| X8 | native XDP: 지원 시 rc=0과 `xdp` 표시, 미지원 시 rc=3·generic 복원, 링크 플랩 시간 | 3.4 |
| X12 | 22.04/24.04 설치 명령, `bpftool version` | 1.2 |
| X13 | LRU 조기 퇴출(nproc > 128 & 커널 < 6.16) — 활성 UE 카운터가 0으로 돌아가는지 | 1.1, 5.3 |
| X14 | RSS 멀티큐 UL `-P 8` 과다 허용 | 5.5 |
| X15 | BIG TCP 비활성(gro_max_size ≤ 65536), native XDP에서 rx_packets 의미 | 1.5, 5.3 |
| X18 | detach 후 커널 기본 root 복원(멀티큐 `mq 0:` + default_qdisc 자식, 단일 큐 default_qdisc) | 7, 10 |
| X19 | `ethtool -L`로 채널을 늘린 뒤 재실행 없이 새 큐가 fq인지 (선택: 3.3 뒤 `sudo ethtool -L "$IF" combined <n>` → `tc qdisc show dev "$IF"`) | 3.3 |
| X20 | 큐 여러 개 NIC의 큐별 fq EDT: DL counter 판정, `-P 4` DL UE 합계 cap | 5.2, 5.5 |
| X21 | `sch_fq`가 builtin인 커널에서 모듈 검사 통과 | 3.3 |
| X22 | systemd: 실제 NIC(드라이버 로드 시간, netplan)에서 부팅 시 `IFACE` 대기, attach·정책 복원 | 8.6 |
| X23 | systemd + native XDP(`XDP_MODE=native`)의 부팅·restart 링크 리셋 (3.4가 rc=0일 때) | 8.6, 8.7 |
| X24 | Grafana UI 렌더링(정책 표, `KILLSWITCH`/`uncapped`, ±10% 선) | 9.3 |
| X25 | exporter 노출: LAN(노트북) 쪽에서 9090 불가 | 9.1, 9.2 |
| X27 | 24.04의 B-UL(3 Mbps, 4세션) 미달 여부 | 5.2 |
| V20 | 맵 메모리(LRU 3개 memlock 합계, 커널별 표시 차이) | 3.2 |
| — | 실제 노트북 2대: 유선 NIC와 Wi-Fi 공존 시 경로·`-B` 바인딩, 물리 스위치 | 2.2, 5.2 |

## 14. 5G 단계로 넘기는 항목 (코어 설치 후 [`install-runbook.md`](install-runbook.md))

| # | 항목 | 이 구성에서 확인할 수 없는 이유 |
|---|---|---|
| X5 | 실 코어 경로에서 UE IP 노출(UPF MASQUERADE 예외), 귀환 경로 | 코어·UPF가 없다(install-runbook 1.4~1.7) |
| — | `uesimtun` 바인딩, `nr-binder`, UPF `ip_forward`·FORWARD | 같은 이유(install-runbook 1.5, 4.0, 4.2) |
| X26 | 실제 다중 노드(Vantage 노드 2대 이상, 같은 UE 풀)를 한 Prometheus로 수집 | 노드가 하나다 |
| D4 | 서비스 노드 뒤(포워딩되는 쪽)에서 UE로 UDP 과부하 후 TCP DL | 포워딩 경로가 없다(install-runbook 4.5) |
| X16 | 다른 netns(컨테이너)에 attach된 경우 unload 가드 미검출 | 해당 시에만 |
| — | 업그레이드(이전 버전 핀이 있는 서버) | 첫 설치다. 필요하면 install-runbook 2장 |

## 15. 로컬 리허설 (이 문서 자체의 검증)

`testbed/l2-lan-rehearsal.sh`가 이 문서의 코드 블록(`<!-- rh: … -->` 주석이 붙은 51개, 주석 없는 `bash` 블록이 있으면 추출 단계에서 실패)을 그대로 추출해 L2 Ubuntu VM 안의 같은 서브넷 토폴로지에서 순서대로 실행한다(testbed/README §5c).

- 토폴로지: VM의 root netns가 서비스 노드다(`IF=vtlan0`, systemd-networkd veth라 재부팅 후에도 있음). 노트북 A·B는 netns 두 개이고 각각 유선 `eth0`(Linux bridge = 스위치, 같은 /24)과 기본 경로를 가진 인터넷용 `wlan0`(Wi-Fi 역할, NAT)을 가진다. 노트북마다 별도 사용자(`lapa`, `lapb`)와 그 netns 안의 sshd가 있어 5.2의 SSH 구동이 실제 SSH 경로를 탄다.
- 붙여넣기 재현: 서비스 노드 블록은 VM `ubuntu` 사용자의 SSH 세션에서, 노트북 블록은 해당 netns의 사용자 셸에서, 모두 `bash -i`에 블록 텍스트를 표준입력으로 넣는다 — bracketed paste가 없는 터미널과 같은 조건(히스토리 확장 켜짐, 표준입력을 읽는 명령이 다음 줄을 먹음)이다. 블록마다 새 셸이다(이전 블록의 `cd`·변수에 기대지 않음).
- 대체한 것(이것뿐): 0.2의 `nano` 편집은 `sed`로 값을 채우는 것으로, 2.4의 비밀번호 입력은 `SSH_ASKPASS`로 대신했다. 노트북 사용자의 sudo는 비밀번호 없이 설정했다(실제 노트북에서는 처음에 `sudo -v`). 2.1의 `systemctl enable --now ssh`는 VM의 sshd에 작용하고, netns sshd는 래퍼가 띄운다. 8.5는 VM을 실제로 재부팅했고(boot id 변경 확인), 재부팅 뒤 래퍼가 노트북 netns를 다시 만든다(실제 노트북은 계속 켜져 있음).
- 최종 실행 `_workspace/lanrh-jammy-20261021_121224`(clone한 커밋 `3971b36`, Ubuntu 22.04.5 / 5.15.0-198, 깨끗한 상태에서 시작: clone·`~/.cargo` 없음): 51 블록 모두 PASS(`FAIL` 줄·셸 오류 0), uninstall --purge 후 잔여물 점검 clean(`/run/vantage-5g.lock`만 남음, 정상), VM 타이머 점검 시작·5.2·5.4·5.5 직전·끝 모두 OK(p99 10.9~13.9 ms).
  - 5.2 counter: A-UL +0.2%, B-UL +0.0%, A-DL -0.1%, B-DL +0.0%. iperf goodput: -3.2 / -6.2 / -1.4 / -3.8%(UL은 헤더·ACK 몫).
  - 5.5 counter: UL `-P 8` -0.1%, DL `-P 4` +0.1%. 5.4 커널 `fq maxrate 20mbit` 대조: goodput 18.29 Mbps(-8.5%).
  - 3.4: veth에서 native XDP rc=0, generic 복귀. 6장: 노트북 B ping 100% 손실, `TX_DROPS` 0 → 3, A 정상. 8.6: 재부팅 후 두 유닛 active, 정책·attach 복원. 9.2: 노트북에서 9090 `http_code=000`.
- 리허설로 대신할 수 없는 것(L4에서만): 실제 노트북 두 대의 NIC(유선·Wi-Fi 공존, NetworkManager, 절전), 물리 스위치, 실제 NIC의 멀티큐(RSS·TX 큐 여러 개 → 5.5가 큐 분산을 실제로 검사하는 것은 L4뿐, VM의 veth는 TX 큐 1개)와 native XDP 드라이버 동작·링크 플랩, 실제 서버 부팅에서의 NIC 등장 시간, sudo 비밀번호 프롬프트와 터미널의 bracketed paste 동작, ufw가 켜진 호스트(VM은 ufw inactive라 2.1·2.3의 ufw 분기는 실행되지 않았다), Grafana UI(9.3).
