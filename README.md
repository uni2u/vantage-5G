# Vantage-5G: Hybrid Cloud-Native Network Telemetry & Orchestrator

`Vantage-5G`는 클라우드 네이티브 5G 핵심 망(5GC) 및 대규모 AI 클러스터 환경을 위한 **Rust-Native eBPF 기반 하이브리드 네트워크 오케스트레이터 및 심층 텔레메트리 엔진**입니다. 

레거시 호스트 툴체인(`bpftool`, `tc` CLI)의 버전 파편화 제약을 완전히 파쇄하고, 리눅스 커널 시스템 콜 계층을 직접 타격하는 `libbpf-rs` 아키텍처를 채택하여 인프라의 휘발성(Ephemerality)을 극복하고 고차원적인 자율 제어 평면(Control Plane)을 제공합니다.

---

## 🏗️ 아키텍처 개요 (Architecture Overview)

Vantage-5G는 고성능 데이터 평면(Data Plane)과 지능형 제어 평면(Control Plane)이 결합된 하이브리드 구조를 가집니다.

* **Data Plane (eBPF Kernel Space)**
  * `vantage_telemetry_sniffer`: `tc(traffic control) clsact` 훅에 용접되어 Line-rate 성능 저하 없이(Zero-Overhead) 패킷의 메트릭(IP, 길이 등)을 추적하여 고속 `Ring Buffer`로 전달합니다.
  * `vantage_tcp_retransmit`: 커널 내부 `tcp_retransmit_skb` 함수에 `fentry` 형태로 결속되어 네트워크의 미세 혼잡 및 유실 신호를 $O(1)$ 성능으로 Per-CPU Array 맵에 누적합니다.
* **Control Plane (Rust User Space)**
  * `libbpf-rs` 엔진을 내장하여 컴파일된 eBPF 객체를 커널에 자율 주입하며, 멱등성(Idempotency)이 보장된 가상 파일시스템(BPFFS) 관리를 수행합니다.
  * 시분할 비동기 런타임(`Tokio`)을 기반으로 고속 패킷 스트림 청취와 Per-CPU 카운터 맵 스크래핑을 병렬로 집행합니다.
  * `kube-rs` 체인을 장착하여 Kubernetes API 레이어에서 파드의 이벤트를 추적하고 대역폭(Cilium EDT)을 선언적으로 패치합니다.

---

## 📌 요구 사항 (Prerequisites)

시스템을 빌드하고 커널에 안전하게 결속하기 위해 아래 환경이 요구됩니다.

* **OS:** Linux Kernel 5.4 이상 (BTF 및 `fentry` 트램펄린 활성화 필수, e.g., Ubuntu 22.04+, Rocky Linux 8.9+ with modern kernel)
* **CNI:** Cilium CNI 가동 환경 (K8s Pod 대역 통제용)
* **Dependencies:** `libbpf`, `libelf`, `Clang/LLVM` (eBPF 컴파일용)
* **Language:** Rust 1.96+ (Edition 2024 규격 준수)

---

## 🛠️ 설치 및 컴파일 (Installation & Setup)

### 1. 호스트 OS 네이티브 개발 패키지 주입
리눅스 커널 소스 및 로우레벨 FFI 바인딩을 위해 필요한 라이브러리를 먼저 설치합니다.

```bash
sudo apt-get update && sudo apt-get install -y \
    libbpf-dev \
    libelf-dev \
    clang \
    llvm \
    build-essential
```

---

## 저장소 클론 및 eBPF 바이트코드 준비

저장소를 클론한 후, 작성된 eBPF C 코드를 컴파일하여 바이트코드(`vantage_ringbuf_edt.o`)를 프로젝트 루트 디렉토리에 위치시킵니다.

```bash
git clone [https://github.com/uni2u/vantage-5G.git](https://github.com/uni2u/vantage-5G.git)
cd vantage-5G

# (참고) eBPF 컴파일 타겟 바이너리가 루트에 존재해야 Rust 엔진이 로드할 수 있습니다.
ls -l vantage_ringbuf_edt.o
```

---

## Rust 제어 평면 빌드

Rust 2024 에디션 최적화 사양으로 바이너리를 컴파일합니다.

```bash
cargo build --release
```

---

## 실전 가동 가이드 (Usage Guide)

멀티 노드 가상화 환경(VM1: 단말 사격기, VM2: 관제탑 및 5GC Pod 구동 호스트)에서의 실전 가동 시퀀스입니다.

### Step 1. 크로스 노드 라우팅 개통 (사격기 VM1 설정)

