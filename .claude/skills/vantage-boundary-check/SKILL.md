---
name: vantage-boundary-check
description: "Vantage-5G 경계면 교차 검증 및 코드 리뷰. BPF C struct ↔ Rust #[repr(C)] ABI, 공유 핀 맵 정의 일치, MAP_/PROG_/OBJ_ 상수 ↔ BPF SEC/Makefile, 핀 경로 ↔ setup.sh/detach.sh, Prometheus 메트릭 ↔ README를 scripts/contract_check.py로 자동 검사하고 verifier·산술 오버플로·동시성·fq/EDT 리뷰를 수행. '리뷰해줘', '검증', 'ABI 맞는지', '정합성', '버그 찾아줘', 변경 후 QA, PR 전 점검 요청 시 반드시 사용."
---

# Vantage Boundary Check

## 1. 결정적 검사 (항상 먼저)

```bash
python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .
```

| ID | 검사 | FAIL이 뜻하는 실제 장애 |
|---|---|---|
| C1 | 여러 BPF 객체의 동일 이름 struct 일치 | RX/TX가 같은 맵 값을 다르게 해석 |
| C2 | Rust `#[repr(C)]` ↔ C struct (순서·이름·폭) | CLI가 쓴 정책을 커널이 다른 필드로 읽음 — 에러 없이 |
| C3 | 공유 핀 맵 정의 일치 | 두 번째 객체 `load` 실패 |
| C4 | Rust `MAP_*` ↔ BPF 맵 | `set`/`stats`가 핀을 못 찾음 |
| C5 | `PROG_*_NAME`/`OBJ_*` ↔ SEC 함수/Makefile | `load`가 프로그램/객체를 못 찾음 |
| C6 | 핀 경로 ↔ setup.sh/detach.sh | attach 실패 |
| C7 | 메트릭 ↔ README | 대시보드/PromQL이 빈 시계열 |
| C8 | Makefile BPF_SRCS 존재, 레거시 식별 | 빌드 실패 |

종료 코드 1 = FAIL 존재. 출력 원문을 보고서에 붙인다. 스크립트가 `WARN unparsed`를 내면 해당 정의를 수동 비교한다.

**스크립트가 못 보는 것:** `packed` 속성, 키 바이트 순서 의미, 값의 단위(bps vs Mbps), 동적 로직. 이건 2단계에서 사람이 본다.

## 2. 판단 검사 (리뷰 체크리스트)

각 항목에서 결함을 찾으면 **실패 시나리오**(구체 입력·상태 → 잘못된 결과)를 함께 쓴다.

**데이터패스** — `vantage-ebpf-datapath` 스킬의 체크리스트(verifier, 산술 범위, 동시성, EDT/fq, XDP 특이점)를 그대로 적용한다. 특히:
- 맵 값 분모 0 처리, 장시간 유휴 후 토큰 리필 곱셈 오버플로
- lookup-miss 초기화 경합(`BPF_ANY` vs `BPF_NOEXIST`)
- 정책 삭제(`reset`) 후 `rx_state_map`/`tx_tstamp_map` 잔존 → 재설정 시 오래된 tstamp/토큰 사용 여부
- 정책 변경 시 기존 버킷 capacity와 새 cap 불일치

**컨트롤플레인** — `vantage-control-plane` 스킬 규칙. 특히:
- libbpf 핀 의미론(pin_root_path vs 수동 pin)
- 단위 변환(Mbps→bps `saturating_mul`), 키 바이트 순서
- `unload`/`detach` 순서, 스크립트 멱등성

- iproute2 XDP 모드 슬롯(`xdpgeneric off`), setup.sh 재실행 EBUSY, qdisc 복원
- 장기 프로세스(`monitor`)의 맵 FD 수명, `unload` 시 attach 가드
- 비root 권한 가정(`unprivileged_bpf_disabled`)

**라이브러리 의미론** — libbpf/libbpf-rs 동작이 판정을 좌우하면 `~/.cargo/registry/src/*/libbpf-sys-*/libbpf/src/`, `libbpf-rs-*/src/`의 Cargo.lock 버전 소스를 읽어 정적으로 확정한다. 소스로 확정되면 결함/비결함으로 판정한다.

**테스트베드 전제** — 정책 키(UE IP)가 서비스 노드 N6에서 실제로 보이는지(UPF가 N6에서 NAT/MASQUERADE하면 모든 정책이 무효). 이 전제를 흔드는 변경·문서는 VERIFY-L3로 넘긴다(`VT_NAT=1`로 L1/L2에서도 실패 모드 재현 가능).

**문서** — README의 명령·플래그·기본값(포트 9090 등)이 clap 정의와 일치하는지.

## 3. 보고서 (`_workspace/04_qa_report.md`)

```
## contract_check.py 출력
## 결함
| ID | 심각도 | 위치 | 실패 시나리오 | 소유자 | 상태 |
## 검증 이관  (VERIFY-L1 Docker / L2 Ubuntu VM·fq / L3 5G 경로 / L4 물리 NIC — 가장 낮은 레벨로 태깅)
## 판정: PASS | FAIL  (BLOCKER/MAJOR가 하나라도 OPEN이면 FAIL)
```

심각도:
- **BLOCKER** — 정상 절차에서 load/attach/detach 실패, 또는 운영자 의도와 다른 정책이 적용되거나 **제거되지 않고 남음**
- **MAJOR** — 특정 조건(부하, 유휴, 경합, 재실행, 재로드)에서 잘못된 속도·카운터·정책 상태
- **MINOR** — 관측성 오표시(게이지·문구), 에러 메시지, 문서, 가독성

ID 규칙: 이전 보고서가 없으면 D1부터. 있으면 기존 ID 유지 + 새 결함은 다음 번호. 의견은 O1부터.
소유자: 한 결함이 양쪽에 걸치면 "주 소유자/보조"로 적는다 — 계약(맵 type, 상태 정리 책임)을 바꾸는 쪽이 BPF면 datapath-engineer가 주도한다.
반송 경로: 팀 모드면 소유자에게 SendMessage, 단독 리뷰 모드면 보고서의 결함 표가 곧 반송이다(리더가 사용자에게 수정 여부를 묻는다).

## 4. 점진 검증
모듈 하나(데이터패스 또는 컨트롤플레인)가 끝날 때마다 1·2단계를 해당 범위로 실행한다. 마지막 통합 검사에서는 전체를 다시 돌린다.
