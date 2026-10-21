# L4 설치 런북 — 물리 Ubuntu 서비스 노드 (22.04 / 24.04)

Vantage-5G를 물리 서비스 노드에 설치하고 UE 2개(UE-A, UE-B)로 측정한다. **5G 코어(Open5GS·UERANSIM)는 Vantage 입장에서 블랙박스다.** 설치·운영 절차는 코어가 있든 없든 같고, 환경 차이는 변수 파일(0장)의 값으로만 흡수한다.

| 환경 | UE-A / UE-B | 트래픽을 내는 호스트(클라이언트) | `UE_GW` |
|---|---|---|---|
| (가) 코어 없음 — 첫 배포 | 노트북 2대의 유선 IP (서비스 노드 NIC와 같은 서브넷) | 노트북 A, 노트북 B | 비움 |
| (나) 5G 코어 | UERANSIM UE의 `uesimtunN` IP (UE 풀, 예 `10.45.0.0/16`) | UERANSIM 호스트 (A·B가 같은 호스트여도 됨) | UPF의 N6 IP |

- **코어 쪽 설정**(UPF NAT 예외, 포워딩, 그 영구화)은 본문이 아니다. 서비스 노드가 2장에서 결과(전제)만 확인하고, 필요한 설정은 **부록 A(코어 파트에 전달할 요구사항)**로 코어 담당에게 넘긴다.
- **복사·붙여넣기만으로 진행한다.** 손으로 고치는 것은 0.2의 변수 파일뿐이다. 모든 명령은 `"$IF"`, `"$SVC"`, `"$UE_A"`, `"$UE_B"` 같은 변수만 쓴다.
- 대상 커밋: `main`의 `3971b36`(PR #8) 이후. 제품 코드(src/, *.c, setup.sh, detach.sh, install.sh, systemd/)는 `3971b36`과 같다. `COMMIT`(0.2)에는 이 문서가 들어간 뒤의 main 해시를 쓴다.
- 로컬 근거(2026-10-21, 부록 C): 이 문서의 코드 블록 68개를 그대로 추출해 변수 파일만 바꿔 두 환경에서 처음부터 끝까지 실행했다. (가) L2 Ubuntu 22.04 VM 안의 같은 서브넷 토폴로지: 본문 59블록 PASS(5.2·6.5의 처리량 행만 VM 타이머 열화 구간이라 판정 제외), 재부팅·uninstall 후 잔여물 없음. (나) L3(Open5GS 2.8 + UERANSIM 코어 VM, 서비스 노드 Ubuntu 24.04 VM): quickstart NAT에서 2.4가 FAIL(의도한 음성 대조) → 부록 A 7블록 → 본문 59블록 모두 PASS, 타이머 내내 OK, 4세션 counter ±0.0%, 재부팅 후 netplan으로 영구화한 UE 경로 유지.
- 형식: 각 단계는 **명령 / 기대 / 실패 시** 순서다. 명령 블록 위의 굵은 글씨가 그 블록을 붙여넣을 호스트다: **[서비스 노드]**, **[클라이언트 A]**(UE-A 트래픽을 내는 호스트), **[클라이언트 B]**, **[UPF 호스트]**(부록 A만). 한 블록은 한 호스트에서만 실행한다. 클라이언트 A와 B가 같은 호스트(UERANSIM)면 A 블록과 B 블록을 둘 다 그 호스트에서 차례로 붙인다.

## 구성

```
 (가) [노트북 A] UE_A ──┐
                        ├── 스위치 (같은 서브넷, 라우터·NAT 없음) ── IF [서비스 노드 SVC]
      [노트북 B] UE_B ──┘

 (나) [UERANSIM 호스트] uesimtun0 UE_A, uesimtun1 UE_B
            │ (gNB ─ GTP-U)
      [UPF 호스트] ogstun ─ UPF ── N6 ── UE_GW ─────────────────── IF [서비스 노드 SVC]
                   (UE→SVC는 NAT 없음: 부록 A)                     Vantage: XDP RX 폴리서(UL) + tc EDT TX 페이서(DL)
```

- UL = UE → 서비스 노드(iperf3 기본 방향, 정책의 `rx`). DL = 서비스 노드 → UE(iperf3 `-R`, 정책의 `tx`).
- 정책 키는 서비스 노드 `IF`에 도착한 패킷의 UE 주소다. 그래서 Vantage가 요구하는 전제는 두 가지뿐이다(2장): **(전제 1)** 클라이언트가 `-B $UE_x`로 보낸 패킷이 `IF`에 출발지 `$UE_x` 그대로 도착한다(중간 NAT 없음). **(전제 2)** 서비스 노드에서 `$UE_x`로 가는 경로가 `IF`로 나간다(DL이 TX 페이서·killswitch를 지난다).
- 4세션 측정은 **서비스 노드가 SSH로 클라이언트의 iperf3를 구동**한다(5.2, 아래 "동시 시작 방식").

## 붙여넣기 규칙 (먼저 읽기)

1. **블록 하나씩** 붙여넣고 끝날 때까지 기다린다. 블록은 새 터미널에서 붙여도 되도록 첫 줄에서 변수 파일을 읽고(`source ~/vt-l4/vars.sh`) 저장소로 이동한다(`cd ~/vantage-5G`).
2. 블록이 출력하는 `OK   …` / `FAIL …` 줄이 판정이다. `FAIL`이 하나라도 나오면 다음 블록으로 가지 말고 그 단계의 "실패 시"를 본다.
3. **sudo 비밀번호:** 붙여넣은 블록 중간에 sudo가 비밀번호를 물으면, 터미널에 따라 붙여넣은 나머지 줄이 비밀번호 입력으로 먹힐 수 있다. 각 호스트에서 시작할 때와 15분 넘게 쉰 뒤에는 **먼저 아래 한 줄만** 실행해 비밀번호를 넣는다. 블록 첫머리의 `sudo -v`는 이 캐시를 연장할 뿐이다.
   ```
   sudo -v
   ```
4. 출력은 각 호스트의 `~/vt-l4/`에 쌓인다. 끝나면 11장에서 서비스 노드 한 곳으로 모은다.
5. 측정 블록(5.2, 5.4, 5.5, 6.5)은 30~70초 걸린다. 그동안 다른 블록을 붙여넣지 않는다.

### 동시 시작 방식과 근거

4세션(UE별 UL·DL)을 같은 순간에 시작해야 한다. 두 가지 방법을 비교했다.

| | (1) 서비스 노드에서 SSH로 구동 — **채택** | (2) NTP 동기화 후 같은 epoch까지 대기 |
|---|---|---|
| 붙여넣기 | 측정 1회 = 서비스 노드에서 블록 1개 | 측정 1회 = 클라이언트들 + 서비스 노드에 블록 여러 개를 시간 안에 |
| 시계 | 서비스 노드 시계 하나. stats 스냅샷(t1·t2)과 클라이언트 시작이 같은 셸에서 순서대로 | 호스트 시계가 수백 ms 안으로 맞아야 함. 라우터 없는 LAN에서는 NTP 서버에 닿지 않아 `timedatectl`이 `System clock synchronized: no`로 남기 쉽다 |
| 결과 | iperf3 JSON이 SSH 표준출력으로 서비스 노드에 바로 저장 → spec.csv·판정까지 같은 블록 | 클라이언트마다 JSON을 만들고 나중에 scp로 모아야 함 |
| 준비 | 클라이언트에 `openssh-server`, 서비스 노드 키를 한 번 등록(2.3) | 클라이언트 NTP 설정 |
| 실패 모드 | SSH 연결 실패는 즉시 보이고(BatchMode, 5 s 제한) 그 세션 JSON이 비어 판정이 FAIL | 시작 시각을 놓친 호스트는 늦게 시작해 겹치는 구간이 줄어도 조용히 진행됨 |

SSH 시작 지연은 세션당 수백 ms라 판정(앞 5 s 제외, counter 창 t1≈+5 s~t2≈+25 s)에 영향이 없다. **killswitch(6장) 동안 UE-B로 가는 DL이 막히므로** 6.2·6.3은 클라이언트에서 직접 붙여넣는다. SSH 대상(`CLIENT_x_HOST`)이 UE 주소가 아닌 관리 주소면(5G의 UERANSIM 호스트) SSH 자체는 막히지 않는다.

## 0. 변수 파일 (호스트마다 한 번)

### 0.1 변수 파일 만들기
같은 내용을 각 호스트에 만든다. 블록마다 `ROLE`만 미리 채워져 있다. 이미 파일이 있으면 덮어쓰지 않는다(0.2에서 고친 값 보호. 클라이언트 A·B가 같은 호스트면 B 블록은 `already exists`).

<!-- rh: id=0.1-svc host=svc -->
**[서비스 노드]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G install runbook variables (docs/install-runbook.md)
# Replace the values once, on this host:  nano ~/vt-l4/vars.sh
ROLE=svc              # this host: svc | client | upf  (pre-filled by the block)
SVC=CHANGE_ME         # service node IP on IF (the address clients connect to), e.g. 192.168.77.10
UE_A=CHANGE_ME        # UE-A address = policy key = iperf3 -B address (laptop wired IP, or UERANSIM uesimtunN IP)
UE_B=CHANGE_ME        # UE-B address
UE_NET=               # UEs behind a gateway (5G core): UE pool CIDR, e.g. 10.45.0.0/16; empty when UEs share IF's subnet
UE_GW=                # UEs behind a gateway: next hop from the service node to UE_NET (UPF N6 IP); empty when UEs share IF's subnet
# --- service node only (other hosts: leave as is) ---
IF=CHANGE_ME          # service node NIC facing the UEs (N6 / LAN), e.g. enp1s0
CLIENT_A_HOST=CHANGE_ME  # SSH address of the host that sends UE-A traffic (laptop A, or the UERANSIM host)
CLIENT_A_USER=CHANGE_ME  # login user on that host
CLIENT_B_HOST=CHANGE_ME  # same for UE-B (may equal CLIENT_A_HOST)
CLIENT_B_USER=CHANGE_ME
COMMIT=CHANGE_ME      # commit hash to install
# --- measurement policy in Mbps (README section 8 values) ---
A_RX=10
A_TX=20
B_RX=3
B_TX=5
XDP_MODE=generic      # systemd service XDP mode (8.2): generic, or native if 3.5 gave rc=0
MGMT_IP=              # optional (9.3): management address to bind the exporter to for a remote Prometheus
PROM_IP=              # optional (9.3): the only host allowed to scrape it
# --- do not edit below ---
SSHO=(-i "$HOME/.ssh/vt_l4" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
vt_snap() { { echo "t=$(date +%s.%N)"; sudo "$HOME/vantage-5G/target/release/vantage-5G" stats; } > "$1"; }
vt_in() { python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$1" "$2" 2>/dev/null; }
vt_route_ok() { local r; r=$(ip route get "$1" 2>/dev/null | head -1); case "$r" in *"dev $IF "*) ;; *) return 1 ;; esac; if [ -z "$UE_GW" ]; then case "$r" in *" via "*) return 1 ;; esac; else case "$r" in *" via $UE_GW "*) ;; *) return 1 ;; esac; fi; }
if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
if grep -qE '^(SVC|UE_A|UE_B)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook 0.2)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```

<!-- rh: id=0.1-a host=a -->
**[클라이언트 A]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G install runbook variables (docs/install-runbook.md)
# Replace the values once, on this host:  nano ~/vt-l4/vars.sh
ROLE=client           # this host: svc | client | upf  (pre-filled by the block)
SVC=CHANGE_ME         # service node IP on IF (the address clients connect to), e.g. 192.168.77.10
UE_A=CHANGE_ME        # UE-A address = policy key = iperf3 -B address (laptop wired IP, or UERANSIM uesimtunN IP)
UE_B=CHANGE_ME        # UE-B address
UE_NET=               # UEs behind a gateway (5G core): UE pool CIDR, e.g. 10.45.0.0/16; empty when UEs share IF's subnet
UE_GW=                # UEs behind a gateway: next hop from the service node to UE_NET (UPF N6 IP); empty when UEs share IF's subnet
# --- do not edit below ---
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
if grep -qE '^(SVC|UE_A|UE_B)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook 0.2)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```

<!-- rh: id=0.1-b host=b -->
**[클라이언트 B]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G install runbook variables (docs/install-runbook.md)
# Replace the values once, on this host:  nano ~/vt-l4/vars.sh
ROLE=client           # this host: svc | client | upf  (pre-filled by the block)
SVC=CHANGE_ME         # service node IP on IF (the address clients connect to), e.g. 192.168.77.10
UE_A=CHANGE_ME        # UE-A address = policy key = iperf3 -B address (laptop wired IP, or UERANSIM uesimtunN IP)
UE_B=CHANGE_ME        # UE-B address
UE_NET=               # UEs behind a gateway (5G core): UE pool CIDR, e.g. 10.45.0.0/16; empty when UEs share IF's subnet
UE_GW=                # UEs behind a gateway: next hop from the service node to UE_NET (UPF N6 IP); empty when UEs share IF's subnet
# --- do not edit below ---
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
if grep -qE '^(SVC|UE_A|UE_B)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook 0.2)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```
- 기대: `[+] created ~/vt-l4/vars.sh`(다시 붙이면 `already exists`).

### 0.2 값 채우기 (유일한 수동 편집)
각 호스트에서 연다. 값을 바꾸고 저장한다(nano: Ctrl+O, Enter, Ctrl+X).

<!-- rh: id=0.2-svc host=svc mode=edit -->
**[서비스 노드]**
```bash
nano ~/vt-l4/vars.sh
```

<!-- rh: id=0.2-a host=a mode=edit -->
**[클라이언트 A]**
```bash
nano ~/vt-l4/vars.sh
```

