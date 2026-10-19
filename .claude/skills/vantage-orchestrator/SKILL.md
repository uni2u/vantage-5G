---
name: vantage-orchestrator
description: "Vantage-5G(eBPF XDP/tc EDT per-UE 대역폭 제어 + Rust CLI) 개발 에이전트 팀 조율. 기능 추가·수정(Phase 2 LPM_TRIE, 5-tuple, systemd, Grafana 대시보드, 새 CLI 명령, 메트릭), 버그 수정, 코드 리뷰/정합성 검증, 테스트베드 검증 런북, iperf3 측정 결과 분석, README 동기화 요청 시 반드시 사용. 후속 작업: 다시 실행, 재실행, 업데이트, 수정, 보완, 'QA만 다시', '런북만 다시', '이전 결과 기반으로', 결과 개선, 측정 결과 가져왔어 등에도 이 스킬을 사용. 단순 개념 질문(EDT가 뭐야 등)은 직접 응답."
---

# Vantage-5G Orchestrator

요청을 분류해 필요한 전문가만 투입하고, **계약 우선 → 병렬 구현 → 경계면 QA → 로컬 테스트(L1 Docker, L2 Ubuntu VM) → 물리 서버 설치 런북** 순으로 진행한다. 목표는 물리 서버에 올리기 전에 로컬에서 결함을 소진하는 것이다.

## 실행 모드: 하이브리드 (생성-검증 + 전문가 풀)

| Phase | 모드 | 이유 |
|---|---|---|
| 3 구현 | 에이전트 팀 | 데이터패스↔컨트롤플레인이 계약 변경을 실시간 교환해야 함 |
| 4 QA | 팀 내 점진 검증 (리뷰 단독 요청이면 서브 에이전트 1명) | 결함을 소유자에게 직접 반송 |
| 5 로컬 테스트·런북 | 팀원 (제품 결함을 엔지니어에게 직접 반송) | QA의 VERIFY-Lx를 입력으로 받는 순차 작업 |

**도구 매핑:** `TeamCreate`/`TaskCreate`가 있으면 사용한다. 없는 환경에서는 `Agent` 도구로 팀원을 `name`을 붙여 스폰하고(`subagent_type`=에이전트 정의 이름, `model: "opus"`), 팀원 간·리더↔팀원 통신은 `SendMessage({to: "<name>"})`로 한다. 어느 경우든 산출물은 `_workspace/` 파일로 넘긴다.

## 에이전트 구성

| 팀원 | subagent_type | 스킬 | 출력 |
|---|---|---|---|
| bpf-datapath-engineer | bpf-datapath-engineer | vantage-ebpf-datapath | `*.c`, `_workspace/03_datapath_notes.md` |
| control-plane-engineer | control-plane-engineer | vantage-control-plane | `src/main.rs`, 스크립트, `_workspace/03_control_plane_notes.md` |
| boundary-qa | boundary-qa | vantage-boundary-check | `_workspace/04_qa_report.md` |
| testbed-engineer | testbed-engineer | vantage-testbed | `testbed/`, `_workspace/05_test_report.md`, `_workspace/05_install_runbook.md`, README, `_workspace/06_result_analysis.md` |

## Phase 0: 컨텍스트 확인

1. `_workspace/` 존재 여부 확인.
2. 분기:
   - 없음 → **초기 실행**
   - 있음 + 부분 수정 요청("QA만 다시", "런북 고쳐줘", 피드백) → **부분 재실행**: 해당 팀원만 호출, 이전 산출물 경로를 프롬프트에 포함
   - 있음 + 새 기능/새 요청 → **새 실행**: `_workspace/`를 `_workspace_{YYYYMMDD_HHMMSS}/`로 이동 후 진행
   - 사용자가 측정 결과를 가져옴 → **결과 분석 경로**(Phase 6)로 바로 이동
3. `_workspace/`는 `.gitignore`에 포함시킨다(없으면 추가).

## Phase 1: 요청 분류 및 입력 저장

요청을 `_workspace/00_input/request.md`에 원문 그대로 저장하고 유형을 정한다:

| 유형 | 투입 | 진행 Phase |
|---|---|---|
| 기능/버그 — 데이터패스만 | datapath + qa + testbed | 2 → 3 → 4 → 5 |
| 기능/버그 — 컨트롤플레인만 | control-plane + qa + testbed | 2 → 3 → 4 → 5 |
| 기능 — 양쪽 (예: Phase 2 LPM_TRIE) | 전원 | 2 → 3 → 4 → 5 |
| 리뷰/정합성 검증만 | qa (서브 에이전트 단독) | 4 |
| 테스트만 / 설치 런북만 / README만 | testbed-engineer 단독 | 5 |
| 물리 서버 측정 결과 분석 | testbed-engineer (+ 필요 시 엔지니어) | 6 |

범위가 모호하면(어느 방향? 어떤 키?) 구현 전에 사용자에게 한 번 묻는다.

## Phase 2: 계약 확정 (리더 수행)

1. `python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .` 실행 → 기준선을 `_workspace/01_baseline_check.txt`에 저장.
2. `_workspace/01_contract.md` 작성: 이번 변경이 건드리는 struct(필드·폭·순서·packed), 맵(type/key/value/max_entries/flags), SEC 이름, 핀 경로, CLI 플래그, 메트릭 이름. 변경 없음이면 "변경 없음"이라고 명시.
3. breaking 변경(맵 type 교체, 메트릭 이름 변경)은 사용자에게 알린다.

## Phase 3: 구현

**실행 모드:** 에이전트 팀

1. 해당 엔지니어를 병렬 스폰(`run_in_background: true`, `model: "opus"`). 프롬프트에 포함: 요청 경로, 계약 경로, 이전 산출물 경로(부분 재실행 시), "작업 시작 시 담당 스킬을 Skill 도구로 로드".
2. 통신 규칙:
   - 계약 변경은 반드시 `_workspace/01_contract.md`를 먼저 갱신한 뒤 상대 엔지니어에게 SendMessage.
   - 각 엔지니어는 자기 모듈 완료 직후 boundary-qa에게 검증 요청(점진 QA).
3. 리더는 계약 충돌 에스컬레이션을 받으면 사용자 의도에 비추어 결정하고 계약 파일에 기록한다.

## Phase 4: 경계면 QA

**실행 모드:** 팀 내 점진 검증 (리뷰 단독이면 서브 에이전트)

1. boundary-qa가 모듈별 검증 → 마지막에 전체 통합 검증.
2. FAIL 결함은 소유자에게 직접 반송 → 수정 → 재검증. **재검증 루프는 최대 2회.** 이후에도 BLOCKER가 OPEN이면 리더가 사용자에게 보고하고 진행 여부를 묻는다.
3. 최종 `_workspace/04_qa_report.md` 판정과 `contract_check.py` 종료 코드 0 확인.

## Phase 5: 로컬 테스트 · 설치 런북 · 문서

**실행 모드:** 팀원 (구현 팀 유지 — 제품 결함을 엔지니어에게 바로 반송)

1. testbed-engineer가 변경 범위에 맞는 레벨을 실행: L1 `./testbed/l1-docker.sh` (항상), L2 `./testbed/l2-vbox.sh` (TX/EDT·qdisc·setup.sh/detach.sh 변경 시, 또는 설치 전 최종 확인). 결과 → `_workspace/05_test_report.md`.
2. 제품 결함 FAIL → 소유 엔지니어 수정 → 해당 레벨 재실행. QA 루프와 합쳐 **최대 2회**, 이후에도 FAIL이면 사용자에게 보고.
3. L1·L2(가능하면 L3)를 통과하면 `_workspace/05_install_runbook.md`(L4 물리 서버) 작성.
4. 사용자 가시적 변경이면 README 동기화 후 `contract_check.py` 재실행.

## Phase 6: 결과 분석 (사용자가 물리 서버 측정 결과를 가져왔을 때)

1. 결과 파일을 `_workspace/00_input/results/`에 저장 (`spec.csv` 없으면 리더가 정책 값으로 작성).
2. testbed-engineer가 `iperf_verdict.py` 판정 + 진단 → `_workspace/06_result_analysis.md`.
3. 코드 원인 의심 시 해당 엔지니어에게 근거와 함께 넘겨 Phase 3부터 부분 재실행.

## Phase 7: 정리 및 보고