타겟 Pod의 가상 Overlay CIDR 대역(`10.0.0.0/24`) 패킷이 외부 인터넷 망으로 탈선하여 증발하는 것을 방지하기 위해, 트래픽을 발사하는 외부 VM1 호스트에 정적 이정표를 각인시킵니다.

```bash
# [VM1 터미널] 10.0.0.x 패킷의 넥스트 홉을 VM2 Host IP로 강제 족쇄 주입
sudo ip route add 10.0.0.0/24 via <VM2_HOST_IP> dev <인터페이스_명칭>

# 예시:
sudo ip route add 10.0.0.0/24 via 192.168.56.10 dev enp0s8
```

### Step 2. 무상태성 관제탑 데몬 가동 (관제탑 VM2 실행)

커널 시스템 콜 직접 제어(`sys_bpf`)를 위해 반드시 `sudo` 권한으로 `monitor` 서브커맨드를 실행합니다. 가동 시 과거의 유령 BPFFS 객체들을 자동 소각(Idempotent Cleanup)하며 청정 구동됩니다.

```bash
# [VM2 터미널 - 창 1]
# 1. 기존 데이터 평면 훅 제거 (ready.sh의 클린업 로직 강제 활용)
sudo tc qdisc del dev $TARGET_DEV clsact 2>/dev/null || true

# 2. Rust 제어 평면 모니터 기동 (BPFFS 청정화 및 링버퍼/카운터 맵 재생성)
sudo ./target/release/vantage-5G monitor
```

가동 성공 시 9090 포트에 Prometheus 익스포터 런타임이 동시 개방됩니다.

### Step 3. 인프라 스텁 자율 정렬 스크립트 집행 (관제탑 VM2 실행)

K8s Pod가 재시작되어 IP와 `iflink` 장치명이 무작위로 변경되어도, 이를 자율 추적하여 eBPF 핀을 인터페이스 차선에 재용접하고 파드 내부 `iperf3` 서버 소켓을 영속 가동해 주는 헬퍼 스크립트를 실행합니다.

```bash
# [VM2 터미널 - 창 2]
./ready.sh
```

### Step 4. 실전 트래픽 저격 사격 및 관측

모든 라인업이 정렬되었습니다. VM1 터미널로 이동하여 새로 할당된 Pod IP를 저격하여 역방향 고속 트래픽을 발사합니다.

```bash
# [VM1 터미널] 새롭게 검출된 진짜 Pod IP로 사격
iperf3 -c <검출된_POD_IP> -R

# 예시:
iperf3 -c 10.0.0.113 -R
```

### 관제 데이터 피드 확인

트래픽이 관통하는 순간 `vantage-5G monitor` 콘솔창에 고속 패킷 수집 로그와 커널 내부 TCP 재전송 미세 신호가 하이브리드로 교차 출력됩니다.

```plaintext
[📡 TELEMETRY] Pod IP: 192.168.56.20   | 📦 크기:   66 Bytes | 메트릭 적치 완료
[📡 TELEMETRY] Pod IP: 192.168.56.20   | 📦 크기:   70 Bytes | 메트릭 적치 완료
[🚨 KERNEL INFRA] 커널 미세 신호 포착 -> 누적 TCP 재전송 총합: 1 회
```

### Prometheus Metrics Endpoint

* 주소: `http://<VM2_HOST_IP>:9090/metrics`
* 제공 메트릭:
  * `vantage_tenant_tx_bytes_total`: 테넌트(Pod IP)별 누적 전송 바이트 수 (Counter)
  * `vantage_tenant_tx_packets_total`: 테넌트(Pod IP)별 누적 전송 패킷 수 (Counter)
  * `vantage_node_tcp_retransmit_total`: 커널 글로벌 누적 TCP 재전송 수 (Gauge)

---

## CLI 명령어 명세 (Command Reference)

Vantage-5G는 Prometheus 모니터링 외에도 K8s 제어 평면을 직접 통제하는 오케스트레이션 명령을 지원합니다.

* `monitor`: 하이브리드 eBPF 수집 엔진 및 메트릭 서버 기동.
* `set`: 특정 네임스페이스의 파드 대역폭(Cilium EDT)을 선언적으로 제한.
```bash
# 사용법: ./target/release/vantage-5G set --pod <POD_NAME> --bw-mbps <LIMIT>
./target/release/vantage-5G set --pod iperf-server-xxx --namespace default --bw-mbps 100

# 검증
kubectl describe pod iperf-server-a | grep egress-bandwidth
```
* `reset`: 주입된 파드의 대역폭 제어 정책을 투명하게 해제.
```bash
./target/release/vantage-5G reset --pod iperf-server-xxx --namespace default
```