<!-- rh: id=0.2-b host=b mode=edit -->
**[클라이언트 B]**
```bash
nano ~/vt-l4/vars.sh
```
- `SVC`, `UE_A`, `UE_B`, `UE_NET`, `UE_GW`는 모든 호스트에 **같은 값**을 쓴다.
- (가) 코어 없음: 각 호스트에서 `ip -br -4 addr`. 서비스 노드의 LAN NIC가 `IF`, 그 주소가 `SVC`, 노트북 유선 주소가 `UE_A`/`UE_B`, `CLIENT_A_HOST`=`UE_A`, `CLIENT_B_HOST`=`UE_B`. `UE_NET`, `UE_GW`는 비운다. 노트북 유선 IP가 DHCP면 측정이 끝날 때까지 고정한다(바뀌면 정책이 맞지 않는다).
- (나) 5G 코어: UERANSIM 호스트에서 `ip -br -4 addr | grep uesimtun` — 주소에서 `/24`(UERANSIM 표시)를 뺀 것이 `UE_A`, `UE_B`(Open5GS 레퍼런스는 등록 순서대로 `10.45.0.2`, `10.45.0.3`). `UE_NET`은 UE 풀(Open5GS 레퍼런스 `10.45.0.0/16`), `UE_GW`는 서비스 노드에서 본 UPF 호스트의 N6 주소, `CLIENT_A_HOST`=`CLIENT_B_HOST`=UERANSIM 호스트의 관리 주소(서비스 노드에서 SSH로 닿는 주소). UE 주소는 PDU 세션을 다시 맺으면 바뀔 수 있다 — 바뀌면 이 파일을 고친다.
- 서비스 노드의 `CLIENT_x_USER`는 그 호스트에서 `whoami`. `COMMIT`은 설치할 main 커밋 해시.
- 측정 정책(`A_RX` …)은 README §8 값이다. 경로가 그보다 느리면(예: UERANSIM은 세션당 수십 Mbps) 낮춘다 — 판정은 이 값 기준이다.

### 0.3 값 검증
`FAIL vars:` 줄이 나오면 0.2로 돌아가 고치고 이 블록을 다시 붙인다. 블록 전체가 괄호 하나로 묶여 있어 실패해도 셸이 닫히지 않는다.

<!-- rh: id=0.3-svc host=svc -->
**[서비스 노드]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  for v in SVC UE_A UE_B IF CLIENT_A_HOST CLIENT_A_USER CLIENT_B_HOST CLIENT_B_USER COMMIT; do eval "x=\$$v"; if [ "$x" = CHANGE_ME ] || [ -z "$x" ]; then echo "FAIL vars: $v is not set"; bad=1; fi; done
  for v in SVC UE_A UE_B; do eval "x=\$$v"; echo "$x" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: $v=$x is not an IPv4 address"; bad=1; }; done
  if [ "$SVC" = "$UE_A" ] || [ "$SVC" = "$UE_B" ] || [ "$UE_A" = "$UE_B" ]; then echo "FAIL vars: SVC, UE_A, UE_B must all differ"; bad=1; fi
  NET_IF=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk -v s="$SVC" '{split($4, a, "/"); if (a[1] == s) print $4}')
  if ! ip link show dev "$IF" >/dev/null 2>&1; then echo "FAIL vars: interface IF=$IF does not exist (check: ip -br link)"; bad=1
  elif [ -z "$NET_IF" ]; then echo "FAIL vars: $IF has no address $SVC (check: ip -4 addr show dev $IF)"; bad=1; fi
  if [ -z "$UE_GW" ]; then
    [ -z "$UE_NET" ] || { echo "FAIL vars: UE_NET is set but UE_GW is empty (set both, or neither)"; bad=1; }
    for u in "$UE_A" "$UE_B"; do vt_in "$u" "$NET_IF" || { echo "FAIL vars: UE_GW empty but $u is not on $IF's subnet $NET_IF"; bad=1; }; done
  else
    vt_in "$UE_GW" "$NET_IF" || { echo "FAIL vars: UE_GW=$UE_GW is not on $IF's subnet $NET_IF"; bad=1; }
    for u in "$UE_A" "$UE_B"; do vt_in "$u" "$UE_NET" || { echo "FAIL vars: $u is not in UE_NET=$UE_NET"; bad=1; }; done
  fi
  if [ $bad = 0 ]; then echo "OK   vars: IF=$IF SVC=$SVC UE_A=$UE_A UE_B=$UE_B UE_NET=${UE_NET:-none} UE_GW=${UE_GW:-none (same subnet)} clients=$CLIENT_A_HOST,$CLIENT_B_HOST"; else echo "FAIL vars: edit ~/vt-l4/vars.sh (0.2) and paste this block again"; fi )
```

<!-- rh: id=0.3-a host=a -->
**[클라이언트 A]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  for v in SVC UE_A UE_B; do eval "x=\$$v"; echo "$x" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: $v=$x is not an IPv4 address"; bad=1; }; done
  ip -4 -o addr show | grep -qF " $UE_A/" || { echo "FAIL vars: no interface on this host has UE_A=$UE_A (check: ip -br -4 addr)"; bad=1; }
  if [ $bad = 0 ]; then echo "OK   vars: client A, UE_A=$UE_A on $(ip -4 -o addr show | grep -F " $UE_A/" | awk '{print $2}'), SVC=$SVC"; else echo "FAIL vars: edit ~/vt-l4/vars.sh (0.2) and paste this block again"; fi )
```

<!-- rh: id=0.3-b host=b -->
**[클라이언트 B]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  for v in SVC UE_A UE_B; do eval "x=\$$v"; echo "$x" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: $v=$x is not an IPv4 address"; bad=1; }; done
  ip -4 -o addr show | grep -qF " $UE_B/" || { echo "FAIL vars: no interface on this host has UE_B=$UE_B (check: ip -br -4 addr)"; bad=1; }
  if [ $bad = 0 ]; then echo "OK   vars: client B, UE_B=$UE_B on $(ip -4 -o addr show | grep -F " $UE_B/" | awk '{print $2}'), SVC=$SVC"; else echo "FAIL vars: edit ~/vt-l4/vars.sh (0.2) and paste this block again"; fi )
```
- 기대: 호스트마다 `OK   vars: …` 한 줄.
- 실패 시: `has no address`면 `IF`가 다른 NIC이거나 IP 오타다. `not on IF's subnet`이면 (가)인데 UE가 다른 서브넷이거나 (나)인데 `UE_GW`를 비운 것이다. 클라이언트의 `no interface … has UE_x`는 노트북이면 유선 IP, UERANSIM이면 PDU 세션(`uesimtunN`이 없음 — UE 등록 실패, `nr-ue` 로그)을 본다.

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
- 실패 시: BTF가 없으면 중단한다(지원 범위 밖). `nproc` > 128 이고 커널 < 6.16(22.04 5.15, 24.04 6.8)이면 LRU 상태 맵(16384)이 CPU별 로컬 free list(CPU당 128)로 소진되어 UE가 몇 개뿐이어도 활성 UE 상태가 퇴출될 수 있다(README §3.1) — 보고서에 적고 X13을 관찰한다(중단 아님).

### 1.2 패키지 (X12)
비대화형으로 설치한다(`iperf3`의 "데몬으로 시작?" 질문, needrestart 대화상자를 건너뜀).

<!-- rh: id=1.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -q 2>&1 | tail -1
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config linux-tools-common "linux-tools-$(uname -r)" iproute2 iperf3 tcpdump ethtool curl git python3 python3-yaml openssh-client 2>&1 | tail -2
bpftool version | tee ~/vt-l4/1.2-bpftool.txt; vt_ck ${PIPESTATUS[0]} "1.2 bpftool usable"
```
- 기대: `OK   1.2 bpftool usable`(`bpftool version`이 버전을 출력, "WARNING: bpftool not found for kernel"이 아님).
- 실패 시: `linux-tools-$(uname -r)` 후보가 없으면(HWE·커스텀 커널) `apt-cache search linux-tools | grep "$(uname -r)"`로 flavour 패키지를 찾는다. `bpftool` 패키지를 따로 찾지 않는다(22.04/24.04 모두 없음).

### 1.3 Rust (rustup, 비대화형)
apt의 `rustc`는 쓰지 않는다(`rust-version = "1.89"`, 잠금에 쓰는 `File::try_lock`). 변수 파일이 `~/.cargo/env`를 읽으므로 이후 새 셸에서도 `cargo`가 잡힌다.

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
- 기대: `OK` 두 줄. 세 스크립트에 실행 권한(`x`)이 있다.
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
- 기대: 드라이버(`driver:`), 큐 수, root qdisc(`mq`일 수 있음), `tx queues in use: N`(할당 수는 `ip -d link`의 `numtxqueues`), `net.core.default_qdisc`가 기록되고 `OK` 두 줄. `gro_max_size`/`gro_ipv4_max_size`가 나오면 65536 이하(X15, BIG TCP 비활성).
- 실패 시: 다른 도구의 XDP나 egress 필터가 있으면 그 소유자와 먼저 조율한다(`setup.sh`가 rc=3으로 거부한다). gro 값이 65536보다 크면 기록하고 계속한다. UL에서 큰 프레임 영구 드롭이 의심되면 보고한다.

## 2. 클라이언트 준비와 Vantage 전제 확인

### 2.1 클라이언트 패키지, SSH 서버, 방화벽
iperf3, openssh-server, curl을 설치한다. ufw가 켜져 있으면 서비스 노드의 SSH만 허용한다.

<!-- rh: id=2.1-a host=a -->
**[클라이언트 A]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -q 2>&1 | tail -1
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q iperf3 openssh-server curl 2>&1 | tail -2
sudo systemctl enable --now ssh 2>&1 | tail -1
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then sudo ufw allow 22/tcp; fi
iperf3 --version | head -1; vt_ck ${PIPESTATUS[0]} "2.1 client A: iperf3 installed"
```

