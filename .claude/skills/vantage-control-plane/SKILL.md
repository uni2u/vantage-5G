---
name: vantage-control-plane
description: "Vantage-5G Rust CLI(src/main.rs: load/unload/set/reset/list/stats/monitor, libbpf-rs 로드·핀, 맵 직렬화, Prometheus exporter)와 운영 자산(setup.sh, detach.sh, Makefile, systemd 유닛, Grafana 대시보드) 작성·수정 절차. CLI 서브커맨드 추가, 메트릭 추가/변경, 핀 경로, attach 스크립트, 부팅 시 자동 load, 대시보드 JSON 요청 시 반드시 사용. BPF C 코드만 바꾸는 작업에는 vantage-ebpf-datapath를 쓴다."
---

# Vantage Control Plane

Rust CLI와 운영 스크립트를 BPF 객체와 어긋나지 않게 바꾸는 절차.

## 로컬 검증
- macOS 호스트의 `cargo check`는 libbpf-sys(pkg-config·libelf) 때문에 실패한다. 빌드는 `./testbed/dev.sh 'cargo build --release'`로, 동작은 `./testbed/l1-docker.sh`(load·set·stats·detach)로 확인한다.
- setup.sh/detach.sh와 qdisc 동작은 fq가 있는 L2(`./testbed/l2-vbox.sh`)에서만 검증된다. 실행하지 않은 레벨은 성공이라 주장하지 않는다.

## 작업 절차
1. `_workspace/01_contract.md` 확인. CLI 요구로 맵 형태가 바뀌어야 하면 bpf-datapath-engineer에게 제안한다(C 직접 수정 금지).
2. 기준선: `python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .`
3. 구현 — 아래 규칙 적용.
4. `cargo fmt --check` (실패하면 `cargo fmt` 후 diff 확인), `contract_check.py` 재실행 → FAIL 0.
5. `_workspace/03_control_plane_notes.md` 작성 후 boundary-qa에 검증 요청.

## 규칙

### Wire 계약
- `#[repr(C)]` struct 이름은 C struct의 CamelCase(`ue_policy`→`UePolicy`)로 유지 — 검사 스크립트가 이 규칙으로 짝을 찾는다.
- 필드 순서·폭은 C와 동일. packed C struct는 `#[repr(C, packed)]`.
- 키 직렬화는 네트워크 바이트 순서(`Ipv4Addr::octets()`, 포트는 `to_be_bytes()`). `from_bytes`는 길이를 assert한다 — 값 크기가 바뀌면 그 assert가 첫 신호다.
- `MAP_*`, `PROG_*_NAME`, `OBJ_*`, `BPF_PIN_DIR` 상수를 추가/변경하면 검사 스크립트가 C/Makefile/스크립트와 대조한다. 이 네이밍 규칙을 지켜야 검사가 동작한다.

### 라이브러리 의미론은 소스로 확정한다
libbpf-rs/libbpf-sys(벤더된 libbpf C 포함) 소스가 `~/.cargo/registry/src/*/`에 있다. API 시그니처나 동작이 불확실하면 추측하지 말고 Cargo.lock 버전의 소스를 grep해서 확인한다 — 이렇게 정적으로 확정한 항목은 검증 이관 대상이 아니다.

### libbpf 핀 의미론
- `LIBBPF_PIN_BY_NAME` 맵은 open 시 `pin_root_path`(기본 `/sys/fs/bpf`) 기준 pin_path가 정해지고 load 시 자동 핀/재사용된다. 다른 경로로 수동 `bpf_map__pin()`하면 "different pin path"로 -EINVAL. → 핀 위치는 `ObjectBuilder::pin_root_path(BPF_PIN_DIR)`로 지정하고, 맵 수동 pin은 하지 않는다. (2026-10-19 리뷰에서 현재 `load_and_pin()`이 이 이유로 실패함을 libbpf 1.7.0 소스로 확인)
- `unload`는 핀만 제거한다. attach가 남아 있으면 프로그램은 고아 맵으로 계속 동작하고 CLI로 더 이상 정책을 바꿀 수 없다 — 순서는 항상 `detach.sh` → `unload`, 가능하면 `unload`가 attach 여부를 확인한다.
- `monitor`처럼 오래 사는 프로세스가 연 맵 FD는 재로드 후에도 옛 맵을 가리킨다.

### 권한
Ubuntu 기본 `kernel.unprivileged_bpf_disabled=2`, `/sys/fs/bpf` 0700 → `set/list/stats`도 사실상 root(CAP_BPF)가 필요하다. 문서·안내 문구를 이에 맞춘다.

### iproute2 운영 의미론
- XDP는 모드별 슬롯이 따로다: `xdpgeneric`으로 붙였으면 `ip link set dev X xdpgeneric off`로 뗀다(모드 없는 `xdp off`는 native 지원 NIC에서 DRV 슬롯만 대상).
- 이미 프로그램이 붙은 슬롯에 다시 `ip link set … xdpgeneric pinned`하면 `-force` 없이는 EBUSY. 재실행 시 어떤 단계가 이전 상태를 지우고 어떤 단계가 실패하는지 순서대로 따져 멱등성을 확인한다.
- root qdisc를 `fq` 단일로 바꾸면 멀티큐 NIC의 `mq`가 사라진다. detach 시 원래 qdisc 복원 여부를 명시.

### 메트릭
- 이름 접두사 `vantage_ue_`, 라벨 `ue_ip`. 카운터는 `_total` 접미사.
- 메트릭 추가/변경 시 README §7 목록을 같은 변경에 포함하도록 testbed-engineer에게 알린다(검사 C7이 불일치를 FAIL로 잡는다).
- BPF 카운터 → Prometheus Counter는 단조 증가만 반영한다(`set_counter`). 맵 리셋 후 재정렬 동작을 바꾸면 notes에 명시.

### 셸 스크립트
- `set -eu`(setup) / `set -u`+`|| true`(detach) 패턴 유지: attach는 실패 시 중단, detach는 무엇이 남아 있든 끝까지.
- 핀 경로는 `PIN_DIR` 변수 + `${PIN_DIR}/<name>` 형태로 쓴다(검사 스크립트가 이 형태를 해석한다).
- 인터페이스 이름은 인자로만 받는다. 하드코딩 금지.

### 신규 운영 자산
- systemd: `vantage-5g-load.service`(oneshot, `ExecStart=… load`, `RemainAfterExit=yes`, `After=sys-fs-bpf.mount`) + attach용 템플릿 유닛 `vantage-5g-attach@<iface>.service`. 바이너리·`.o` 경로는 `WorkingDirectory`로 고정(현재 `load`는 `.o`를 상대경로로 연다).
- Grafana: `dashboards/vantage-5g.json`, README §7의 PromQL을 패널로 사용, `ue_ip` 템플릿 변수.