---

## 🚀 Roadmap & Future Work: Agentic AI & MCP Integration (TODO)

본 프로젝트의 최종 진화 목적지는 인간 엔지니어의 개입 없이, 커널 심층 미세 신호를 상위 AI 가 실시간 추론하여 인프라를 자율 방어하는 **'Zero-Touch 자율 네트워킹 제어 평면'**을 완성하는 것입니다. 이를 위해 아래 고도화 작업을 주도적으로 진행하고 있으며, 오픈소스 기여를 환영합니다.

### 🟥 Task 1: Rust-Native Model Context Protocol (MCP) Host/Client Bridge 구현
* **목적:** 상위 대형 언어 모델(LLM) 및 AI 에이전트(NRAG 두뇌 레이어)가 `vantage-5G` 인프라를 자신의 도구(Tools) 및 리소스(Resources)로 직접 인식하고 조작할 수 있는 표준 규격 통로 개방.
* **상세 설계:**
  * JSON-RPC 2.0 기반의 MCP 비동기 통신 규격 프로토콜 스택을 Rust 매니저 내부에 이식.
  * AI가 시스템 콜 계층으로 진입할 수 있도록 `vantage-5G set/reset` 명령을 MCP Tool로 랩핑(Wrapping) 바인딩.

### 🟥 Task 2: 슬라이딩 윈도우 기반 의미론적 문맥 응축 엔진 (Semantic Aggregator) 이식
* **목적:** 원시 패킷 단위의 Ring Buffer 이벤트 플러딩(Event Flooding)으로 인한 제어 평면 I/O 병목 및 AI Context Window 고갈을 원천 차단.
* **상세 설계:**
  * eBPF 콜백은 백그라운드에서 원자적 카운터만 초고속 누적하고, 유저 공간의 Tokio 타이머 스레드가 1초 주기로 데이터를 덤프.
  * 1초간 수집된 처리량(Throughput), pps, 평균 패킷 크기 및 `fentry` 기반 TCP 재전송 누적 델타 값을 융합하여 의미론적 고차원 JSON Context 가공 엔진 구축.

### 🟥 Task 3: Closed-Loop 자율 통제 방어 알고리즘 실증
* **목적:** AI 가 미세 신호를 기반으로 네트워크 혼잡(Congestion)과 DoS 등 악성 공격(Anomaly)을 구분하여 대역폭 교살 정책을 실시간 피드백 루프로 집행.
* **상세 설계:**
  * MCP 리소스를 통해 JSON 문맥을 실시간 구독 중인 Agentic AI가 "TCP Retransmit 카운트 급증 + pps 폭발" 감지 시, 배후 라우팅 유실 혹은 내부 침해 자산의 데이터 탈취 징후로 정밀 추론.
  * AI가 직접 MCP 도구를 타격하여 해당 파드의 대역폭을 50 Mbps로 긴급 압착(Throttling) 조치하는 폐루프(Closed-Loop) 자동화 검증.

---

## 📡 Current Status & Verified Benchmarks (Context Anchor)

1. **L3/L4 Data Plane 무결성 검증 완료:** * 멀티 노드 가상화 환경에서 Cross-Node 라우팅 테이블 동기화 완료 (`sudo ip route add 10.0.0.0/24 via <VM2_IP> dev <Dev>`).
   * VM1 사격기에서 타겟 파드로의 기저 ICMP 통신 무결성 및 L4 `iperf3` 역방향 소켓 통로 개통 완료.
2. **eBPF-Rust 하이브리드 수집 매니저 실증 완료:**
   * 호스트 `bpftool` 제약을 우회하여 `libbpf-rs`를 이용한 `fentry/tcp_retransmit_skb` 커널 트램펄린 자율 용접 성공.
   * `vantage_tenant_tx_bytes_total` 및 `vantage_tenant_tx_packets_total` 메트릭을 통해 평균 66 Bytes 대역의 순수 TCP ACK 제어 스트림 포착 성공 및 9090 포트 프로메테우스 익스포터 정상 유출 확인.
3. **Control Plane 제어 집행력 실증 완료:**
   * `vantage-5G set --bw-mbps 100` 명령을 통한 K8s API 패치 무결성 입증.
   * Cilium EDT(Earliest Departure Time) 매커니즘이 발동하여 VM1 벤치마크 결과가 대역폭 상한선인 `97.9 Mbits/sec` 근처에서 칼같이 셰이핑(Capping)되는 데이터 무결성 물리적 확인 완료.
  
