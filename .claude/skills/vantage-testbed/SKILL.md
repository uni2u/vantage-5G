---
name: vantage-testbed
description: "Vantage-5G 로컬 테스트 실행과 물리 서버 설치 준비. L1 Docker(빌드·verifier·load·RX 셰이핑·killswitch), L2 VirtualBox Ubuntu VM(fq/EDT DL 페이싱, setup.sh/detach.sh, 4세션 iperf3 ±10%), L3 Open5GS+UERANSIM 5G 경로, L4 물리 서버 설치 런북, iperf3 결과 판정(scripts/iperf_verdict.py), README 동기화. '테스트 돌려줘', '로컬에서 검증', 'L1/L2', '빌드 되는지', 'iperf 결과 봐줘', '속도가 안 맞아', '설치 런북', '물리 서버에 올리기', 'README 업데이트' 요청 시 반드시 사용. 코드 정합성 리뷰는 vantage-boundary-check를 쓴다."
---

# Vantage Testbed

목표: **로컬에서 최대한 검증한 뒤 물리 Ubuntu 서버에 설치**한다. 결함은 가장 낮은(빠른) 레벨에서 잡는다.

## 검증 레벨

| 레벨 | 환경 | 명령 | 검증 범위 | 못 하는 것 |
|---|---|---|---|---|
| L0 | macOS 호스트 | `python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .` | C↔Rust↔스크립트↔README 계약 | 실행 전부 |
| L1 | Docker Desktop (커널 linuxkit, 특권 컨테이너) | `./testbed/l1-docker.sh` | build, verifier, `load`/핀, 멱등 load, attach, UL RX 셰이핑(동시 2세션), killswitch, reset, detach/unload 잔존물 | **sch_fq 없음** → setup.sh, DL EDT 페이싱 SKIP |
| L2 | VirtualBox Ubuntu VM: `VT_RELEASE=noble`(기본, 24.04, `vantage-svc`, SSH :2522) / `jammy`(22.04, iproute2 5.15, `vantage-svc-jammy`, SSH :2523) | `[VT_RELEASE=jammy] ./testbed/l2-vbox.sh` | L1 전부 + setup.sh(재실행·비root·ingress 거부 포함) + DL 페이싱 + README §8 4세션 동시. 지원 OS 둘 다 돌린다 | 실제 5G 경로, 물리 NIC |
| L3 | VirtualBox VM 2대 (core: Open5GS+UERANSIM, svc: Vantage) | (구축 예정 — 아래) | 실제 UE IP가 N6에 보이는지(NAT), GTP 경로 뒤의 셰이핑 | 물리 NIC native XDP |
| L4 | 물리 서버 | `_workspace/05_install_runbook.md` (사용자 실행) | 실제 NIC·드라이버·실 Core | — |

빠른 단건 실험: `./testbed/dev.sh '<cmd>'` — 저장소 사본에서 명령 실행(예: `'make build'`, `'bpftool prog loadall vantage_tx_pacer.o /sys/fs/bpf/t type tc'`).

### 공통 테스트 본체 `testbed/run-tests.sh`
L1·L2가 같은 스크립트를 쓴다. 운영자 경로 그대로(make build → `vantage-5G load` → `./setup.sh` → set → iperf3 → killswitch → `./detach.sh` → unload)를 실행하고, 결과 디렉토리에 `summary.txt`(PASS/FAIL/SKIP), 단계별 `.log`, iperf3 JSON, `spec.csv`, `verdict.txt`, `stats_*.txt`를 남긴다. 토폴로지는 `testbed/netns-topo.sh`(UE netns 2개 → core netns(UPF 역할) → N6 veth `vt-n6` → 서비스 노드). `VT_NAT=1`이면 Open5GS 레퍼런스처럼 MASQUERADE를 걸어 "UE IP가 안 보이는" 실패 모드를 재현한다. `VT_NETEM="delay 10ms rate 200mbit"`로 무선 구간을 흉내 낼 수 있다. `VT_SETUP_AS=ubuntu`면 setup.sh/detach.sh를 NOPASSWD sudo 사용자로 실행(D21). setup.sh는 bpftool 필수이므로 `setup.sh-no-bpftool`(새 iface)·`setup.sh-no-bpftool-attached`(attach 상태) 단계가 매 실행 bpftool을 숨겨 rc=2·상태 무변경을 확인한다(`VT_NO_BPFTOOL`은 호환용, 무시). 회귀 단계: `map-sizes-d25`(LRU 3개 lru_hash/16384, policy hash/1024, nproc·memlock 기록), `d7-reset-clears`, `d26-same-set-keeps-state`(같은 값 set → `(unchanged; rx/tx state kept)`, 두 상태 맵 값 동일), `d26-changed-set-clears`(tx 또는 rx 변경 → 두 맵 비움), `d6-small-pkt-no-starvation`, `d4-fwd-overload-then-tcp`(vt-src netns → root ns 포워딩 → vt-n6, D15 포함), `d16-tx-segments`(fq 있을 때), `unload-refused-while-attached`, `detach-rc`(nobody로 rc=4, 없는 iface rc=1), `upgrade-from-hash-pins`(HASH/1024로 바꾼 2차 .o) · `upgrade-from-lru1024-pins`(LRU/1024인 3차 .o): 이전 .o를 load·attach한 뒤 새 load rc=1 + `max_entries 1024 -> 16384` + 절차 → detach→unload→load→setup. iperf 판정 외에 `counter-verdict`(`scripts/counter_verdict.py`, stats rx_bytes/tx_bytes 증분 = L2 바이트, X3 B안)를 함께 남긴다. 비root 단계 `setup.sh-nonroot`(사용자 `VT_NONROOT_USER`, 기본 ubuntu)와 `setup.sh-ingress-refused`(D22)는 fq가 있으면 항상 돈다. l2-vbox.sh는 이 변수들을 VM으로 넘기고 결과를 `_workspace/l2-<release>-<ts>/`에 둔다.