1. 팀원 종료, `_workspace/` 보존.
2. 사용자 보고: 변경 파일, QA 판정과 남은 결함, **레벨별 테스트 결과(실행한 것만 PASS)**, SKIP과 그 사유, 물리 서버 설치 런북 경로.
3. 피드백 요청: "결과나 팀 구성에서 바꾸고 싶은 점이 있나요?" — 피드백은 CLAUDE.md 변경 이력과 함께 해당 에이전트/스킬에 반영.

## 데이터 흐름

```
request.md ─→ [리더] contract_check 기준선 + 01_contract.md
                    │
        ┌───────────┴───────────┐
 [datapath-engineer] ⇄ SendMessage ⇄ [control-plane-engineer]
        │ 03_datapath_notes      │ 03_control_plane_notes
        └──────→ [boundary-qa] ←─┘   (모듈별 점진 검증, 결함 반송 ≤2회)
                    │ 04_qa_report (VERIFY-Lx)
                    ↓
          [testbed-engineer] L1 Docker → L2 VirtualBox VM ─(제품 결함)→ 엔지니어
                    │ 05_test_report.md, README
                    ↓ (로컬 통과 시)
          05_install_runbook.md → 사용자가 물리 서버 실행 → results/
                    → 06_result_analysis.md ─(코드 원인)→ Phase 3
```

## 에러 핸들링

| 상황 | 전략 |
|---|---|
| 팀원 실패/무응답 | SendMessage로 상태 확인 → 1회 재스폰. 재실패 시 해당 영역 누락을 보고서에 명시 |
| 계약 충돌 | 삭제하지 않고 양쪽 안을 계약 파일에 병기 → 리더 결정 → 기록 |
| QA 2회 후 BLOCKER 잔존 | 사용자에게 결함과 선택지 제시, 임의 진행 금지 |
| contract_check.py 파싱 경고 | QA가 수동 비교, 반복되면 스크립트 개선을 하네스 진화 항목으로 제안 |
| 레벨 환경 실패 (Docker 미기동, VirtualBox VM 생성·SSH 실패) | 제품 결과와 분리해 "환경 실패"로 보고, 사용자 조치 안내 |
| 로컬 검증 불가 항목 | 성공으로 보고하지 않음 — 상위 레벨(L2→L3→L4 런북)로 이관 |
| 측정 결과 불완전 | 판정 가능한 세션만 판정, 부족한 수집 명령을 정확히 요청 |

## 테스트 시나리오

### 정상 흐름 — "Prometheus 메트릭에 ue별 policy 변경 횟수 추가해줘"
1. Phase 0: `_workspace/` 없음 → 초기 실행
2. Phase 1: 컨트롤플레인만 → control-plane + qa + runbook
3. Phase 2: 기준선 PASS, 계약에 신규 메트릭 `vantage_ue_policy_updates_total` 기록
4. Phase 3: control-plane-engineer가 main.rs 수정, README 반영 요청
5. Phase 4: boundary-qa — 처음엔 C7 FAIL(README 미반영) → testbed-engineer가 README 갱신 → PASS
6. Phase 5: L1에서 `monitor` 기동 후 `curl :9090/metrics | grep policy_updates` 확인
7. 결과: 변경 파일 + QA PASS + L1 결과 + 설치 런북 경로 보고

### 에러 흐름 — Phase 2 LPM_TRIE에서 struct 불일치
1. datapath-engineer가 키를 packed로 정의, control-plane-engineer는 계약 갱신 전 non-packed로 구현
2. boundary-qa가 수동 비교에서 packed 불일치 BLOCKER 발견 → control-plane-engineer에게 반송
3. 1회차 수정에서 필드 순서 오류 → 2회차 수정 후 PASS
4. 만약 2회 후에도 OPEN이면 리더가 사용자에게 보고하고 중단
5. L1에서 verifier·load·RX 셰이핑 확인, L2에서 TX 확인 후 최종 보고

### 결과 분석 흐름 — "iperf 결과 가져왔어, B-DL이 9Mbps 나와"
1. Phase 0: 결과 분석 경로
2. `iperf_verdict.py` → B-DL FAIL(+80%, over cap)
3. 진단표: fq root 미설정 / 다른 iface → `tc qdisc show`, `stats` tx_bytes 증가 여부 요청
4. 사용자 추가 출력으로 원인 확정 후 필요 시 Phase 3 부분 재실행
