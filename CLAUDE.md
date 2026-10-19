## 하네스: Vantage-5G 개발

**목표:** eBPF(XDP RX 폴리서 + tc EDT TX 페이서) per-UE 대역폭 제어와 Rust CLI를 로컬(Docker·Ubuntu VM)에서 최대한 개발·검증한 뒤 물리 Ubuntu 서버(N6, Open5GS UPF와 별도 서버)에 설치한다.

**트리거:** Vantage-5G 기능 개발·버그 수정·코드 리뷰·로컬 테스트·설치 런북·측정 결과 분석·README 동기화 요청 시 `vantage-orchestrator` 스킬을 사용하라. 단순 질문은 직접 응답 가능.

**검증 레벨:** 호스트는 macOS(직접 빌드 불가). L1 `testbed/l1-docker.sh`(Docker Desktop, sch_fq 없음 → TX 페이싱 SKIP), L2 `testbed/l2-vbox.sh`(VirtualBox Ubuntu 24.04 VM, 전체), L3 Open5GS+UERANSIM(미구축), L4 물리 서버(런북). 실행하지 않은 레벨은 성공으로 보고하지 마라. 레거시 파일(`vantage_datapath*.c`, `vantage_dynamic_edt.c`, `vantage_ringbuf_edt.c`, `ready.sh`, `README_old.md`, `history.md`)은 읽기 전용이다.

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