테스트 스크립트를 고치는 것은 이 스킬의 소유다. 제품 코드 결함을 테스트에서 우회하지 않는다 — 예: 스크립트 실행권한이 없으면 `bash setup.sh`로 돌리지 말고 FAIL로 남긴다(물리 서버에서도 똑같이 실패하므로).

## 모드 A — 로컬 테스트 실행

1. 변경 범위로 필요한 최저 레벨을 고른다: 계약만 → L0, BPF/CLI 로직 → L1, TX/qdisc/setup.sh → L2, 5G 경로·NAT → L3.
2. 실행하고 `summary.txt`의 FAIL마다 해당 `.log`를 읽어 원인을 분류한다: **제품 결함**(소유 엔지니어에게 근거와 함께 반송) / **테스트 결함**(직접 수정) / **환경 한계**(SKIP 사유로 기록, 상위 레벨로 이관).
3. 결과를 `_workspace/05_test_report.md`에: 레벨, 커밋, 단계별 결과표, verdict 표, 원인 분류, 상위 레벨로 넘긴 항목.
4. 이전 테스트 리포트가 있으면 단계별로 비교해 회귀를 표시한다.

## 모드 B — 결과 판정 (iperf3)

```bash
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py <dir>/spec.csv [--skip 5 --tol 0.10 --cv-warn 0.15]
```
보조 판정(cap = L2 바이트, ACK 포함): `python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py <dir>/spec.csv <dir>/stats_t1.txt <dir>/stats_t2.txt`. iperf goodput은 헤더(약 4.4%)와 반대 방향 ACK만큼 cap보다 낮게 읽힌다.
처리량 FAIL 분류: cap **초과**는 제품 결함. 미달이면 같은 VM에서 커널 자체 셰이퍼 대조(`tc qdisc replace dev vt-n6 root fq maxrate 20mbit`, `tc filter add dev vt-n6 ingress matchall action police rate 10mbit burst 312500 drop`)와 이전 커밋 A/B를 돌려, 커널 셰이퍼도 미달이면 환경으로 분류한다.
cap 0(killswitch)에서 연결 실패는 PASS. 진단표:

| 증상 | 1순위 가설 | 구분 방법 |
|---|---|---|
| DL이 cap보다 훨씬 높음 | root qdisc가 fq 아님 / 다른 iface / 정책 키 불일치 | `tc qdisc show`, `stats` tx_bytes 증가 여부, `list` |
| UL이 cap보다 훨씬 높음 | XDP가 다른 iface / 키 불일치(NAT) | rx_bytes 증가 여부, `tcpdump -ni <if> host <UE>` |
| cap보다 지속적으로 낮음 | refill 절삭, GRO 큰 skb, 경로 병목, ACK가 반대 방향 버킷 소모 | `reset` 후 기준 처리량, 단방향 단독 실행 |
| CV 높음 | 교차 간섭, 비원자 상태 갱신, TCP 톱니 | 단독 vs 동시 비교 |
| DL 대량 드롭 + 저속 정책 | fq horizon/flow_limit 초과 | `tc -s qdisc show` |

## 모드 C — L4 물리 서버 설치 런북 (`_workspace/05_install_runbook.md`)

L1~L3을 통과한 커밋에 대해서만 작성한다. 각 단계는 `명령 / 기대 결과 / 실패 시` 형식.
1. 사전 조건: 커널·BTF, 패키지, 커밋 해시, **N6에서 UE IP가 보이는지**(`tcpdump -ni <N6> host <UE_IP> -c 5`; UPF IP만 보이면 중단 — Open5GS 서버의 MASQUERADE 규칙 확인)
2. 빌드 → load → `./setup.sh <N6>` (NIC 드라이버와 native XDP 지원 여부 기록, `ethtool -i`, 멀티큐/`mq` 여부)
3. README §8 4세션 측정을 `iperf3 -J`로 수집하고 `spec.csv` 작성 → 결과를 가져오면 모드 B
4. detach/unload 후 잔존물 확인
5. 로컬에서 재현 못 한 항목(native XDP, 실제 NIC 멀티큐, 실 Core)을 별도 체크리스트로

## 모드 D — README 동기화
코드에서 확인한 사실만 쓴다(clap 정의, `opts!` 메트릭, 스크립트 동작). 수정 후 `contract_check.py` C7 PASS 확인. `history.md`, `README_old.md`는 건드리지 않는다.

## L3 구축 계획 (미구현)
- `vantage-core` VM: Open5GS(레퍼런스 설치, ogstun 10.45.0.0/16) + UERANSIM gNB/UE 2대. N6 라우팅으로 `vantage-svc`에 도달.
- `vantage-svc` VM: L2와 동일.
- 시나리오: (a) 레퍼런스 그대로(MASQUERADE) → 정책 불일치 확인, (b) 서비스 대역 NAT 제외 → README §8 측정.
- 구축 시 이 절을 실제 스크립트 경로로 교체한다.
