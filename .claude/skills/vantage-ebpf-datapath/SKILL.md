---
name: vantage-ebpf-datapath
description: "Vantage-5G eBPF 데이터패스(vantage_rx_policer.c XDP 토큰버킷, vantage_tx_pacer.c tc-bpf EDT 페이서) 작성·수정 절차와 체크리스트. BPF C 코드 변경, 맵 추가/변경, LPM_TRIE 5-tuple 정책 키(Phase 2), killswitch, 토큰버킷/EDT 산술, verifier 에러 대응, XDP/tc 동작 변경 요청 시 반드시 사용. Rust CLI만 바꾸는 작업이나 레거시 vantage_datapath*.c 분석에는 사용하지 않는다."
---

# Vantage eBPF Datapath

BPF 소스를 안전하게 바꾸기 위한 절차. 빌드·verifier는 `./testbed/dev.sh 'make bpf && bpftool prog loadall vantage_rx_policer.o /sys/fs/bpf/r type xdp && bpftool prog loadall vantage_tx_pacer.o /sys/fs/bpf/t type tc'`로 직접 확인하고, RX 동작은 L1(`./testbed/l1-docker.sh`), EDT/fq 동작은 L2(`./testbed/l2-vbox.sh`)에서 검증된다.

## 구조 요약 (변경 전 반드시 재확인)

| 객체 | 훅 | 방향 | 키 | 소유 맵 | 공유 맵 |
|---|---|---|---|---|---|
| `vantage_rx_policer.o` | XDP (`xdpgeneric`) | UL, `ip->saddr`=UE | UE IPv4 (NBO) | `rx_state_map` | `ue_policy_map`, `ue_stats_map` |
| `vantage_tx_pacer.o` | tc clsact egress | DL, `ip->daddr`=UE | UE IPv4 (NBO) | `tx_tstamp_map` | `ue_policy_map`, `ue_stats_map` |

- 빌드 대상은 Makefile `BPF_SRCS`뿐이다. 다른 `.c`는 레거시 참고용.
- `struct ue_policy`, `struct ue_stats`는 두 파일에 **중복 정의**되어 있고 `src/main.rs`의 `UePolicy`/`UeStats`와 바이트 단위로 일치해야 한다.
- 공유 맵은 `LIBBPF_PIN_BY_NAME`으로 공유된다. 같은 이름의 맵은 type/key/value/max_entries가 완전히 같아야 두 번째 객체가 로드된다.

## 작업 절차

1. **계약 확인/갱신** — `_workspace/01_contract.md`에 이번 변경이 건드리는 struct·맵·SEC 이름·핀 이름을 적는다. 변경이 있으면 control-plane-engineer에게 먼저 알린다.
2. **기준선 측정** — `python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .` 을 실행해 변경 전 상태를 기록한다.
3. **구현** — 두 파일의 공유 정의를 함께 고친다. 아래 체크리스트를 코드 작성 중에 적용한다.
4. **자가 점검** — 체크리스트 각 항목에 대해 "해당 없음 / 확인함 / VERIFY-Lx"를 notes에 기록한다.
5. **계약 재검사** — `contract_check.py` 재실행. FAIL이 0이어야 QA로 넘긴다.
6. **notes 작성** — `_workspace/03_datapath_notes.md`.

## 체크리스트

### Verifier
- 모든 패킷 포인터 접근 전에 `(void *)(hdr + 1) > data_end` 경계 검사. 가변 길이 헤더(IP options의 `ihl*4`, L4 헤더)는 계산된 오프셋으로 **다시** 검사한다 — Phase 2 5-tuple 파싱에서 가장 흔한 거부 원인.
- `bpf_map_lookup_elem` 결과는 NULL 검사 후에만 역참조한다. "insert 후 재조회" 패턴에서도 재조회 결과를 검사한다.
- 루프는 상수 상한(`#pragma unroll` 또는 bounded loop, 커널 5.3+)만 사용. 스택 512B 제한 — 큰 struct는 per-CPU array scratch로.
- 0으로 나누기: 맵 값(`tx_bps`, `rx_bps`)을 분모로 쓰기 전 0 분기를 먼저 둔다(verifier는 막지 않고 결과가 0이 될 뿐이라 논리 버그가 된다).

### 산술 범위 (u64)
- EDT: `len * 8e9 / tx_bps` — `len`은 GSO skb에서 64KB까지 가능 → 최대 ~5.2e14, 안전. 새 공식을 넣으면 최대값을 notes에 적는다.
- 토큰 리필: `(elapsed_us) * rx_bps`는 장시간 유휴 후 오버플로 가능(예: 1Gbps에서 elapsed가 ~5시간을 넘으면 1.8e19 초과). **곱하기 전에 elapsed를 버킷이 가득 차는 시간으로 clamp**하는 방식을 선호한다.
- 단위: 맵은 bps, CLI는 Mbps(×1e6). 바이트↔비트 변환(×8) 위치를 주석으로 명시.

