# Vantage-5G: Cloud-Native 5G QoS & Telemetry Orchestrator

Vantage-5G는 클라우드 네이티브 K8s 환경에서 5G 테넌트의 트래픽 대역폭을 정밀하게 제어하고, eBPF를 통해 나노초 단위의 네트워크 텔레메트리를 관측하는 하이브리드 오케스트레이터입니다.

## 🚀 Architecture: Hybrid Orchestration (V2)

과거 물리 인터페이스(`tc egress`)를 제어하던 방식에서 벗어나, 데이터 평면의 **통제(Enforcement)**와 **관측(Observation)**을 분리한 클라우드 네이티브 구조로 진화했습니다.

* **Control Plane (Enforcement):** Rust 기반의 `vantage-cli`가 K8s API를 비동기(tokio)로 타격하여, 파드의 Annotation을 조작합니다. 이는 Cilium의 `BandwidthManager` (eBPF EDT Fast-Path)를 실시간으로 제어하여 Zero-Downtime 대역폭 슬라이싱을 달성합니다.
* **Data Plane (Observation):** C 기반의 Custom eBPF 엔진(`vantage_ringbuf_edt.o`)이 파드 가상 인터페이스(veth)에 부착되어 트래픽을 스니핑하고, Ring Buffer를 통해 사용자 공간으로 텔레메트리 이벤트를 전송합니다.

---

## 📋 Prerequisites (사전 요구사항)

Vantage-5G를 구동하기 위해서는 다음 환경이 준비되어야 합니다.

1. **Kubernetes Cluster** (v1.20+)
2. **Cilium CNI** (v1.12+)
   * 🚨 **필수 설정:** Cilium ConfigMap에 대역폭 매니저가 반드시 활성화되어야 합니다.
   ```bash
   kubectl edit cm cilium-config -n kube-system
   # 아래 항목 추가 및 확인
   # data:
   #   enable-bandwidth-manager: "true"
   #   ipv4-native-routing-cidr: "10.0.0.0/8" (호스트 대역 쉼표 기입 주의)
3. Rust Toolchain (Cargo, vantage-cli 빌드용)
4. Clang / LLVM / libbpf-dev (eBPF 엔진 컴파일용)
5. **Ubuntu 24.04 이상 (Kernel ver 5.5 이상)**
   * Ubuntu 22.04의 경우 Kernel 5.5(Ubuntu 22.04.3 LTS) 이상이 필요합니다.
   ```bash
   cd vantage-5G
   bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
   ```

## Installation & Build (설치 및 빌드)
1. Control Plane (Rust CLI) 빌드
K8s API와 통신하는 컨트롤러를 빌드합니다.
```bash
git clone <repository-url>
cd vantage-5G
cargo build --release
```

2. Data Plane (eBPF Engine) 빌드
패킷을 스니핑할 eBPF 센서 코드를 컴파일합니다.
```bash
sudo clang -O2 -g -target bpf -c vantage_ringbuf_edt.c -o vantage_ringbuf_edt.o
```

## Usage (사용법)
`vantage-cli`는 K8s 인증서(`~/.kube/config`)를 사용하여 API 서버와 통신합니다. (대역폭 제어 명령어는 sudo가 필요하지 않습니다.)

1. 대역폭 슬라이싱 (QoS 제어)
특정 5G 테넌트(Pod)의 Egress 대역폭을 지정된 Mbps로 즉각 제한합니다.
```bash
# 사용법: ./target/release/vantage-5G set --pod <POD_NAME> --bw-mbps <LIMIT>
./target/release/vantage-5G set --pod iperf-server-a --bw-mbps 10
```
검증: `kubectl describe pod iperf-server-a | grep egress-bandwidth`

2. 대역폭 정책 해제
부여된 대역폭 제한을 해제하여 트래픽을 전속력(Fast-Path)으로 복구합니다.
```bash
./target/release/vantage-5G reset --pod iperf-server-a
```

3. 텔레메트리 관측소 가동 (Monitor)
eBPF Ring Buffer에서 쏟아지는 나노초 단위의 트래픽 이벤트와 지연 시간(Delay)을 수신합니다. (커널 메모리 직접 접근을 위해 `sudo` 권한이 필수적입니다.)
```bash
sudo ./target/release/vantage-5G monitor
```
참고: Monitor 데몬 구동 시 백그라운드에서 Prometheus Metric Exporter가 함께 가동됩니다.

