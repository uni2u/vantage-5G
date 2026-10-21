## 하네스: Vantage-5G 개발

**목표:** eBPF(XDP RX 폴리서 + tc EDT TX 페이서) per-UE 대역폭 제어와 Rust CLI를 로컬(Docker·Ubuntu VM)에서 최대한 개발·검증한 뒤 물리 Ubuntu 서버(N6, Open5GS UPF와 별도 서버)에 설치한다.

**트리거:** Vantage-5G 기능 개발·버그 수정·코드 리뷰·로컬 테스트·설치 런북·측정 결과 분석·README 동기화 요청 시 `vantage-orchestrator` 스킬을 사용하라. 단순 질문은 직접 응답 가능.

**검증 레벨:** 호스트는 macOS(직접 빌드 불가). L1 `testbed/l1-docker.sh`(Docker Desktop, sch_fq 없음 → TX 페이싱 SKIP), L2 `testbed/l2-vbox.sh`(VirtualBox Ubuntu 24.04 / `VT_RELEASE=jammy` 22.04 VM, 전체), L3 `testbed/l3-vbox.sh`(Open5GS 레퍼런스 + UERANSIM, UPF와 서비스 노드 분리), L4 물리 서버(`docs/install-runbook.md`). 실행하지 않은 레벨은 성공으로 보고하지 마라. VirtualBox VM은 동시에 하나만 켜는 것이 원칙이다(호스트 경합 시 타이머 열화로 처리량 판정 무효 — `timer-health.txt`가 OK일 때만 처리량을 판정). 레거시 파일(`vantage_datapath*.c`, `vantage_dynamic_edt.c`, `vantage_ringbuf_edt.c`, `ready.sh`, `README_old.md`, `history.md`)은 읽기 전용이다.

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-10-19 | 초기 구성 (에이전트 4, 스킬 5, 검사 스크립트 2) | 전체 | - |
| 2026-10-19 | xdpgeneric GRO 서술 정정, EDT horizon·refill 정밀도·ACK 공유·맵 용량 체크리스트 추가 | skills/vantage-ebpf-datapath | with/without-skill 리뷰 비교에서 스킬의 오기가 GRO 결함 탐지를 막음 |
| 2026-10-19 | registry 소스로 libbpf 의미론 확정, iproute2 XDP 모드·멱등성·권한·monitor FD 항목 추가 | skills/vantage-control-plane, vantage-boundary-check | 테스트 리뷰의 BLOCKER 2건이 이 영역 |
| 2026-10-19 | 심각도 기준·ID 규칙·공동 소유자·단독 모드 반송 경로 명시, N6 NAT 전제 확인 단계 추가 | skills/vantage-boundary-check, vantage-testbed | QA 에이전트 피드백 |
| 2026-10-19 | 스킬 로드 지시에 SKILL.md Read 폴백 추가 | agents/* | 세션 중 생성된 스킬이 Skill 도구에 미등록 |
| 2026-10-19 | 로컬 검증 레벨(L1 Docker/L2 Multipass) 도입, testbed/ 스크립트 추가, testbed-runbook-writer→testbed-engineer, vantage-testbed-runbook→vantage-testbed, LINUX-VERIFY→VERIFY-Lx | 전체 | 목표가 "로컬 최대 검증 후 물리 서버 설치"로 확정, Docker Desktop에 sch_fq 없음 확인 |
| 2026-10-19 | L2를 Multipass → VirtualBox(`testbed/l2-vbox.sh`, 클라우드 이미지+cloud-init, SSH+rsync)로 교체 | testbed/, skills/vantage-testbed, 오케스트레이터 | Multipass 데몬이 로컬 네트워크 권한·이미지 잠금 문제로 불안정, 사용자 결정 |
| 2026-10-19 | dev 이미지에 sudo·rustfmt·clippy 추가, run-tests.sh verifier 임시 핀 이름 수정(bpffs는 `.` 포함 이름 거부)·루트 잔여 핀 기록·D3 이후 재부착 단계 | testbed/ | 첫 BLOCKER 수정 회귀 테스트에서 테스트 결함 4건 발견 |
| 2026-10-19 | L2에 22.04(jammy) VM 추가(`VT_RELEASE`), 비root·probe·ingress 회귀 단계, attached_ok id 기반 판정 | testbed/, skills/vantage-testbed | README가 22.04/24.04를 지원하는데 L2는 24.04만 돌려 D20(22.04 iproute2 5.15 이름 미출력)을 놓침 |
| 2026-10-19 | 병렬 엔지니어의 L2 VM 동시 사용 금지(VM 분배 규칙) | skills/vantage-orchestrator | 3차 작업에서 datapath·control-plane이 같은 VM 핀을 동시에 사용해 실험 오염 가능성 발생 |
| 2026-10-19 | 처리량 판정에 counter 기반 보조 판정(counter_verdict.py), 회귀 단계(D4/D6/D7/D16/D25/D26/업그레이드) 추가, L4 설치 런북을 docs/로 | testbed/, skills/vantage-testbed, docs/ | 3·4차 결함 수정 검증, X3 B안(cap=L2 전체 바이트) |
| 2026-10-19 | L2 VM 격리 규칙 강화(라우팅·sysctl·bpffs 공유 → 테스트 중 VM 접근 금지) | skills/vantage-orchestrator | 6차에서 별도 veth를 쓴 엔지니어의 10.45.1.0/24 주소가 테스트 경로를 가로채 실행 1회 무효 |
| 2026-10-20 | L3 테스트베드(Open5GS 레퍼런스 + UERANSIM, UPF/서비스 노드 분리) 구현, vantage-testbed 스킬 L3 갱신 | testbed/, skills/vantage-testbed | 로드맵 2번: 물리 서버 전 5G 경로·NAT 절차 로컬 검증 |
| 2026-10-20 | X10 원인=VirtualBox 타이머 열화(단일 VM 원칙, timer-health 점검), 검증 레벨 서술 갱신(L2 22.04/24.04, L3 구현됨) | CLAUDE.md, testbed/ | X10 조사 결과, 오래된 서술 정정 |
| 2026-10-20 | 로드맵 3번: apply/export, systemd 유닛, install.sh (부팅 순서 load → apply → setup.sh, 리더 승인) | src/, systemd/, install.sh | 물리 서버 재부팅 후 정책·attach 복원 |
| 2026-10-21 | VM 종료 시 게스트 sync 후 ACPI, L3 테스트에 INVALID 상태·timer-health·RAN 생존 확인/재수립 추가 | testbed/, skills/vantage-testbed | 최종 회귀에서 하드 poweroff로 cleanup 유실(L3 1차 오염), UERANSIM 무선 끊김이 FAIL·공허한 PASS로 기록됨 |