### 동시성
- XDP/tc는 여러 CPU에서 동시에 실행된다. `rx_state`/`tx_tstamp` 갱신은 원자적이지 않다 — 소량의 과다 허용은 허용 가능한 오차로 보되, 정확도 요구가 커지면 `bpf_spin_lock` 또는 per-CPU 버킷을 검토하고 trade-off를 notes에 기록.
- 카운터는 `__sync_fetch_and_add` 유지.
- lookup-miss → update → lookup 패턴은 경합 시 덮어쓰기가 가능하다. `BPF_NOEXIST`로 초기화하면 기존 상태를 덮지 않는다.

### EDT / fq 상호작용
- EDT는 root qdisc가 `fq`일 때만 동작한다(setup.sh가 설정). `fq`는 `horizon`(기본 10s)보다 먼 tstamp를 드롭하거나 cap한다 — 매우 낮은 tx_bps에 큰 백로그가 쌓이면 대량 드롭이 생긴다. 낮은 속도를 다루는 변경은 이 영향을 notes에 적는다.
- `skb->tstamp`는 CLOCK_MONOTONIC(`bpf_ktime_get_ns`) 기준. 다른 클럭 사용 금지.
- killswitch(`tx_bps==0`)는 UE로 가는 모든 패킷(SYN-ACK 포함)을 드롭한다 — TCP 연결 자체가 안 맺힌다. 이것이 의도된 동작임을 유지한다.

- 미래 tstamp 상한: 송신이 cap보다 빠르면(UDP, 버스트) `*last`가 끝없이 미래로 밀린다. `next - now`가 horizon(fq 기본 10s)보다 작은 상한을 넘으면 드롭(`TC_ACT_SHOT` + tx_drops)하고 `*last`를 전진시키지 않는다. fq가 드롭한 패킷도 이미 슬롯을 소비했다는 점을 기억한다.

### 토큰버킷 정밀도
- 정수 나눗셈 절삭으로 refill이 0이 되는데 `last_refill_ns = now`를 무조건 갱신하면 그 시간이 영구 손실된다(고 pps·저 bps에서 기아). **실제로 토큰으로 환산된 시간만큼만 `last_refill_ns`를 전진**시키거나 나머지를 이월한다.
- 다른 CPU가 더 최신 `last_refill_ns`를 써 두면 `now - last`가 언더플로한다 → `now < last`면 elapsed=0으로 처리.

### XDP / 방향 특이점
- `xdpgeneric`은 GRO 이후 skb에서 돈다 — 합쳐진 64KB 패킷이 1개로 보일 수 있다. 버킷 capacity가 최대 패킷보다 작으면 그 패킷은 영원히 드롭된다 → capacity ≥ 64KB 하한을 두거나, 초과분을 부채로 허용한다. (커널별 동작은 VERIFY-L2/L4)
- 정책은 UE 단위로 RX/TX를 공유한다: RX 버킷은 UL 데이터 + **DL 흐름의 ACK**, TX 타임라인은 DL 데이터 + **UL 흐름의 ACK**를 함께 소모한다. 양방향 동시 측정 결과에 영향을 주는 변경은 이 상호작용을 notes에 적는다.
- `pkt_len = data_end - data`와 tc `skb->len`은 모두 L2 포함 — RX/TX 회계 단위를 일치시킨다. TX의 GSO skb는 1패킷으로 세진다.
- IPv6, VLAN 태그(`ETH_P_8021Q`) 트래픽은 bypass된다. 범위를 넓히는 변경이면 명시.

### 맵 용량·수명
- HASH `max_entries`가 차면 lookup-miss 초기화가 실패하고 해당 UE는 상태 없이 통과한다. 상태/통계 맵은 `LRU_HASH`를 고려하고, 정책 삭제 시 상태 엔트리 정리 책임(CLI vs BPF)을 계약에 적는다.

## Phase 2 (LPM_TRIE) 가이드
상세는 `references/phase2-lpm-trie.md`를 읽는다 — 키 레이아웃(prefixlen 선두, packed), 바이트 순서, Rust 쪽 키 직렬화 계약을 다룬다.

## notes 템플릿 (`_workspace/03_datapath_notes.md`)
```
## 변경 요약
## 계약 변경 (struct/맵/SEC/핀)  — 없음 | 있음(diff)
## 체크리스트 결과  (항목: 해당없음/확인/VERIFY-Lx + 근거)
## 산술 최대값 분석
## 빌드·verifier 결과 (dev.sh 실행 출력) / 검증 이관 항목
```