<!-- rh: id=2.1-b host=b -->
**[클라이언트 B]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -q 2>&1 | tail -1
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q iperf3 openssh-server curl 2>&1 | tail -2
sudo systemctl enable --now ssh 2>&1 | tail -1
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then sudo ufw allow 22/tcp; fi
iperf3 --version | head -1; vt_ck ${PIPESTATUS[0]} "2.1 client B: iperf3 installed"
```
- 기대: `OK   2.1 client A: iperf3 installed`(B도 같음). SSH가 실제로 되는지는 2.3에서 서비스 노드가 확인한다.
- 실패 시: apt가 인터넷에 닿지 않으면(노트북의 인터넷은 보통 Wi-Fi) Wi-Fi를 켠 채로 다시 실행한다.

### 2.2 클라이언트 바인딩 확인 (`-B $UE_x`가 그 UE 인터페이스로 나가는가)
이후 모든 iperf3·ping은 `-B $UE_x`/`-I $UE_x`(출발지 주소 지정)로 보낸다. 그 출발지로 서비스 노드에 가는 경로가 **UE 주소를 가진 인터페이스**여야 한다 — 노트북은 유선 NIC(Wi-Fi가 같이 있어도 됨), UERANSIM은 `uesimtunN`.

<!-- rh: id=2.2-a host=a -->
**[클라이언트 A]**
```bash
source ~/vt-l4/vars.sh
{ ip -br -4 addr; ip route get "$SVC" from "$UE_A"; } 2>&1 | tee ~/vt-l4/2.2-bind-A.txt
dev=$(ip route get "$SVC" from "$UE_A" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
ip -4 -o addr show dev "${dev:-none}" 2>/dev/null | grep -qF " $UE_A/"; vt_ck $? "2.2 client A: traffic from $UE_A to $SVC leaves via ${dev:-?}, the interface that owns $UE_A"
```

<!-- rh: id=2.2-b host=b -->
**[클라이언트 B]**
```bash
source ~/vt-l4/vars.sh
{ ip -br -4 addr; ip route get "$SVC" from "$UE_B"; } 2>&1 | tee ~/vt-l4/2.2-bind-B.txt
dev=$(ip route get "$SVC" from "$UE_B" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
ip -4 -o addr show dev "${dev:-none}" 2>/dev/null | grep -qF " $UE_B/"; vt_ck $? "2.2 client B: traffic from $UE_B to $SVC leaves via ${dev:-?}, the interface that owns $UE_B"
```
- 기대: `OK` 한 줄. 노트북이면 `… dev <유선 NIC> src <UE_x>`, UERANSIM이면 `… dev uesimtunN table …`.
- 실패 시:
  - 노트북에서 `dev`가 Wi-Fi NIC이면 Wi-Fi가 같은 대역을 쓰는 것이다 — Wi-Fi를 끄거나 다른 네트워크에 연결한다. `via`가 있으면(라우터 경유) (가)의 전제가 아니다.
  - UERANSIM에서 `dev`가 `uesimtunN`이 아니고 LAN NIC이면 `-B`만으로는 5G 경로를 타지 않는다(UERANSIM의 출발지 정책 라우팅이 없음). 이때는 iperf3를 UERANSIM `build/`의 `nr-binder`로 실행해야 하고(`cd ~/UERANSIM/build && ./nr-binder "$UE_A" iperf3 -c "$SVC" …` — `./libdevbnd.so`를 상대 경로로 preload하므로 `build/`에서 실행), 5.2 등의 SSH 명령을 그에 맞게 바꿔야 한다. 이 경우를 보고하고 진행 방법을 정한다.

### 2.3 SSH 키 등록 (서비스 노드 → 클라이언트, 한 번)
클라이언트 로그인 비밀번호를 A, B 순서로 한 번씩 묻는다(같은 호스트면 두 번째는 `already exist`). 호스트 키는 자동으로 받아들인다(`accept-new`).

<!-- rh: id=2.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
mkdir -p -m 700 ~/.ssh; test -f ~/.ssh/vt_l4 || ssh-keygen -q -t ed25519 -N '' -C vantage-vt-l4 -f ~/.ssh/vt_l4
ssh-copy-id -i ~/.ssh/vt_l4.pub -o StrictHostKeyChecking=accept-new "$CLIENT_A_USER@$CLIENT_A_HOST" </dev/null 2>&1 | tail -2
ssh-copy-id -i ~/.ssh/vt_l4.pub -o StrictHostKeyChecking=accept-new "$CLIENT_B_USER@$CLIENT_B_HOST" </dev/null 2>&1 | tail -2
for h in "$CLIENT_A_USER@$CLIENT_A_HOST" "$CLIENT_B_USER@$CLIENT_B_HOST"; do ssh "${SSHO[@]}" -n "$h" 'hostname; iperf3 --version | head -1'; vt_ck $? "2.3 key login to $h"; done
```
- 기대: 비밀번호 입력 후 ssh-copy-id 출력 끝(`… make sure that only the key(s) you wanted were added.`, 이미 등록되어 있으면 `All keys were skipped because they already exist`), 클라이언트 호스트 이름과 iperf3 버전, `OK` 두 줄.
- 실패 시: `Connection refused`/`timed out`이면 클라이언트 sshd(2.1)와 방화벽, `CLIENT_x_HOST`가 서비스 노드에서 닿는 주소인지 본다. `Permission denied`면 사용자 이름이나 비밀번호를 확인한다.

### 2.4 전제 1 — UE 주소가 그대로 `IF`에 도착하는가 (X5)
서비스 노드가 `IF`에서 ICMP를 잡는 동안 각 클라이언트가 `-I $UE_x`로 ping을 보낸다. 출발지가 `$UE_x`여야 한다. 아직 귀환 경로(2.5)가 없으면 ping 응답은 실패해도 된다(도착만 본다).

<!-- rh: id=2.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
for x in A B; do
  if [ $x = A ]; then u=$UE_A; h="$CLIENT_A_USER@$CLIENT_A_HOST"; else u=$UE_B; h="$CLIENT_B_USER@$CLIENT_B_HOST"; fi
  sudo timeout 15 tcpdump -lni "$IF" -c 3 "icmp and dst host $SVC" > ~/vt-l4/2.4-tcpdump-$x.txt 2>/dev/null &
  sleep 2; ssh "${SSHO[@]}" -n "$h" "ping -c 3 -W 1 -I $u $SVC" > ~/vt-l4/2.4-ping-$x.txt 2>&1; wait
  cat ~/vt-l4/2.4-tcpdump-$x.txt
  grep -q "IP $u > $SVC: ICMP echo request" ~/vt-l4/2.4-tcpdump-$x.txt; vt_ck $? "2.4 premise 1: packets from $u arrive on $IF with source $u (no NAT)"
done
```
- 기대: 클라이언트마다 `IP <UE_x> > <SVC>: ICMP echo request` 줄들과 `OK`.
- 실패 시: **중단한다.** 출발지가 다른 주소(5G에서는 UPF의 N6 주소)로만 보이면 중간에 NAT가 있다 — 이 상태에서는 per-UE 정책이 하나도 맞지 않는다. **부록 A**를 코어 담당에게 전달해 UE→서비스 노드 NAT 예외를 받은 뒤 이 블록을 다시 붙인다. 아무것도 안 잡히면 클라이언트 바인딩(2.2), (나)에서는 UE의 PDU 세션과 UPF 포워딩(부록 A.3)을 본다.

### 2.5 전제 2 — 서비스 노드에서 UE로 가는 경로가 `IF`인가 (귀환 경로)
DL 응답이 Vantage가 붙은 `IF`로 나가야 TX 페이서와 killswitch가 적용된다(tc egress 훅은 그 NIC에만 있다). `UE_GW`가 비어 있으면 확인만 한다. `UE_GW`가 있고 경로가 아니면 `UE_NET via UE_GW dev IF`를 넣는다(재부팅 영구화는 2.6).

<!-- rh: id=2.5 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
{ ip route get "$UE_A"; ip route get "$UE_B"; } 2>&1 | tee ~/vt-l4/2.5-route-before.txt
if [ -n "$UE_GW" ]; then if vt_route_ok "$UE_A" && vt_route_ok "$UE_B"; then echo "[i] route to $UE_NET via $UE_GW dev $IF already in place"; else sudo ip route replace "$UE_NET" via "$UE_GW" dev "$IF"; echo "[+] ip route replace $UE_NET via $UE_GW dev $IF"; fi; fi
for u in "$UE_A" "$UE_B"; do ip route get "$u" | head -1; vt_route_ok "$u"; vt_ck $? "2.5 premise 2: route to $u is dev $IF${UE_GW:+ via $UE_GW}"; done
```
- 기대: `OK` 두 줄. (가) `… dev <IF> src <SVC>`(via 없음). (나) `… via <UE_GW> dev <IF> …`.
- 실패 시: (가)에서 `via`가 있거나 다른 `dev`면 UE가 `IF`와 같은 서브넷이 아니다 — 0.2의 값을 확인한다. (나)에서 `RTNETLINK answers: Network is unreachable`이면 `UE_GW`가 `IF`의 서브넷에 없다(0.3이 잡는다). 다른 경로가 더 구체적(예: `/24`)이면 `ip route show | grep "$IF"`를 보고한다.

### 2.6 귀환 경로 영구화 (`UE_GW`가 있을 때만, netplan)
기존 `/etc/netplan/` 파일을 **덮어쓰지 않는다**(DHCP·게이트웨이·DNS·다른 인터페이스 설정이 사라진다). `IF`를 정의한 netplan 키를 찾아 경로만 담은 drop-in(`/etc/netplan/90-vantage-ue-route.yaml`)을 만든다. netplan은 같은 키를 파일 이름순으로 병합하지만 `routes:` 목록은 **덧붙지 않고 대체**되므로, 그 키에 이미 `routes:`가 있으면 drop-in을 만들지 않고 멈춘다. 지금 경로는 2.5에서 이미 들어가 있으므로 `netplan apply`/`try`는 하지 않고 `netplan generate`로 검사만 한다 — 적용은 다음 부팅(8.5 재부팅 후 8.6에서 확인).

<!-- rh: id=2.6 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
if [ -z "$UE_GW" ]; then echo "[i] UE_GW empty (UEs share $IF's subnet): no route to persist"; else
  KEY=$(sudo netplan get ethernets 2>/dev/null | python3 -c 'import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
ifn, mac = sys.argv[1], sys.argv[2].lower()
for k, v in d.items():
    v = v or {}; m = v.get("match") or {}
    if k == ifn or v.get("set-name") == ifn or m.get("name") == ifn or str(m.get("macaddress", "")).lower() == mac:
        print(k); break' "$IF" "$(cat /sys/class/net/"$IF"/address)")
  echo "netplan key for $IF: ${KEY:-<none>}"
  if [ -z "$KEY" ]; then echo "FAIL 2.6 $IF is not configured by netplan here; persist '$UE_NET via $UE_GW' with the tool that configures $IF"
  else
    R=$(sudo netplan get "ethernets.$KEY.routes" 2>/dev/null)
    if echo "$R" | grep -qF "$UE_NET"; then echo "[i] $UE_NET already in netplan ethernets.$KEY.routes"
    elif [ -n "$R" ] && [ "$R" != null ]; then echo "FAIL 2.6 ethernets.$KEY already has routes: (a drop-in would replace them); add '- to: $UE_NET' / 'via: $UE_GW' to that list in its file by hand"
    else printf '%s\n' 'network:' '  version: 2' '  ethernets:' "    $KEY:" '      routes:' "        - to: $UE_NET" "          via: $UE_GW" | sudo tee /etc/netplan/90-vantage-ue-route.yaml > /dev/null; sudo chmod 600 /etc/netplan/90-vantage-ue-route.yaml; echo "[+] wrote /etc/netplan/90-vantage-ue-route.yaml"; fi
    sudo netplan get "ethernets.$KEY" | tee ~/vt-l4/2.6-netplan.txt
    sudo netplan generate; vt_ck $? "2.6 netplan generate"
    sudo netplan get "ethernets.$KEY.routes" | grep -qF "$UE_NET"; vt_ck $? "2.6 $UE_NET via $UE_GW persisted (netplan ethernets.$KEY)"
  fi
fi
```
- 기대: (가) `[i] UE_GW empty …`. (나) `[+] wrote …`(또는 `already`), `netplan get` 출력에 기존 주소(또는 `dhcp4`)와 새 경로가 함께 있고 `OK` 두 줄.
- 실패 시: `not configured by netplan`이면(NetworkManager 단독, ifupdown 등) 그 도구로 같은 경로를 영구화하고 기록한다. `already has routes:`면 출력된 대로 그 파일의 목록에 항목을 추가한 뒤 `sudo netplan generate`. `netplan generate`가 오류를 내면 drop-in을 지우고(`sudo rm /etc/netplan/90-vantage-ue-route.yaml`) 오류를 보고한다 — 이 상태로 `netplan apply`를 실행하지 않는다.

### 2.7 종단 확인과 iperf3 포트

<!-- rh: id=2.7 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
for x in A B; do
  if [ $x = A ]; then u=$UE_A; h="$CLIENT_A_USER@$CLIENT_A_HOST"; else u=$UE_B; h="$CLIENT_B_USER@$CLIENT_B_HOST"; fi
  ssh "${SSHO[@]}" -n "$h" "ping -c 3 -W 2 -I $u $SVC" | tail -2; vt_ck ${PIPESTATUS[0]} "2.7 $u <-> $SVC end to end (ping from the client, replies back)"
done
sudo ufw status 2>/dev/null | head -1
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then for u in "$UE_A" "$UE_B"; do sudo ufw allow from "$u" to any port 5201:5204 proto tcp; done; fi
```
- 기대: `0% packet loss`와 `OK` 두 줄. ufw가 active이면 `Rule added` 두 줄(5201~5204/tcp, UE 주소에서만).
- 실패 시: 요청은 2.4에서 보였는데 응답이 안 오면 2.5(귀환 경로)를, (나)에서는 UPF 호스트의 포워딩과 서비스 노드 대역 경로(부록 A.3)를 본다.

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
- 실패 시: `bpftool not usable (Ubuntu: apt install linux-tools-common linux-tools-<kver>)`이면 1.2. `cargo not found`면 1.3. verifier/BTF 오류면 `make clean && make build`로 재시도하고 출력 전체를 보고한다.

### 3.2 잔여 루트 핀 정리 (X4/V14 — 이 서버에서 구버전을 돌린 적이 있을 때)
구 빌드는 맵을 `/sys/fs/bpf/` 바로 아래에 핀했다. 남아 있으면 확인 후 지운다. `/sys/fs/bpf/vantage/` 안은 건드리지 않는다. 처음 설치하는 서버면 `OK`만 나온다.

<!-- rh: id=3.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo ls /sys/fs/bpf | tee ~/vt-l4/3.2-bpffs.txt
for m in ue_policy_map ue_stats_map rx_state_map tx_tstamp_map; do if sudo test -e /sys/fs/bpf/$m; then sudo bpftool map show pinned /sys/fs/bpf/$m; sudo rm -f /sys/fs/bpf/$m; echo "[+] removed legacy root pin /sys/fs/bpf/$m"; fi; done
[ -z "$(sudo ls /sys/fs/bpf | grep -xE 'ue_policy_map|ue_stats_map|rx_state_map|tx_tstamp_map')" ]; vt_ck $? "3.2 no legacy root pins under /sys/fs/bpf"
```
- 기대: `OK`. 다른 도구의 핀은 무관하다.

### 3.3 load (V20)

<!-- rh: id=3.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./target/release/vantage-5G load 2>&1 | tee ~/vt-l4/3.3-load1.txt; vt_ck ${PIPESTATUS[0]} "3.3 load"
sudo ./target/release/vantage-5G load 2>&1 | tee ~/vt-l4/3.3-load2.txt; vt_ck ${PIPESTATUS[0]} "3.3 load again (idempotent)"
grep -q 'already pinned' ~/vt-l4/3.3-load2.txt; vt_ck $? "3.3 second load skipped"
for m in rx_state_map tx_tstamp_map ue_stats_map ue_policy_map; do sudo bpftool map show pinned /sys/fs/bpf/vantage/$m; done 2>&1 | tee ~/vt-l4/3.3-maps.txt
[ "$(grep -c lru_hash ~/vt-l4/3.3-maps.txt)" = 3 ] && [ "$(grep -c 'max_entries 16384' ~/vt-l4/3.3-maps.txt)" = 3 ]; vt_ck $? "3.3 three LRU maps x16384 (V20)"
free -m | head -2
```
- 기대: `OK` 네 줄. 첫 load 출력 첫 줄이 `[i] BPF objects from /home/<user>/vantage-5G`. 맵은 `lru_hash` 3개(`max_entries 16384`, load 시 전량 사전 할당)와 `ue_policy_map` `hash`(1024). `memlock` 합계는 24.04(6.8)에서 약 4.5 MiB(로컬 4,721,856 B), 22.04(5.15)에서 약 1.5 MiB(로컬 1,572,864 B)로 표시된다(README §3.1) — `3.3-maps.txt`에 기록된다.
- 실패 시: `pinned maps under /sys/fs/bpf/vantage do not match the object:`이면 이전 버전이 이 서버에서 돌고 있다 — **부록 B(업그레이드)**. `Error: BPF object files not found`면 나열된 누락 파일을 보고 3.1을 확인한다(`load`는 `<exe>/../..` → exe 디렉터리 → 현재 디렉터리 순으로 .o를 찾는다. README §12.3).

### 3.4 setup.sh (generic, 재실행, 비root) — X7, X21

<!-- rh: id=3.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sysctl net.core.default_qdisc | tee ~/vt-l4/3.4-dq-before.txt
sudo ./setup.sh "$IF" 2>&1 | tee ~/vt-l4/3.4-setup1.txt; vt_ck ${PIPESTATUS[0]} "3.4 setup.sh"
tc qdisc show dev "$IF" | tee ~/vt-l4/3.4-qdisc1.txt
sudo ./setup.sh "$IF" > ~/vt-l4/3.4-setup2.txt 2>&1; vt_ck $? "3.4 setup.sh re-run"
tc qdisc show dev "$IF" > ~/vt-l4/3.4-qdisc2.txt; diff ~/vt-l4/3.4-qdisc1.txt ~/vt-l4/3.4-qdisc2.txt; vt_ck $? "3.4 re-run kept the qdiscs (same handles)"
./setup.sh "$IF" > ~/vt-l4/3.4-setup-nonroot.txt 2>&1; vt_ck $? "3.4 setup.sh as sudo user (non-root)"
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*' | tee ~/vt-l4/3.4-xdp.txt; tc filter show dev "$IF" egress | head -2
sysctl net.core.default_qdisc | diff - ~/vt-l4/3.4-dq-before.txt; vt_ck $? "3.4 net.core.default_qdisc unchanged"
ls /run/vantage-5g.default_qdisc 2>&1 | tail -1
```
- 기대: `OK` 다섯 줄. 플래그 없이 실행하면 generic이다: `ip link` 첫 줄에 `xdpgeneric`, `prog/xdp id <핀 id>`, `clsact`, egress `… direct-action …` 필터 1개. qdisc는 1.5의 TX 큐 수 N에 따라 다르다.
  - N=1: root `fq`, 출력 끝 `TX qdisc  root fq`.
  - N≥2: root `mq 1:`이고 **모든 mq 클래스**(`parent 1:1` … `parent 1:<M, 16진수>`, M=numtxqueues, 쓰지 않는 큐 포함)가 `fq`. 출력 끝 `TX qdisc  root mq 1: + fq on all M mq classes (N TX queues in use)`. 첫 실행에 `current root: mq 0:; creating root mq 1:`, `net.core.default_qdisc`가 fq가 아니었으면 `… -> fq for the mq creation only`와 `… restored to <값>`. M > N이면 `setting fq on mq classes: 1:<N+1> …`.
  - 마지막 줄 `ls: cannot access '/run/vantage-5g.default_qdisc'`(파일 없음이 정상).
- 실패 시: rc=2면 `bpftool version`(1.2). rc=3이면 출력의 `[-]` 줄: 남의 XDP 프로그램·필터, `ingress` qdisc, `has a qdisc using handle 1:`(멀티큐에서 root `prio 1:`/`htb 1:` 등 — 쓰는 곳이 없으면 `sudo tc qdisc del dev "$IF" root` 후 재실행), `kernel module(s) not available`(`sch_fq`/`cls_bpf`/`sch_ingress`, `modinfo <모듈>` 결과를 기록). rc=5면 `step failed … may be partially attached`를 기록하고 `sudo ./detach.sh "$IF"` 후 원인을 고쳐 재실행. rc=4면 `[-] verify: …` 줄을 보고한다(예: `TX queue classes without fq under root …`). 시작 시 `[!] /run/vantage-5g.default_qdisc exists`가 나오면 이전 실행이 중단된 것이다 — 출력된 복구 명령(`sudo sysctl -w net.core.default_qdisc=<원래값>`, 파일 삭제)을 실행한다. `default_qdisc unchanged`가 FAIL이면 `sudo sysctl -w net.core.default_qdisc=$(awk '{print $3}' ~/vt-l4/3.4-dq-before.txt)`로 되돌리고 보고한다. 큐 N≥2에서 첫 실행 순간(`mq 0:` → `mq 1:`) 큐에 있던 패킷은 버려진다 — 트래픽이 흐르던 중이면 `sudo dmesg | tail`과 함께 기록한다(X7).

### 3.5 native XDP 시도 (선택) — X8
`1.5-nic.txt`의 드라이버가 native XDP를 지원하면(예: ixgbe, i40e, ice, mlx5, virtio_net) 결과를 기록한다. 일부 드라이버는 attach/detach 때 **링크가 잠깐 끊긴다** — 서비스 노드에 접속한 SSH가 `IF`를 거치지 않는지, 트래픽이 없는 시간인지 먼저 확인한다. 블록은 마지막에 generic으로 되돌린다.

<!-- rh: id=3.5 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./setup.sh "$IF" --xdp-mode native 2>&1 | tee ~/vt-l4/3.5-native.txt; echo "native_rc=${PIPESTATUS[0]}" | tee -a ~/vt-l4/3.5-native.txt
ip -d link show dev "$IF" | head -3 | tee -a ~/vt-l4/3.5-native.txt; sudo dmesg | tail -5 > ~/vt-l4/3.5-dmesg.txt
sudo ./setup.sh "$IF" > ~/vt-l4/3.5-generic.txt 2>&1; vt_ck $? "3.5 back to generic"
ip -d link show dev "$IF" | grep -qw xdpgeneric; vt_ck $? "3.5 xdpgeneric again"
```
- 기대(지원): `native_rc=0`, 출력에 `moving the Vantage program (id …) from 'xdpgeneric' to native mode`와 `RX policer (XDP native, id <n>)`, `ip link` 첫 줄에 `xdp`. 기대(미지원): `native_rc=3`, `[-] XDP attach in native mode failed: …`(예: `Underlying driver does not support XDP in native mode`), 드라이버명, `Use '--xdp-mode generic'`, 이어서 `restoring the previous attach (xdpgeneric, …)`. 둘 다 정상이며 마지막 `OK` 두 줄.
- 실패 시: `native_rc=4`와 `restore failed: <IF> has NO XDP RX policer now.`이면 바로 `sudo ./setup.sh "$IF"`를 실행하고 보고한다. 링크 끊김 시간(`3.5-dmesg.txt`의 `Link is Down/Up`)을 기록한다. 서비스(8장)를 native로 돌리려면 `native_rc=0`일 때만 `vars.sh`의 `XDP_MODE=native`로 바꾼다.

### 3.6 bpftool 없는 상태의 거부 (선택)
`setup.sh`는 bpftool이 없으면 아무것도 바꾸지 않고 rc=2로 멈춰야 한다. bpftool을 한 줄 안에서 잠깐 숨겼다가 되돌린다.

<!-- rh: id=3.6 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
X1=$(ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*')
sudo mv /usr/sbin/bpftool /usr/sbin/bpftool.off; sudo ./setup.sh "$IF" > ~/vt-l4/3.6-nobpftool.txt 2>&1; rc=$?; sudo mv /usr/sbin/bpftool.off /usr/sbin/bpftool
tail -3 ~/vt-l4/3.6-nobpftool.txt; [ $rc = 2 ]; vt_ck $? "3.6 setup.sh refuses without bpftool (rc=2)"
[ "$(ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*')" = "$X1" ]; vt_ck $? "3.6 attach state unchanged"
bpftool version > /dev/null; vt_ck $? "3.6 bpftool restored"
```
- 기대: `linux-tools-$(uname -r)` 안내와 `OK` 세 줄.
- 실패 시: `bpftool restored`가 FAIL이면 `sudo mv /usr/sbin/bpftool.off /usr/sbin/bpftool`. attach 상태가 바뀌었으면 즉시 `sudo ./setup.sh "$IF"`를 실행하고 보고한다.

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
- 기대: `[+] policy set: UE <UE_A> rx=… Mbps tx=… Mbps` 등, `list`에 두 UE, `OK` 두 줄. 같은 값 재적용은 정책만 덮어쓰고 RX 토큰버킷·TX EDT 상태를 유지한다(`(unchanged; rx/tx state kept)`). 값이 바뀌면 이 문구가 없고 상태가 초기화된다. 강제 초기화는 `reset` 후 `set`.
- 실패 시: `open pinned ue_policy_map (run vantage-5G load first; needs root)`이면 3.3. `invalid value … for '--ue-ip <UE_IP>'`(rc=2)이면 0.2의 IP에 `/24`가 붙었는지 본다.

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
서비스 노드가 SSH로 클라이언트에서 UL·DL 클라이언트 4개를 동시에 시작하고, 시작 후 약 5초(t1)와 25초(t2)에 `stats` 스냅샷을 남긴다(X3 B안 counter 판정용). 결과는 `~/vt-l4/m4-<시각>/`에 쌓이므로 다시 붙여도 이전 결과를 덮지 않는다(서비스 상태 8장에서 다시 재도 된다).

<!-- rh: id=5.2 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/m4-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5201 -t 30 -J"    > "$D/a_ul.json" &
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -J" > "$D/a_dl.json" &
ssh "${SSHO[@]}" -n "$CLIENT_B_USER@$CLIENT_B_HOST" "iperf3 -c $SVC -B $UE_B -p 5202 -t 30 -J"    > "$D/b_ul.json" &
ssh "${SSHO[@]}" -n "$CLIENT_B_USER@$CLIENT_B_HOST" "iperf3 -c $SVC -B $UE_B -p 5204 -t 30 -R -J" > "$D/b_dl.json" &
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
- 기대: counter 판정 4행 모두 `PASS`(±10%, 로컬 22.04 VM 기준 ±1% 안팎)와 `OK   5.2 counter verdict`. iperf goodput은 UL이 헤더·ACK 몫만큼 -1~-7% 낮게 읽히는 것이 정상이다(README §8.5). **처리량 판정의 기준은 counter 판정이다.**
- Ubuntu 24.04 서버라면 B-UL(3 Mbps) 행을 따로 기록한다(X27: 로컬 24.04 VM에서 이 행만 -9~-12% 미달한 적이 있음, 미분류). 미달이면 B-UL 단독(`ssh "${SSHO[@]}" -n "$CLIENT_B_USER@$CLIENT_B_HOST" "iperf3 -c $SVC -B $UE_B -p 5202 -t 30 -J" > ~/vt-l4/b_ul_solo.json`)을 한 번 더 재서 비교한다.
- 실행 중 확인(선택, 다른 터미널): `sudo ~/vantage-5G/target/release/vantage-5G stats`에 두 UE 행이 있고 rx_bytes/tx_bytes가 증가한다.
- 실패 시:
  - cap **초과**(counter `over cap`)는 즉시 보고한다. 함께: `tc qdisc show dev "$IF"`(root가 fq/mq+fq인지), `stats`에 UE 행이 있는지, 2.4(NAT), 2.5(`ip route get`).
  - `FAIL (no counters for UE)`이면 Vantage가 그 UE 주소를 보지 못했다 — 2.4를 다시 붙인다(코어 쪽 NAT가 되살아났을 수 있음). iperf `cannot read`/`iperf3 error`이면 그 세션이 돌지 않았다 — `$D/*.json`이 비었으면 SSH(2.3)·5.1 서버, `unable to connect`면 2.5·2.7.
  - 미달이면 5.4(커널 셰이퍼 대조)를 하고 서버 CPU(`mpstat -P ALL 1 5`, sysstat)를 기록한다. (나)에서는 무선 구간(UERANSIM 용량, 세션당 수십 Mbps)이 병목일 수 있다 — 0.2의 정책 값을 경로 용량 아래로 낮춘다.

### 5.3 측정 직후 상태

<!-- rh: id=5.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
{ sudo ./target/release/vantage-5G stats; tc -s qdisc show dev "$IF"; ethtool -S "$IF" 2>&1 | grep -iE 'drop|miss' | head; } 2>&1 | tee ~/vt-l4/5.3-after.txt
```
- 기대: 두 UE 행. 정상 TCP에서는 `TX_DROPS`가 0 근처, fq `dropped`가 작다. 장기 운영에서 활성 UE의 카운터가 0으로 돌아가면 X13(1.1)을 의심한다. native XDP에서는 `RX_PKTS`가 드라이버 수신 프레임 기준이다(X15).

### 5.4 커널 셰이퍼 대조 (선택, 5.2에서 DL이 cap보다 10% 넘게 낮을 때)
경로 자체가 cap을 못 내는 것인지, 페이서 문제인지를 가른다. 같은 NIC에서 커널 `fq maxrate`(플로우당 상한)로 같은 속도를 걸고 UE-A의 DL 한 세션을 잰다. 대조 중 UE-A는 Vantage 정책이 없으니 트래픽이 없는 시간에 한다. 블록 끝에서 복구한다(`replace root fq`로는 maxrate가 남으므로 반드시 del 후 `setup.sh`).

<!-- rh: id=5.4 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/kfq-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
sudo ./target/release/vantage-5G reset --ue-ip "$UE_A"
sudo tc qdisc del dev "$IF" root; sudo tc qdisc add dev "$IF" root fq maxrate "${A_TX}mbit"; tc qdisc show dev "$IF" | tee "$D/qdisc-control.txt"
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -J" > "$D/a_dl_kfq.json"
sudo tc qdisc del dev "$IF" root; sudo ./setup.sh "$IF" > "$D/setup-restore.txt" 2>&1; vt_ck $? "5.4 restore: setup.sh"
sudo ./target/release/vantage-5G set --ue-ip "$UE_A" --rx-mbps "$A_RX" --tx-mbps "$A_TX"
tc qdisc show dev "$IF" | tee "$D/qdisc-restored.txt" | grep -q maxrate; [ $? = 1 ]; vt_ck $? "5.4 restore: no maxrate left"
cat > "$D/spec.csv" <<EOF
label,ue_ip,direction,cap_mbps,json_path
A-DL-kernel-fq,$UE_A,DL,$A_TX,a_dl_kfq.json
EOF
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py "$D/spec.csv" | tee "$D/iperf_verdict.txt"
```
- 기대: 복구 `OK` 두 줄. 판정 행은 참고값이다: 커널 fq도 5.2의 A-DL과 같은 폭으로 미달하면 경로·환경 문제(서버 CPU, NIC 오프로드, 무선 구간)로, 커널 fq는 cap에 맞는데 Vantage만 미달하면 datapath 문제로 보고한다.
- 실패 시: `maxrate`가 남아 있으면 `sudo tc qdisc del dev "$IF" root; sudo ./setup.sh "$IF"`를 다시 실행하고 4.1의 A `set`을 다시 넣는다.

### 5.5 멀티 플로우: UL `-P 8` (X14), DL `-P 4` (X20) (약 70초)
UE-A 하나에 플로우 여러 개를 걸어도 UE 합계가 cap인지 본다. RSS 멀티큐 NIC에서는 UL 플로우가 여러 RX 큐(여러 CPU)로, DL 플로우가 여러 TX 큐의 fq로 나뉜다.

<!-- rh: id=5.5 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/mq-ul-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5201 -t 30 -P 8 -J" > "$D/a_ul_p8.json" &
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
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -P 4 -J" > "$D/a_dl_p4.json" &
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
- 실패 시: UL cap **초과**면 초과 폭과 `ethtool -l "$IF"`(RX 큐 수)를 기록해 보고한다(D5a 잔여 경합, X14). DL cap 초과면 즉시 보고한다(`tc qdisc show dev "$IF"`로 모든 큐가 fq인지, 3.4).

## 6. killswitch와 D4

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

### 6.2 클라이언트 B: 서비스 노드 ping 실패

<!-- rh: id=6.2 host=b -->
**[클라이언트 B]**
```bash
source ~/vt-l4/vars.sh
ping -c 3 -W 1 -I "$UE_B" "$SVC" > ~/vt-l4/6.2-ping-B.txt 2>&1; rc=$?; tail -2 ~/vt-l4/6.2-ping-B.txt; [ $rc != 0 ]; vt_ck $? "6.2 client B: ping $SVC from $UE_B fails under killswitch"
```
- 기대: `3 packets transmitted, 0 received, 100% packet loss`, `OK`.
- 실패 시: 응답이 오면 6.1의 `set` 출력과 2.5(DL이 `IF`로 나가는지)를 확인해 보고한다.

### 6.3 클라이언트 A: 정상

<!-- rh: id=6.3 host=a -->
**[클라이언트 A]**
```bash
source ~/vt-l4/vars.sh
ping -c 3 -W 1 -I "$UE_A" "$SVC" > ~/vt-l4/6.3-ping-A.txt 2>&1; vt_ck $? "6.3 client A: ping $SVC from $UE_A works"; tail -2 ~/vt-l4/6.3-ping-A.txt
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
ssh "${SSHO[@]}" -n "$CLIENT_B_USER@$CLIENT_B_HOST" "ping -c 2 -W 2 -I $UE_B $SVC" > /dev/null; vt_ck $? "6.4 UE_B reachable again"
```
- 기대: `TX_DROPS`가 늘었고 복구 후 UE-B가 다시 닿는다. `OK` 두 줄.

### 6.5 D4 변형: DL UDP 과부하 직후 TCP (약 30초)
UE-A의 DL을 1 Mbps로 두고 서비스 노드가 UE-A로 UDP 100 Mbit/s를 10초 보낸 직후 TCP DL을 연다. TCP가 연결되고 1 Mbps 근처가 나와야 한다(과부하로 fq/EDT 상태가 굳지 않음). `TX_DROPS` 증가는 정상이다. 서비스 노드 뒤에서 **포워딩되는** 트래픽으로 하는 원래 D4는 그런 호스트가 있을 때만 한다(13장).

<!-- rh: id=6.5 host=svc mode=measure -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
D=~/vt-l4/d4-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; echo "results: $D"
sudo ./target/release/vantage-5G set --ue-ip "$UE_A" --rx-mbps "$A_RX" --tx-mbps 1
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5203 -u -b 100M -R -t 10 -J" > "$D/a_dl_udp100m.json"
ssh "${SSHO[@]}" -n "$CLIENT_A_USER@$CLIENT_A_HOST" "iperf3 -c $SVC -B $UE_A -p 5203 -R -t 25 -J" > "$D/a_dl_tcp_after.json" &
sleep 5;  vt_snap "$D/stats_t1.txt"
sleep 15; vt_snap "$D/stats_t2.txt"
wait
sudo ./target/release/vantage-5G set --ue-ip "$UE_A" --rx-mbps "$A_RX" --tx-mbps "$A_TX"
cat > "$D/spec.csv" <<EOF
label,ue_ip,direction,cap_mbps,json_path
A-DL-TCP-after-UDP,$UE_A,DL,1,a_dl_tcp_after.json
EOF
python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py "$D/spec.csv" "$D/stats_t1.txt" "$D/stats_t2.txt" | tee "$D/counter_verdict.txt"; vt_ck ${PIPESTATUS[0]} "6.5 TCP DL after a UDP overload runs at the 1 Mbps cap (D4, counter)"
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py "$D/spec.csv" | tee "$D/iperf_verdict.txt"
```
- 기대: `OK`(counter 판정 1 Mbps ±10%: TCP가 연결되어 cap까지 쓴다). iperf goodput 행은 참고값이다(1 Mbps에서는 헤더·ACK 몫이 커서 -5~-15%로 읽힐 수 있다). UE-A의 `TX_DROPS`는 UDP 구간에서 크게 늘어 있는 것이 정상이다. 정책은 블록 중간에 4.1 값으로 돌아간다.
- 실패 시: TCP JSON에 `unable to connect`가 있거나 counter가 0에 가까우면 즉시 보고한다(`$D/stats_t*.txt`, `tc -s qdisc show dev "$IF"`의 fq `dropped`/`flows`). 정책이 1 Mbps로 남았으면 4.1의 A `set`을 다시 넣는다.

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
- 기대: 첫 unload가 `Vantage programs are still attached:`, `<IF>: xdpgeneric prog id … (vantage_rx_poli)`와 `run: sudo …/detach.sh <IF>`로 거부(rc=1)되고 핀은 유지된다. detach 후 `prog/xdp` 없음(generic·native 슬롯 모두), egress 필터·clsact 없음, root는 커널 기본(큐 N≥2면 **`mq 0:`**(handle 0, setup.sh의 `mq 1:`이 아님)에 1.5의 `default_qdisc` 자식, N=1이면 그 default qdisc 하나). 이전에 직접 넣은 custom qdisc는 복원되지 않는다. `OK` 일곱 줄.
- 실패 시: detach rc=4면 남은 목록을 보고 sudo로 다시 실행한다(native 드라이버에서 xdp 잔존은 X2, `setup.sh's root qdisc (mq 1:, per-queue fq) still present`는 root 삭제 실패). unload가 `still attached`를 낸 인터페이스가 `IF`가 아니면 그 인터페이스에도 `sudo ./detach.sh <iface>`. 다른 netns(컨테이너)에 붙은 것은 가드가 보지 못한다(X16). root가 `0:`이 아니면 `7-after-detach.txt`를 보고한다(X18).

## 8. systemd 서비스 (부팅 시 자동 load → apply → setup.sh)
서비스는 `policies.conf`가 기준이다(시작·reload·재부팅마다 `apply --replace` — 파일에 없는 UE의 정책은 지워진다). 정책은 변수 파일 값으로 파일에 쓴다. 재부팅(8.5) 전에 서비스 노드 접속이 `IF`를 거치지 않는지 확인한다.

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
- 기대: `OK` 네 줄. 첫 설치 출력에 `vantage-5G 0.2.0`, `/usr/local/bin/vantage-5G -> /usr/local/lib/vantage-5g/vantage-5G`, `vantage-5g.env created from the example`, `policies.conf created from the example`, `[+] Vantage-5G installed.`, `[!] set IFACE= in /etc/vantage-5g/vantage-5g.env`(8.2에서 설정). 재실행 출력에 `vantage-5g.env exists (kept)`, `policies.conf exists (kept)`.
- 실패 시: rc=2와 `missing in <저장소>: …`이면 3.1. rc=1과 `run as root`이면 sudo. `[!] /usr/local/bin/vantage-5G is a regular file`이면 기록한다(그 파일은 건드리지 않음 — 이후 `sudo vantage-5G` 대신 `sudo /usr/local/lib/vantage-5g/vantage-5G`).

### 8.2 설정과 정책 파일 (변수에서 생성)

<!-- rh: id=8.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo sed -i -e "s/^IFACE=.*/IFACE=$IF/" -e "s/^XDP_MODE=.*/XDP_MODE=$XDP_MODE/" /etc/vantage-5g/vantage-5g.env
sudo tee /etc/vantage-5g/policies.conf > /dev/null <<EOF
# Vantage-5G policies (runbook 8.2): <UE_IPv4> <rx_mbps> <tx_mbps>
$UE_A $A_RX $A_TX
$UE_B $B_RX $B_TX
EOF
grep -vE '^\s*(#|$)' /etc/vantage-5g/vantage-5g.env /etc/vantage-5g/policies.conf | tee ~/vt-l4/8.2-config.txt
grep -qx "IFACE=$IF" /etc/vantage-5g/vantage-5g.env && grep -qx "XDP_MODE=$XDP_MODE" /etc/vantage-5g/vantage-5g.env; vt_ck $? "8.2 env IFACE=$IF XDP_MODE=$XDP_MODE"
grep -qx 'MONITOR_ARGS=--bind 127.0.0.1' /etc/vantage-5g/vantage-5g.env; vt_ck $? "8.2 exporter bound to 127.0.0.1 only (X25)"
```
- 기대: `OK` 두 줄. env에 `IFACE=<IF>`, `XDP_MODE=generic`(또는 3.5에서 고른 native), `IFACE_WAIT_SEC=90`, `MONITOR_ARGS=--bind 127.0.0.1`. policies.conf에 두 줄(형식은 파일 안 주석, README §6.1).
- `/metrics`에는 모든 UE의 IP·정책·카운터가 나오므로 `--bind 127.0.0.1`을 유지한다(`--bind`가 없으면 N6 쪽을 포함한 `0.0.0.0:9090`). 원격 Prometheus는 9.3. `--port`는 1024 이상(monitor 유닛에 `CAP_NET_BIND_SERVICE`가 없어 1024 미만이면 bind 오류로 재시작을 반복하다 failed). `XDP_MODE=`는 비우지 않는다(비우면 preflight status=1, 줄을 지우면 generic). `IFACE_WAIT_SEC`는 최대 240(초과 값은 240으로 줄고 경고).
- 서비스 시작 **뒤에** env를 바꾸면 키별로 재시작할 유닛이 다르다(두 유닛은 서로를 재시작하지 않는다): `IFACE`, `XDP_MODE`, `IFACE_WAIT_SEC` → `sudo systemctl restart vantage-5g`(재attach), `MONITOR_ARGS` → `sudo systemctl restart vantage-5g-monitor`(`restart vantage-5g`로는 bind가 바뀌지 않는다).
- 수동 경로에서 `set`한 정책을 그대로 파일로 저장하려면(이 블록 대신): `sudo vantage-5G export > /tmp/policies.conf && sudo mv /tmp/policies.conf /etc/vantage-5g/policies.conf`(임시 파일 → mv: export 실패 시 빈 파일 방지). export가 `[!] <ip>: … is not a whole Mbps; exported rounded down`을 내면 그 UE를 기록한다.

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
- 실패 시: 서비스는 실패해도 **자동 정리하지 않는다**. `8.3-status.txt`의 `ExecStartPre=…`/`ExecStart=… (code=exited, status=N)` 줄로 단계를 판정한다:
  - `vantage-5g-unit.sh preflight` status=1: env 오류(`IFACE is not set`, `not a valid interface name`, `XDP_MODE is empty`, `XDP_MODE … must be generic or native`) 또는 `policies.conf not found`. status=6: `interface <IF> did not appear within 90s` — `ip link`로 이름을 확인한다.
  - `vantage-5G load` status=1: 3.3의 실패 시(`do not match`이면 부록 B).
  - `vantage-5G apply` status=1: journal에 `line N: …` 오류 목록과 `nothing was changed`(또는 30초 잠금 대기 초과 `still holds /run/vantage-5g.lock`). 아무것도 attach되지 않는다. 파일을 고치고 다시 start한다.
  - `setup.sh` status=2/3/4/5: 3.4의 실패 시. status=3이면 다른 도구의 상태는 그대로이므로 원인을 정리하고 다시 start한다. status=5면 먼저 `sudo /usr/local/lib/vantage-5g/detach.sh "$IF"`.
  - 원인을 고친 뒤 이 블록을 다시 붙인다. 출력 전체(status, journal)를 기록한다.

### 8.4 reload (정책 파일 변경)
UE-B의 tx를 1 올려 reload하고(재attach 없음 확인), 원래 값으로 되돌려 한 번 더 reload한다.

<!-- rh: id=8.4 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*' > ~/vt-l4/8.4-xdp-before.txt
sudo tee /etc/vantage-5g/policies.conf > /dev/null <<EOF
# Vantage-5G policies (runbook 8.4: UE_B tx + 1)
$UE_A $A_RX $A_TX
$UE_B $B_RX $((B_TX + 1))
EOF
sudo systemctl reload vantage-5g; vt_ck $? "8.4 reload"
sudo journalctl -u vantage-5g --no-pager -n 6 | tee ~/vt-l4/8.4-reload.txt | grep 'applied'
grep -q 'added 0, changed 1, unchanged 1, removed 0' ~/vt-l4/8.4-reload.txt; vt_ck $? "8.4 one policy changed"
ip -d link show dev "$IF" | grep -o 'prog/xdp[a-z]* id [0-9]*' | diff - ~/vt-l4/8.4-xdp-before.txt; vt_ck $? "8.4 same XDP program (no re-attach)"
sudo tee /etc/vantage-5g/policies.conf > /dev/null <<EOF
# Vantage-5G policies (runbook 8.2): <UE_IPv4> <rx_mbps> <tx_mbps>
$UE_A $A_RX $A_TX
$UE_B $B_RX $B_TX
EOF
sudo systemctl reload vantage-5g; vt_ck $? "8.4 reload back to the 8.2 values"
```
- 기대: `[+] applied /etc/vantage-5g/policies.conf (--replace): added 0, changed 1, unchanged 1, removed 0`, `OK` 네 줄. 바뀌지 않은 UE는 RX/TX 상태가 유지된다.
- 정책이 하나도 없는(빈·잘린) 파일로 reload하면 rc≠0, journal에 `has no policies; --replace would remove all N current policies (pass --allow-empty …)`, 정책은 그대로이고 유닛은 active다. 정말 모두 지우려면 `sudo vantage-5G apply -f /etc/vantage-5g/policies.conf --replace --allow-empty`.
- 실패 시: 파일 오류면 rc≠0이고 journal에 줄 번호 목록이 나오며 정책은 그대로다(동작 중인 셰이핑 영향 없음). 파일을 고치고 다시 reload한다. CLI로만 `set`한 UE가 `removed`로 나오면 정상이다(파일이 기준).

### 8.5 재부팅
`IF`를 거치지 않는 경로로 접속해 있는지 확인한 뒤 실행한다. 접속이 끊긴다.

<!-- rh: id=8.5 host=svc mode=reboot -->
**[서비스 노드]**
```bash
sudo systemctl reboot
```

### 8.6 재접속 후 확인 (X22, 귀환 경로 영구화)
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
for u in "$UE_A" "$UE_B"; do ip route get "$u" | head -1; vt_route_ok "$u"; vt_ck $? "8.6 route to $u after reboot is dev $IF${UE_GW:+ via $UE_GW}"; done
for x in A B; do if [ $x = A ]; then u=$UE_A; h="$CLIENT_A_USER@$CLIENT_A_HOST"; else u=$UE_B; h="$CLIENT_B_USER@$CLIENT_B_HOST"; fi; ssh "${SSHO[@]}" -n "$h" "ping -c 2 -W 2 -I $u $SVC" > /dev/null; vt_ck $? "8.6 $u <-> $SVC after reboot"; done
```
- 기대: `running`(또는 `degraded` — 다른 유닛 문제, 기록), `OK` 여덟 줄. journal 순서는 8.3과 같다(NIC가 늦게 뜨면 `waiting up to 90s for interface …`와 `appeared after ~Ns`가 앞에 나온다). 9090은 `127.0.0.1:9090`만. (나)에서 경로가 `via <UE_GW>`로 남아 있다(2.6의 netplan drop-in).
- 실패 시: preflight status=6(`did not appear within …s`)이면 NIC가 늦게 올라온 것이다 — `sudo journalctl -b | grep -iE "$IF|link"`로 NIC가 나타난 시각을 기록하고 `/etc/vantage-5g/vantage-5g.env`의 `IFACE_WAIT_SEC`를 늘린다(최대 240). 장치가 생길 때까지 시작을 미루려면 `sudo systemctl edit vantage-5g`로 `[Unit]`에 `BindsTo=sys-subsystem-net-devices-<IF>.device`와 `After=sys-subsystem-net-devices-<IF>.device`를 넣는 방법도 있다(로컬 미검증). 서비스가 `inactive`이고 `systemctl is-enabled vantage-5g`가 `disabled`이면 `sudo systemctl enable vantage-5g vantage-5g-monitor`. 정책이 다르면 `8.6-export.txt`와 policies.conf를 함께 보고한다. 경로가 사라졌으면 2.6(netplan)을 다시 본다 — `2.6-netplan.txt`와 `ip route show` 출력을 보고한다.

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
- 기대: `OK` 아홉 줄. monitor 유닛은 `After=vantage-5g.service`만 두고 의존 관계가 없어 main의 stop/restart에 끌려가지 않는다(핀이 없는 동안 scrape 오류 1회, UE 시리즈 없음, restart 후 새 맵을 다시 읽음). restart = detach → unload → load → apply → setup(짧은 셰이핑 공백). monitor까지 멈추려면 `sudo systemctl stop vantage-5g-monitor vantage-5g`.
- 점검 중 monitor만 재시작해도 load·attach가 일어나지 않는다(선택 확인: `sudo systemctl stop vantage-5g; sudo systemctl restart vantage-5g-monitor; ls /sys/fs/bpf/vantage; sudo systemctl start vantage-5g` → `No such file or directory`).
- 실패 시: **stop은 정리에 실패해도 rc=0이다.** `is-failed`가 `failed`이면 `sudo journalctl -u vantage-5g -n 20`의 `Vantage programs are still attached:` 목록에 `sudo /usr/local/lib/vantage-5g/detach.sh <iface>` → `sudo vantage-5G unload` → `sudo systemctl reset-failed vantage-5g`. 그 전까지 핀은 유지되고 CLI로 정책을 계속 바꿀 수 있다.

### 8.8 서비스 업그레이드 (새 커밋 설치)
나중에 새 커밋을 올릴 때의 절차다. 0.2의 `COMMIT`을 새 해시로 바꾼 뒤 붙인다(같은 커밋이면 재설치·재시작만 된다). 맵 정의가 바뀐 업그레이드도 `restart vantage-5g`(detach → unload → load)로 끝난다.

<!-- rh: id=8.8 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo vantage-5G export > ~/vt-l4/8.8-export.txt; diff <(grep -vE '^\s*(#|$)' ~/vt-l4/8.8-export.txt | awk '{print $1, $2, $3}' | sort) <(grep -vE '^\s*(#|$)' /etc/vantage-5g/policies.conf | awk '{print $1, $2, $3}' | sort); vt_ck $? "8.8 policies.conf matches the running policies (nothing CLI-only to lose)"
git fetch -q origin && git checkout -q "$COMMIT" && make build 2>&1 | tail -1; git log -1 --oneline
P0=$(systemctl show -p MainPID --value vantage-5g-monitor)
sudo ./install.sh install > ~/vt-l4/8.8-install.txt 2>&1; vt_ck $? "8.8 install over the running service"
grep -A4 'still use the previous version' ~/vt-l4/8.8-install.txt
sudo systemctl restart vantage-5g; vt_ck $? "8.8 restart vantage-5g (new .o / binary, re-attach)"
sudo systemctl restart vantage-5g-monitor; vt_ck $? "8.8 restart vantage-5g-monitor"
[ "$(systemctl show -p MainPID --value vantage-5g-monitor)" != "$P0" ]; vt_ck $? "8.8 monitor restarted (new PID)"
sudo journalctl -u vantage-5g -n 30 --no-pager | grep -q 'applied /etc/vantage-5g/policies.conf (--replace)'; vt_ck $? "8.8 policies re-applied"
```
- 기대: `OK` 여섯 줄. install 출력 끝에 `The running units still use the previous version; to switch:`와 두 유닛의 restart 안내. 두 유닛은 따로 재시작한다(`restart vantage-5g`만 하면 monitor는 옛 바이너리로 계속 돈다).
- 실패 시: 첫 줄이 FAIL이면 CLI로만 바꾼 정책이 있다 — 남길 것이면 8.2의 export 방법으로 파일에 저장한 뒤 다시 붙인다. restart 후 `failed`면 8.3의 실패 시 표로 단계를 판정한다.

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

### 9.2 클라이언트 A(UE 경로): 9090이 보이지 않음

<!-- rh: id=9.2 host=a -->
**[클라이언트 A]**
```bash
source ~/vt-l4/vars.sh
code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' --interface "$UE_A" "http://$SVC:9090/metrics"); echo "http_code=$code"; [ "$code" = 000 ]; vt_ck $? "9.2 client A: $SVC:9090 not reachable from $UE_A"
```
- 기대: 9.1 `OK`, 정책 메트릭 4줄(UE 2개 × rx/tx). 9.2 `http_code=000`, `OK`.
- 실패 시: 9.2에서 `200`이면 `MONITOR_ARGS`에 `--bind`가 없거나 `IF` 주소로 bind된 것이다 — 8.2를 다시 붙이고 `sudo systemctl restart vantage-5g-monitor`. 수동으로 `vantage-5G monitor`를 띄운 경우 기본값이 `0.0.0.0`이므로 `--bind`를 붙여 다시 띄운다.

### 9.3 원격 scrape: 관리망 bind + 방화벽 (선택, `MGMT_IP`를 채웠을 때만)
원격 Prometheus가 필요할 때만. 0.2에서 `MGMT_IP`(서비스 노드의 관리망 주소, `IF` 쪽이 아님)와 `PROM_IP`(Prometheus 호스트)를 채운다. 비어 있으면 아무것도 하지 않는다.

<!-- rh: id=9.3 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
if [ -z "$MGMT_IP" ]; then echo "[i] MGMT_IP empty: exporter stays on 127.0.0.1 (9.3 skipped)"; else
  sudo sed -i "s/^MONITOR_ARGS=.*/MONITOR_ARGS=--bind $MGMT_IP --port 9090/" /etc/vantage-5g/vantage-5g.env
  sudo systemctl restart vantage-5g-monitor; sleep 2
  ss -ltn | grep ':9090 ' | tee ~/vt-l4/9.3-ss.txt; grep -q "$MGMT_IP:9090 " ~/vt-l4/9.3-ss.txt; vt_ck $? "9.3 exporter on $MGMT_IP:9090"
  if sudo ufw status | grep -q 'Status: active'; then sudo ufw allow from "$PROM_IP" to "$MGMT_IP" port 9090 proto tcp; else sudo iptables -C INPUT -p tcp --dport 9090 ! -s "$PROM_IP" -j DROP 2>/dev/null || sudo iptables -A INPUT -p tcp --dport 9090 ! -s "$PROM_IP" -j DROP; fi
fi
```
- 기대: `OK   9.3 exporter on <MGMT_IP>:9090`. Prometheus 호스트에서 `curl -m3 -s http://<MGMT_IP>:9090/metrics | grep -c '^vantage_'` > 0, 클라이언트·UPF 쪽에서는 실패. ufw가 inactive이면 이 목적만으로 `ufw enable`을 하지 않는다(기본 정책이 SSH와 iperf3 5201~5204를 막는다) — 블록은 그때 iptables로 9090만 막는다(영구화는 부록 A.4 (B)와 같은 방법).
- 실패 시: `ss`가 바뀌지 않았으면 `restart vantage-5g`를 한 것이다 — monitor를 재시작한다. monitor가 `failed`면 `sudo journalctl -u vantage-5g-monitor -n 20`에서 bind 오류(주소가 이 호스트에 없음, 포트 사용 중)를 본다.

### 9.4 Grafana 대시보드 (선택)
대시보드는 로컬에서 Grafana 11.2.0 / Prometheus 2.54.1로 provisioning과 모든 패널 쿼리가 오류 없이 도는 것까지 확인했다. **Grafana UI 렌더링은 확인하지 않았고 여기서 확인한다(X24).** `schemaVersion` 39라 Grafana 10.4 이상이면 로드될 것으로 예상한다(미검증).
- 설정: Prometheus에 `job_name: vantage-5g`, `targets: ["<MGMT_IP>:9090"]`(서비스 노드 자체면 `127.0.0.1:9090`), 측정 중 `scrape_interval: 1s`. Grafana에서 Dashboards → Import → `dashboards/vantage-5g.json`, *Prometheus* 드롭다운에서 데이터 소스 선택. Grafana·Prometheus 버전을 기록한다. 상세는 [`dashboards/README.md`](../dashboards/README.md).
- 기대: Targets에서 `vantage-5g`가 UP. *Exporter* 변수에 서비스 노드, *UE* 변수에 policies.conf의 UE. *UEs with a policy* = 정책 수, *Exporter scrape* = 1. 정책 표는 UE마다 한 행이고 exporter 열이 있다.
- 판독(5.2를 대시보드를 보며 다시 붙인다, rate window 15s): *DL/UL throughput vs cap*의 UE별 선이 cap 점선 근처, *realized / cap (%)*가 90~110% 안이고 5.2 counter 판정 err%와 몇 % 안에서 맞는다. killswitch(6.1) 중 정책 표 TX cap이 `KILLSWITCH`, *Killswitch UEs* = 1, *DL drops/s* 증가. `sudo vantage-5G reset --ue-ip "$UE_B"` 후 *UEs with counters but no policy* = 1(확인 후 다시 `set`). unload 후 vantage 시리즈가 모두 사라지고 *Exporter scrape*는 1. 화면을 `~/vt-l4/9.4-*.png`로 남긴다.
- 실패 시: *Exporter scrape*가 No data면 `job_name`이 `vantage-5g`가 아니다(패널 쿼리가 `up{job="vantage-5g"}`). 처리량 패널이 비면 rate window를 scrape 간격의 3배 이상으로. 화면 이상(표 열 순서, `KILLSWITCH`/`uncapped` 표시, ±10% 선)은 스크린샷과 함께 보고한다.

## 10. 제거 (서버에서 뺄 때만)
계속 운영할 것이면 10장은 건너뛰고 11장으로 간다.

### 10.1 uninstall

<!-- rh: id=10.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./install.sh uninstall 2>&1 | tee ~/vt-l4/10-uninstall.txt; vt_ck ${PIPESTATUS[0]} "10.1 uninstall"
[ -z "$(systemctl list-unit-files 'vantage-5g*' --no-legend)" ]; vt_ck $? "10.1 unit files removed"
test -e /usr/local/lib/vantage-5g || test -e /usr/local/bin/vantage-5G; [ $? = 1 ]; vt_ck $? "10.1 /usr/local files removed"
test -d /etc/vantage-5g; vt_ck $? "10.1 /etc/vantage-5g kept by plain uninstall"
sudo ./install.sh uninstall --purge > ~/vt-l4/10-purge.txt 2>&1; vt_ck $? "10.1 uninstall --purge"
test -e /etc/vantage-5g; [ $? = 1 ]; vt_ck $? "10.1 /etc/vantage-5g removed by --purge"
sudo test -e /sys/fs/bpf/vantage; [ $? = 1 ]; vt_ck $? "10.1 no pins left"
ip -d link show dev "$IF" | grep -q 'prog/xdp'; [ $? = 1 ]; vt_ck $? "10.1 no XDP left on $IF"
[ -z "$(tc qdisc show dev "$IF" | grep -E 'clsact|root' | grep -v ' 0: root')" ]; vt_ck $? "10.1 kernel default root qdisc, no clsact"
pkill -x iperf3; tc qdisc show dev "$IF" | tee ~/vt-l4/10-qdisc.txt
```
- 기대: `[+] Vantage-5G uninstalled.`(`removed /usr/local/lib/vantage-5g; kept /etc/vantage-5g`), `OK` 아홉 줄. `/run/vantage-5g.lock`(CLI의 쓰기 잠금 파일, tmpfs)은 남아도 정상이다(재부팅 때 사라진다).
- 실패 시: rc=4와 `did not stop cleanly`이면 아무것도 지워지지 않았다 — 출력된 대로 `sudo /usr/local/lib/vantage-5g/detach.sh <iface>` 후 이 블록을 다시 붙인다. rc=5면 파일은 지워졌지만 핀이 남았다(앞서 `--force`를 쓴 경우): `sudo ./detach.sh "$IF"; sudo ./target/release/vantage-5G unload`.

### 10.2 네트워크 설정 되돌리기 (이 서버가 더 이상 UE를 서비스하지 않을 때만)
2.6의 netplan drop-in과 UE 경로, 9.3의 9090 차단 규칙을 지운다. 해당 없는 항목은 건너뛴다.

<!-- rh: id=10.2 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh
sudo -v
if [ -n "$UE_GW" ]; then sudo rm -f /etc/netplan/90-vantage-ue-route.yaml; sudo netplan generate; sudo ip route del "$UE_NET" via "$UE_GW" dev "$IF" 2>/dev/null; ip route show "$UE_NET" | grep -q .; [ $? = 1 ]; vt_ck $? "10.2 route $UE_NET removed (runtime and netplan)"; else echo "[i] UE_GW empty: no route to remove"; fi
if [ -n "$PROM_IP" ]; then sudo iptables -D INPUT -p tcp --dport 9090 ! -s "$PROM_IP" -j DROP 2>/dev/null; echo "[i] 9090 DROP rule removed (if it was there)"; fi
```
- 기대: (나) `OK   10.2 route … removed`. (가) `[i] UE_GW empty …`.

## 11. 결과 수집

### 11.1 서비스 노드로 모으고 묶기
클라이언트의 `~/vt-l4/`를 SSH로 가져와 `~/vt-l4/client-a`, `client-b`에 넣고(같은 호스트면 같은 내용) 전체를 tar로 묶는다. 마지막에 개발 PC에서 붙일 `scp` 명령을 출력한다.

<!-- rh: id=11.1 host=svc -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
{ git log -1 --oneline; uname -r; lsb_release -ds; date -Is; } > ~/vt-l4/11-meta.txt
rm -rf ~/vt-l4/client-a ~/vt-l4/client-b
scp "${SSHO[@]}" -q -r "$CLIENT_A_USER@$CLIENT_A_HOST:vt-l4" ~/vt-l4/client-a < /dev/null; vt_ck $? "11.1 collected client A"
scp "${SSHO[@]}" -q -r "$CLIENT_B_USER@$CLIENT_B_HOST:vt-l4" ~/vt-l4/client-b < /dev/null; vt_ck $? "11.1 collected client B"
T=~/vt-l4-$(hostname)-$(date +%Y%m%d-%H%M).tgz; tar czf "$T" -C ~ vt-l4; vt_ck $? "11.1 archive $T"
for ip in $(hostname -I); do case "$ip" in *:*) ;; *) echo "scp $(id -un)@$ip:$(basename "$T") ." ;; esac; done
```
- 기대: `OK` 세 줄. 마지막 줄들이 개발 PC에서 붙일 명령이다(서비스 노드의 주소마다 한 줄 — PC에서 닿는 주소의 줄을 쓴다).
- 가져올 것: 이 tar 하나(서비스 노드와 클라이언트의 단계별 출력, `m4-*`·`mq-*`·`kfq-*`·`d4-*` 측정 디렉토리, 8장 journal, `nproc`, 맵 정보, `ethtool -i`/`-l`, 커밋 해시, `uname -r`). (나)라면 코어 담당에게 받은 부록 A 출력(`~/vt-l4/A.*` on UPF 호스트)도 함께 받는다. 9.3·9.4를 했다면 그 출력과 스크린샷, Grafana·Prometheus 버전.

### 11.2 SSH 키 정리 (선택)
측정을 다시 할 계획이 없으면 클라이언트에서 서비스 노드 키를 지우고, 서비스 노드에서 키를 지운다.

<!-- rh: id=11.2-a host=a -->
**[클라이언트 A]**
```bash
sed -i '/vantage-vt-l4/d' ~/.ssh/authorized_keys; grep -c vantage-vt-l4 ~/.ssh/authorized_keys
```

<!-- rh: id=11.2-b host=b -->
**[클라이언트 B]**
```bash
sed -i '/vantage-vt-l4/d' ~/.ssh/authorized_keys; grep -c vantage-vt-l4 ~/.ssh/authorized_keys
```

<!-- rh: id=11.2-svc host=svc -->
**[서비스 노드]**
```bash
rm -f ~/.ssh/vt_l4 ~/.ssh/vt_l4.pub; ls ~/.ssh
```
- 기대: 클라이언트에서 `0`. 서비스 노드 `~/.ssh`에 `vt_l4`가 없다.

## 12. 판정 다시 하기
tar를 푼 디렉토리 또는 서비스 노드에서, 저장소(`~/vantage-5G`)의 판정 스크립트로 모든 측정 디렉토리를 다시 판정한다. 개발 PC에서는 `R=~/vt-l4` 대신 tar를 푼 `vt-l4` 경로를 쓴다.

<!-- rh: id=12 host=svc -->
**[서비스 노드]**
```bash
cd ~/vantage-5G; R=~/vt-l4
for d in "$R"/m4-* "$R"/mq-* "$R"/kfq-* "$R"/d4-*; do [ -f "$d/spec.csv" ] || continue; echo "=== $d"; python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py "$d/spec.csv"; if [ -f "$d/stats_t2.txt" ]; then python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py "$d/spec.csv" "$d/stats_t1.txt" "$d/stats_t2.txt"; fi; done
```
- 해석: README §8.5. counter 판정(L2 바이트, ACK 포함)이 cap 기준이고, iperf goodput은 헤더·반대 방향 ACK만큼 낮게 읽힌다. `kfq-*`는 iperf 판정만 있다(5.4 참고값).

## 13. 체크리스트 (L4에서만 확인되는 항목)

환경: (가) 코어 없음, (나) 5G 코어, 공통 = 둘 다.

| # | 항목 | 환경 | 확인 위치 |
|---|---|---|---|
| X1 | 새 clone의 스크립트 실행 권한 | 공통 | 1.4 |
| X2 | native XDP 지원 드라이버(ixgbe/i40e/mlx5 등)에서 detach 후 xdp 잔존 없음 | 공통 | 3.5 → 7, 10.1 |
| X5 | UE 주소가 NAT 없이 `IF`에 보임, 귀환 경로 | (나) (가는 2.4·2.5가 자명하게 통과) | 2.4, 2.5, 부록 A |
| X7 | 멀티큐 NIC: 커널 기본 `mq 0:` → `mq 1:` + 큐별 fq(첫 실행), 재실행 시 qdisc 무변경, 전환 순간 손실·링크 리셋, `default_qdisc` 원복 | 공통 | 3.4 |
| X8 | native XDP: 지원 시 rc=0과 `xdp` 표시, 미지원 시 rc=3·generic 복원, 링크 플랩 시간. 남의 native XDP가 있으면 rc=3 | 공통 | 3.5 |
| X12 | 22.04/24.04 설치 명령, `bpftool version` | 공통 | 1.2 |
| X13 | LRU 조기 퇴출 — 조건은 UE 수가 아니라 CPU 수(nproc > 128 & 커널 < 6.16). 활성 UE 카운터가 0으로 돌아가는지 | 공통 | 1.1, 5.3, 장기 운영 |
| X14 | RSS 멀티큐 UL `-P 8` 과다 허용 | 공통 | 5.5 |
| X15 | BIG TCP 비활성(gro_max_size ≤ 65536), native XDP에서 rx_packets 의미 | 공통 | 1.5, 5.3 |
| X16 | 다른 netns(컨테이너 등)에 attach된 경우 unload 가드 미검출 | 해당 시 | 7 |
| X18 | detach 후 커널 기본 root 복원: 멀티큐 `mq 0:` + default_qdisc 자식, 단일 큐 default_qdisc | 공통 | 7, 10.1 |
| X19 | `ethtool -L`로 채널을 늘린 뒤 **재실행 없이** 새 큐가 fq인지, 줄인 뒤 재실행 시 숨은 클래스를 다시 graft하는지(≥5.16), numtxqueues ≫ 사용 큐(예: mlx5 64+)에서 최초 setup 소요 시간·손실 (선택: 3.4 뒤 `sudo ethtool -L "$IF" combined <n>` → `tc qdisc show dev "$IF"`) | 공통 | 3.4 |
| X20 | 큐가 여러 개(수십 개)인 NIC에서 큐별 fq의 EDT: DL counter 판정, `-P 4` DL에서 UE 합계 cap | 공통 | 5.2, 5.5 |
| X21 | `sch_fq`가 builtin인 커널에서 모듈 검사 통과(rc=0) | 공통 | 3.4 |
| X22 | systemd: 실제 NIC(드라이버 로드 시간, bond/VLAN, netplan)에서 부팅 시 `IFACE`가 제때 있는지, 재부팅 후 attach·정책·UE 경로 복원 | 공통 | 8.6 |
| X23 | systemd + native XDP(`XDP_MODE=native`)의 부팅·restart 링크 리셋 | 공통(3.5가 rc=0일 때) | 8.6, 8.7 |
| X24 | Grafana UI 렌더링: 정책 표(merge/organize, exporter 열), 값 매핑(`KILLSWITCH`/`uncapped`), ±10% 선, `$__rate_interval` | 공통 | 9.4 |
| X25 | exporter 노출: UE 쪽에서 9090 불가, 관리망 bind + 방화벽으로 원격 scrape | 공통 | 9.1~9.3 |
| X26 | 실제 다중 노드: Vantage 노드 2대 이상(또는 UPF 2대가 같은 UE 풀을 쓰는 경우)을 한 Prometheus로 수집 — 정책 표의 exporter 열, *Exporter scrape* = `min(up{job="vantage-5g"})` | 해당 시(노드 2대 이상) | 9.4 |
| X27 | 24.04의 B-UL(3 Mbps, 4세션) 미달(로컬 VM에서 미분류) | 공통(24.04) | 5.2 |
| V20 | 맵 메모리(LRU 3개 memlock 합계, 커널별 표시 차이) | 공통 | 3.3 |
| D4 | 서비스 노드 뒤(포워딩되는 쪽) 호스트에서 UE로 UDP 과부하 후 TCP DL — 그런 호스트가 있을 때. 없으면 6.5의 변형만 | 해당 시 | 6.5 |
| — | 실제 클라이언트의 바인딩: 노트북 유선·Wi-Fi 공존, UERANSIM `uesimtun` 출발지 라우팅(아니면 `nr-binder`) | (가)/(나) | 2.2 |
| — | 물리 스위치(가), 실 코어 경로의 무선 구간 용량(나) | (가)/(나) | 5.2 |

---

## 부록 A. 코어(UPF) 파트에 전달할 요구사항

Vantage가 코어에 요구하는 것은 **결과 세 가지**뿐이다. 코어가 블랙박스라면 설정 방법은 코어 담당이 정하고, 서비스 노드는 본문 2.4·2.5·2.7로 결과만 확인하면 된다.

1. **UE → 서비스 노드 트래픽은 NAT하지 않는다.** 서비스 노드 `IF`에 출발지가 UE 주소(`UE_NET` 안) 그대로 도착해야 한다(정책 키). 인터넷으로 나가는 UE 트래픽의 NAT는 그대로 둬도 된다 — 목적지가 서비스 노드(`SVC`)인 것만 예외.
2. **UPF 호스트는 UE ↔ 서비스 노드 패킷을 포워딩한다**(`ip_forward`, 방화벽 FORWARD 허용).
3. **UPF 호스트에서 서비스 노드로 가는 경로가 N6 쪽이다**(서비스 노드의 `UE_GW`가 UPF 호스트의 N6 주소).

아래는 **Open5GS 레퍼런스 설치(quickstart의 MASQUERADE)를 기준으로 한 예시 명령**이다. 다른 코어나 다른 NAT 구성이면 같은 결과를 내는 방법으로 바꾼다. 블록은 UPF 호스트에서 실행하고, 변수 파일은 서비스 노드와 같은 `SVC`, `UE_NET`을 쓴다.

### A.0 UPF 호스트 변수 파일

<!-- rh: id=A.0-1 host=upf -->
**[UPF 호스트]**
```bash
mkdir -p ~/vt-l4 && cd ~/vt-l4
if [ -e vars.sh ]; then echo "[i] ~/vt-l4/vars.sh already exists (not overwritten)"; else cat > vars.sh <<'EOF'
# ~/vt-l4/vars.sh -- Vantage-5G install runbook variables (docs/install-runbook.md, appendix A)
# Replace the values once, on this host:  nano ~/vt-l4/vars.sh
ROLE=upf              # this host: svc | client | upf  (pre-filled by the block)
SVC=CHANGE_ME         # service node IP (the N6 address UEs send to), e.g. 10.200.0.2
UE_NET=CHANGE_ME      # UE pool CIDR, e.g. 10.45.0.0/16
# --- do not edit below ---
vt_ck() { if [ "$1" = 0 ]; then echo "OK   $2"; else echo "FAIL $2"; fi; }
if grep -qE '^(SVC|UE_NET)=CHANGE_ME' "$HOME/vt-l4/vars.sh"; then echo "[!] CHANGE_ME left in ~/vt-l4/vars.sh (runbook A.0)"; fi
true
EOF
echo "[+] created ~/vt-l4/vars.sh"; fi
```

<!-- rh: id=A.0-2 host=upf mode=edit -->
**[UPF 호스트]**
```bash
nano ~/vt-l4/vars.sh
```

<!-- rh: id=A.0-3 host=upf -->
**[UPF 호스트]**
```bash
( source ~/vt-l4/vars.sh; bad=0
  echo "$SVC" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "FAIL vars: SVC=$SVC is not an IPv4 address"; bad=1; }
  echo "$UE_NET" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' || { echo "FAIL vars: UE_NET=$UE_NET is not a CIDR"; bad=1; }
  ip route get "$SVC" > /dev/null 2>&1 || { echo "FAIL vars: no route to SVC=$SVC on this host"; bad=1; }
  if [ $bad = 0 ]; then echo "OK   vars: SVC=$SVC via $(ip route get "$SVC" | head -1) UE_NET=$UE_NET"; else echo "FAIL vars: edit ~/vt-l4/vars.sh and paste this block again"; fi )
```
- 기대: `OK   vars: SVC=… via <SVC> dev <N6 NIC> … UE_NET=…`. `dev`가 N6 NIC가 아니면 요구사항 3(경로)부터 맞춘다.

### A.1 현재 상태 기록

<!-- rh: id=A.1 host=upf -->
**[UPF 호스트]**
```bash
source ~/vt-l4/vars.sh
sudo -v
{ sudo iptables -t nat -S POSTROUTING; sysctl net.ipv4.ip_forward; sudo iptables -S FORWARD | head -1; ip route get "$SVC"; sudo ufw status 2>/dev/null | head -1; } 2>&1 | tee ~/vt-l4/A.1-before.txt
```
- 기대: quickstart 그대로면 `-A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE` — 이 규칙이 UE→서비스 노드 트래픽도 UPF 주소로 바꾼다(본문 2.4가 FAIL하는 원인).
- 실패 시: 규칙이 `iptables`에 안 보이면 `sudo nft list ruleset | grep -n -B3 masquerade`로 nftables 쪽을 확인하고 같은 의미의 예외를 넣는다.

### A.2 NAT 예외 (요구사항 1)
nat 테이블은 첫 종단 규칙에서 멈추므로, MASQUERADE보다 **위에** `UE_NET → SVC` `ACCEPT`(= 주소 변환 안 함)를 넣는다(방법 A). 이미 NAT된 연결은 conntrack 항목이 남아(established TCP는 며칠) 계속 UPF 주소로 보이므로 지운다.

<!-- rh: id=A.2 host=upf -->
**[UPF 호스트]**
```bash
source ~/vt-l4/vars.sh
sudo -v
sudo iptables -t nat -C POSTROUTING -s "$UE_NET" -d "$SVC" -j ACCEPT 2>/dev/null || sudo iptables -t nat -I POSTROUTING 1 -s "$UE_NET" -d "$SVC" -j ACCEPT
sudo iptables -t nat -L POSTROUTING -n --line-numbers | tee ~/vt-l4/A.2-nat.txt
awk -v s="$SVC" '$2 == "ACCEPT" && $6 == s && a == "" {a = $1} $2 == "MASQUERADE" && m == "" {m = $1} END {exit (a != "" && (m == "" || a + 0 < m + 0)) ? 0 : 1}' ~/vt-l4/A.2-nat.txt; vt_ck $? "A.2 UE_NET -> SVC exception is above MASQUERADE"
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q conntrack 2>&1 | tail -1
sudo conntrack -D -s "$UE_NET" -d "$SVC" 2>&1 | tail -1
```
- 기대: `ACCEPT … <UE_NET> <SVC>` 줄이 `MASQUERADE` 줄보다 위(번호가 작음), `OK`. conntrack은 지울 항목이 없으면 `0 flow entries have been deleted`(정상).
- 방법 B(대안, A 대신): MASQUERADE 규칙 자체에 서비스 노드 제외 조건을 넣는다.
  ```
  sudo iptables -t nat -D POSTROUTING -s "$UE_NET" ! -o ogstun -j MASQUERADE
  sudo iptables -t nat -A POSTROUTING -s "$UE_NET" ! -d "$SVC" ! -o ogstun -j MASQUERADE
  ```
- 실패 시: 예외가 MASQUERADE보다 아래면 `sudo iptables -t nat -D POSTROUTING -s "$UE_NET" -d "$SVC" -j ACCEPT` 후 이 블록을 다시 붙인다. 코어를 직접 바꿀 수 없으면 이 부록을 코어 관리자에게 전달하고 본문 2.4까지 진행하지 않는다.

### A.3 포워딩과 경로 (요구사항 2, 3)

<!-- rh: id=A.3 host=upf -->
**[UPF 호스트]**
```bash
source ~/vt-l4/vars.sh
sudo -v
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-ue-forward.conf > /dev/null && sudo sysctl --system > /dev/null
[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]; vt_ck $? "A.3 net.ipv4.ip_forward=1 (persistent via /etc/sysctl.d)"
if sudo iptables -S FORWARD | head -1 | grep -q DROP; then
  sudo iptables -C FORWARD -s "$UE_NET" -d "$SVC" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s "$UE_NET" -d "$SVC" -j ACCEPT
  sudo iptables -C FORWARD -s "$SVC" -d "$UE_NET" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s "$SVC" -d "$UE_NET" -j ACCEPT
  echo "[+] FORWARD policy is DROP: accepted UE_NET <-> SVC"; fi
sudo iptables -S FORWARD | tee ~/vt-l4/A.3-forward.txt | head -3
ip route get "$SVC" | tee ~/vt-l4/A.3-route.txt
```
- 기대: `OK`. FORWARD 정책이 `-P FORWARD ACCEPT`이거나(Docker가 없는 기본), `DROP`이면 두 ACCEPT 규칙이 들어간다. `ip route get "$SVC"`가 N6 NIC로 나간다.
- 실패 시: `SVC`로 가는 경로가 N6 NIC가 아니면 UPF 호스트에 서비스 노드 대역 경로를 추가한다.

### A.4 A.2·A.3 규칙 영구화
`sysctl.d` 파일은 이미 영구적이다. iptables 규칙은 재부팅하면 사라지므로 A.2와 A.3을 **모두** 마친 뒤 한 번 저장한다.
- **ufw가 active이면 (A)** — `iptables-persistent`를 설치하지 않는다. **Ubuntu 24.04에서 `apt-get install iptables-persistent`는 ufw를 묻지 않고 제거한다**(ufw 0.36.2의 `Breaks: iptables-persistent, netfilter-persistent`. 22.04의 ufw 0.36.1에는 이 충돌이 없다). 대신 `/etc/ufw/before.rules` 맨 위(`*filter` 줄 앞)에 아래 `*nat` 블록을 넣고(이미 `*nat` 블록이 있으면 그 안의 MASQUERADE 줄 위에 ACCEPT 줄만 추가; `<UE_NET>`, `<SVC>`는 변수 값으로 바꿔 쓴다), `sudo ufw route allow from <UE_NET> to <SVC>`, `sudo ufw route allow from <SVC> to <UE_NET>`, `sudo ufw reload` 후 `sudo iptables -t nat -L POSTROUTING -n --line-numbers`로 ACCEPT가 MASQUERADE 위인지 본다. 이 경로는 사람이 파일을 편집하므로 블록으로 만들지 않았다(로컬 미검증).
  ```
  *nat
  :POSTROUTING ACCEPT [0:0]
  -A POSTROUTING -s <UE_NET> -d <SVC> -j ACCEPT
  -A POSTROUTING -s <UE_NET> ! -o ogstun -j MASQUERADE
  COMMIT
  ```
- **ufw를 쓰지 않으면 (B)** — 아래 블록. ufw가 active이면 블록이 설치하지 않고 멈춘다. 제거 대상에 ufw가 있으면(ufw가 inactive여도 설치돼 있으면 24.04에서 제거됨) 역시 멈춘다 — ufw가 필요 없을 때만 그것을 지우고 다시 붙인다.

<!-- rh: id=A.4 host=upf -->
**[UPF 호스트]**
```bash
source ~/vt-l4/vars.sh
sudo -v
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then echo "FAIL A.4 ufw is active: do not install iptables-persistent; use the ufw before.rules route (A)"; else
  sudo apt-get -s install iptables-persistent 2>/dev/null | grep -A3 REMOVED | tee ~/vt-l4/A.4-apt-dryrun.txt
  if grep -q ufw ~/vt-l4/A.4-apt-dryrun.txt; then echo "FAIL A.4 installing iptables-persistent would remove ufw: use the ufw route (A), or remove ufw first if it is not needed"; else
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q iptables-persistent 2>&1 | tail -1
    sudo netfilter-persistent save 2>&1 | tail -2
    sudo grep -E 'ACCEPT|MASQUERADE' /etc/iptables/rules.v4 | tee ~/vt-l4/A.4-rules.txt
    grep -qF -e "-s $UE_NET -d $SVC/32 -j ACCEPT" ~/vt-l4/A.4-rules.txt; vt_ck $? "A.4 NAT exception saved in /etc/iptables/rules.v4"
  fi
fi
```
- 기대: dry run 출력이 비어 있고(제거 대상 없음) `OK`. `rules.v4`에 A.2의 nat 예외(와 A.3에서 넣었다면 FORWARD 규칙)가 있다.
- 실패 시: `DEBIAN_FRONTEND` 없이 설치하면 `-y`여도 debconf 대화상자("Save current IPv4 rules?")에서 멈춘다 — 어느 답이든 이어서 `sudo netfilter-persistent save`를 실행하면 된다. 가능하면 재부팅 후 A.1을 다시 붙여 규칙과 `ip_forward`가 남아 있는지 확인한다(VERIFY-L4).

### A.5 결과 확인
서비스 노드에서 본문 **2.4**(UE 주소가 그대로 도착)와 **2.7**(종단)을 다시 붙인다. 둘 다 `OK`면 코어 쪽 요구사항이 충족된 것이다.

## 부록 B. 업그레이드 — 맵 정의가 바뀐 버전 위에 수동 설치할 때

맵 3개(`rx_state_map`, `tx_tstamp_map`, `ue_stats_map`)가 HASH 1024에서 LRU_HASH 16384로 바뀌었다(3차 테스트 빌드를 올린 서버는 LRU_HASH 1024 → 16384). 기존 핀 위에서는 새 `load`가 거부된다(3.3의 실패 시). 서비스(8장)로 설치된 서버는 8.8로 끝난다. 이 부록은 이전 버전이 수동으로 돌고 있는 서버용이며 로컬 리허설에서는 실행하지 않았다(이전 버전 핀이 필요; L1/L2 `upgrade-from-*-pins` 단계가 같은 절차를 검사한다).

### B.1 현재 정책 백업과 load 거부 확인 (이전 빌드 바이너리가 `~/vantage-5G`에 있을 때)

<!-- rh: id=B.1 host=svc mode=manual -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./target/release/vantage-5G list | tee ~/vt-l4/B.1-policies-before.txt
git fetch -q origin && git checkout -q "$COMMIT" && make build 2>&1 | tail -1
sudo ./target/release/vantage-5G load 2>&1 | tee ~/vt-l4/B.1-load.txt; echo "load_rc=${PIPESTATUS[0]}"
```
- 기대: `load_rc=1`, `pinned maps under /sys/fs/bpf/vantage do not match the object:`, `rx_state_map (pinned -> .o): type Hash -> LruHash, max_entries 1024 -> 16384`(3차 빌드에서 올 때는 `max_entries 1024 -> 16384`만)와 업그레이드 절차 안내. 이전 버전은 계속 동작한다(아무것도 바뀌지 않음).
- 실패 시: `load_rc=0`이면 핀이 이미 새 정의다(업그레이드 불필요). 그 밖의 에러는 출력 전체를 보고한다.

### B.2 detach → unload → 새 버전 설치

<!-- rh: id=B.2 host=svc mode=manual -->
**[서비스 노드]**
```bash
source ~/vt-l4/vars.sh && cd ~/vantage-5G
sudo -v
sudo ./detach.sh "$IF"; vt_ck $? "B.2 detach"
sudo ./target/release/vantage-5G unload; vt_ck $? "B.2 unload"
```
- 기대: `OK` 두 줄(`[+] Vantage-5G pins removed.`). 이어서 3.3(load) → 3.4(setup.sh) → 4.1을 진행하고, B.1의 백업(`B.1-policies-before.txt`)에 있던 다른 UE 정책도 모두 다시 `set`한다.
- 실패 시: detach가 rc=4면 남은 훅 목록을 보고 sudo로 다시 실행한다. unload가 `Vantage programs are still attached`이면 출력된 각 인터페이스에 `sudo ./detach.sh <iface>`. 다른 netns에 붙은 것은 가드가 보지 못한다(X16).

## 부록 C. 로컬 리허설 (이 문서 자체의 검증)

`testbed/runbook-rehearsal.sh`가 이 문서의 코드 블록(`<!-- rh: … -->` 주석이 붙은 것. 주석 없는 `bash` 블록이 있으면 추출 단계에서 실패)을 **그대로** 추출해 두 환경에서 순서대로 실행한다(testbed/README §5c). 두 환경의 차이는 변수 파일 값뿐이다 — 두 실행의 추출 결과(`blocks/`)는 바이트 단위로 같다.

- 붙여넣기 재현: 블록마다 새 `bash -i`에 블록 텍스트를 표준입력으로 넣는다 — bracketed paste가 없는 터미널과 같은 조건(히스토리 확장 켜짐, 표준입력을 읽는 명령이 다음 줄을 먹음). 이전 블록의 `cd`·변수에 기대지 않는다.
- (가) `VT_REH=lan`, L2 VM 한 대(Ubuntu 22.04.5, 5.15.0-198): root netns가 서비스 노드(`IF=vtlan0`, systemd-networkd veth라 재부팅 후에도 있음), 스위치 = Linux bridge, 클라이언트 A·B = netns 두 개(유선 `eth0` 같은 /24 + 기본 경로를 가진 인터넷용 `wlan0`, 사용자 `lapa`/`lapb`, netns별 sshd). `UE_GW` 비움, 정책 10/20/3/5.
- (나) `VT_REH=l3`, L3 VM 두 대: `vantage-core`(Ubuntu 22.04, Open5GS 레퍼런스 + UERANSIM v3.2.7, UE 2개가 netns `ran`의 `uesimtun0/1`)가 UPF 호스트이자 클라이언트 호스트(A·B 같은 호스트), `vantage-svc`(Ubuntu 24.04, 6.8)가 서비스 노드(`IF` = N6 NIC `enp0s8`, netplan). `UE_NET=10.45.0.0/16`, `UE_GW=10.200.0.1`(UPF N6), 정책 4/6/2/3(UERANSIM 용량). 부록 A 블록을 코어 VM에서 quickstart MASQUERADE 상태부터 실행했다.
- 래퍼가 대신한 것: 0.2·A.0-2의 `nano` 편집은 `sed`로 값 채우기, 2.3의 비밀번호 입력은 `SSH_ASKPASS`, 클라이언트 사용자의 sudo는 비밀번호 없음(실제로는 처음에 `sudo -v`), 클라이언트 sshd는 래퍼가 netns 안에 띄움(2.1의 `systemctl enable --now ssh`는 VM의 sshd에 작용), (나)에서 서비스 노드 → UERANSIM 호스트 관리 경로(10.100.0.0/24 via UPF 호스트), 8.5 재부팅 뒤 클라이언트 netns(가)·관리 경로(나) 재생성.
- 최종 실행:
  - (가) `_workspace/rh-lan-jammy-20261021_134341`: 본문 59블록 중 57 PASS, 5.2·6.5 FAIL은 처리량 행뿐이다. 이 VM은 세 번 다시 켜도 측정 구간 타이머가 열화되어(p99 51~93 ms) 처리량을 판정하지 않았다(cap 초과 없음, 미달만. counter A-UL -1.6, B-UL -0.5, A-DL -13.3, B-DL -13.0%). 같은 날 타이머가 건강했던 같은 토폴로지의 실행(`lanrh-jammy-20261021_121224`)은 +0.2 / +0.0 / -0.1 / +0.0%였다. 부록 A 7블록은 해당 없음(`UE_GW` 비움), 부록 B 2블록은 실행 안 함. 잔여물 clean.
  - (나) `_workspace/rh-l3-20261021_135727`: 2.4 음성 대조 FAIL(출발지 `10.200.0.1`만 보임 = NAT 검출), 부록 A 7블록 PASS, 본문 59블록 PASS. 타이머 두 VM 모두 내내 OK. 5.2 counter +0.0 / -0.0 / -0.0 / -0.0%, iperf -6.8 / -6.8 / -1.7 / -3.2%. 5.5 UL `-P 8` -0.1%, DL `-P 4` -0.2%. 6.5(D4) counter -0.1%. 5.4 커널 fq 대조 -4.6%. 8.6 재부팅 후 `10.45.0.x via 10.200.0.1 dev enp0s8` 유지(2.6 netplan drop-in), 두 유닛·정책·attach 복원. 6.2/6.3 killswitch는 `ping -I <UE IP>`로 동작. 잔여물 clean, 코어는 quickstart NAT 상태로 복귀.
- 실행하지 않은 것: 부록 B(이전 버전 핀 필요 — L1/L2 `upgrade-from-*-pins`가 같은 절차를 검사), 9.3(원격 scrape, `MGMT_IP` 비움), 9.4(Grafana UI), A.4의 ufw(A) 경로와 A.3의 `FORWARD DROP` 분기(VM이 ufw inactive, FORWARD ACCEPT), 코어 VM 재부팅 후 `iptables-persistent` 복원, 2.2 실패 시의 `nr-binder` 경로.
