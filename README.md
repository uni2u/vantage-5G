# Vantage-5G: Cloud-Native 5G QoS & Telemetry Orchestrator

Vantage-5G는 클라우드 네이티브 환경(Cilium CNI)에서 5G 테넌트의 트래픽 대역폭을 정밀하게 제어(EDT)하고, eBPF Ring Buffer를 통해 나노초 단위의 지연 시간(Delay)을 관측하는 하이브리드 오케스트레이터입니다.

## 🚀 Architecture Evolution (V1 to V2)

### V1: Node-Local TC Data Plane (Deprecated)
* **접근법:** 외부 물리 인터페이스(`enp0s8`)의 `tc egress` 관문에 커스텀 eBPF 엔진(`vantage_ringbuf_edt.o`)을 부착하여 전역(Global) 대역폭 통제 시도.
* **한계 발견 (The Cilium Wormhole):** Cilium CNI가 `bpf_redirect_neigh` 커널 함수를 호출하여 리눅스 스택(TC)을 완전히 우회(Bypass)하는 'eBPF Full-Offload Fast Path'를 독점하고 있음을 실증(Single Packet Sniper 전술 및 Guillotine 하드 드롭 검증 완료).

### V2: Cloud-Native Hybrid Orchestration (Current)
데이터 평면의 통제권(Enforcement)과 관측망(Observation)을 분리(Decoupling)한 마이크로서비스 아키텍처로 진화했습니다.
* **Control Plane (Enforcement):** `vantage-cli`는 `kube-rs` 비동기 클라이언트를 활용하여 Kubernetes API Server를 직접 타격합니다. 파드의 Annotation(`kubernetes.io/egress-bandwidth`)을 동적 패치(Patch)하여 Cilium의 내장 Bandwidth Manager(EDT)를 깨우는 방식으로 Zero-Downtime 대역폭 슬라이싱을 달성합니다.
* **Data Plane (Observation):** [예정] 순수 텔레메트리 수집으로 경량화된 Custom BPF 엔진을 트래픽이 웜홀로 진입하기 직전인 파드 가상 인터페이스(`lxc...`)에 전진 배치하여 메트릭을 수집하고 Prometheus Endpoint로 노출합니다.

## 🛠️ Components
* `src/main.rs`: 비동기(tokio) 기반 K8s API 오케스트레이터 및 Ring Buffer 메트릭 수집 데몬 (Rust).
* `vantage_ringbuf_edt.c`: 인-파드(In-Pod) 트래픽 스니핑 및 텔레메트리 추출용 eBPF 엔진 (C).
