# Vantage-5G

**Vantage-5G** is a Rust-based manual QoS control and telemetry CLI for service-side bandwidth control in black-box 5G Core environments.

This project assumes that the 5G Core is operated as a separate domain and cannot be modified or directly connected to by the service operator. In such an environment, Vantage-5G provides a way for a network operator to control **service-to-UE bandwidth** from the Kubernetes service domain, without replacing Cilium or directly modifying Cilium-managed BPF maps.

## 1. Motivation

If the 5G Core and service workloads are deployed in the same Kubernetes, Multus, and Cilium networking domain, Cilium's native bandwidth management can be used directly.

However, the target environment for this project is different:

```text
[UE / Device]
     |
[5G Core / Open5GS or similar]   <-- black-box domain
     |
[Service Kubernetes Cluster]
     |
[Cilium CNI]
     |
[Service Pod]
```

In this environment:

* The 5G Core is not controlled by the service operator.
* The 5G Core Kubernetes cluster, Multus configuration, CNI, UPF, QFI, and 5QI policy plane are not accessible.
* Only the service Kubernetes domain is controllable.
* Cilium owns the Kubernetes service datapath.
* Vantage-5G does not replace Cilium.
* Vantage-5G provides an operator-side CLI to adjust bandwidth limits through Cilium-compatible mechanisms.

The initial goal is to validate whether a network operator can manually control the bandwidth of traffic in the following direction:

```text
[Service Pod] -> [5G Core / UPF path] -> [UE]
```

## 2. Current Status

Vantage-5G is currently a **manual CLI PoC**.

Implemented commands:

```text
set
reset
monitor
```

Current capabilities:

* Set Pod egress bandwidth through Kubernetes annotation.
* Reset Pod egress bandwidth annotation.
* Load an eBPF object with `libbpf-rs`.
* Attach an fentry program to observe TCP retransmission events.
* Read packet telemetry through a BPF ring buffer.
* Export Prometheus metrics on port `9090`.

Not implemented yet:

* Automatic closed-loop QoS control.
* UE-aware per-device bandwidth control.
* Service-name-based bandwidth control.
* MCP tool integration.
* AI-agent-based policy decision.
* Direct update of custom QoS BPF maps from the CLI.
* Automatic eBPF object compilation from Cargo.

## 3. Architecture

### 3.1 Current PoC Architecture

```text
+-----------------------------+
| Network Operator            |
+--------------+--------------+
               |
               | manual CLI
               v
+-----------------------------+
| vantage-5G                  |
| - set                       |
| - reset                     |
| - monitor                   |
+--------------+--------------+
               |
               | Kubernetes API patch
               v
+-----------------------------+
| Kubernetes Pod Annotation   |
| kubernetes.io/egress-bandwidth
+--------------+--------------+
               |
               | interpreted by
               v
+-----------------------------+
| Cilium Bandwidth Manager    |
| eBPF / EDT enforcement      |
+--------------+--------------+
               |
               v
[Service Pod] ---> [5G Core] ---> [UE]
```

### 3.2 Telemetry Path

```text
vantage-5G monitor
    |
    | loads
    v
vantage_ringbuf_edt.o
    |
    +--> tc packet telemetry ring buffer
    |
    +--> fentry/tcp_retransmit_skb counter
    |
    v
Prometheus metrics endpoint
http://0.0.0.0:9090/metrics
```

## 4. Requirements

### 4.1 Recommended Environment

This README assumes a real VM or bare-metal Kubernetes environment.

Do not use Kind for bandwidth enforcement testing. Cilium bandwidth enforcement is not suitable for nested network namespace environments such as Kind.

Recommended environment:

| Component          | Recommended                               |
| ------------------ | ----------------------------------------- |
| OS                 | Ubuntu 22.04 or Ubuntu 24.04              |
| Kernel             | Linux 5.4+                                |
| Kubernetes         | Existing cluster or kubeadm-based cluster |
| CNI                | Cilium                                    |
| Cilium feature     | Bandwidth Manager enabled                 |
| Rust               | stable toolchain                          |
| eBPF compiler      | clang/llvm                                |
| Runtime permission | root required for `monitor`               |

### 4.2 Required Tools

Install the basic build and eBPF dependencies:

```bash
sudo apt-get update

sudo apt-get install -y \
  build-essential \
  clang \
  llvm \
  libbpf-dev \
  libelf-dev \
  linux-tools-common \
  linux-tools-generic \
  pkg-config \
  curl \
  git \
  iproute2 \
  iperf3
```

Install Rust:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

rustc --version
cargo --version
```

Install Kubernetes client tools if they are not already installed:

```bash
sudo apt-get install -y apt-transport-https ca-certificates gnupg
```

Install Helm if needed:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

Verify Kubernetes access:

```bash
kubectl get nodes
kubectl get pods -A
```

## 5. Cilium Bandwidth Manager

Vantage-5G currently uses Cilium-compatible Pod bandwidth annotations.

Enable Cilium Bandwidth Manager during Cilium installation:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.19.5 \
  --set bandwidthManager.enabled=true
```

If Cilium is already installed, enable Bandwidth Manager with:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --version 1.19.5 \
  --reuse-values \
  --set bandwidthManager.enabled=true

kubectl -n kube-system rollout restart ds/cilium
```

Verify Cilium status:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
```

Verify Bandwidth Manager:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep BandwidthManager
```

Expected example:

```text
BandwidthManager:       EDT with BPF [eth0]
```

## 6. Clone and Build Vantage-5G

Clone the repository:

```bash
git clone https://github.com/uni2u/vantage-5G.git
cd vantage-5G
```

Check the local build environment:

```bash
make check
```

Build both the eBPF object and the Rust CLI:

```bash
make build
```

If `make build` fails while reading `/sys/kernel/btf/vmlinux`, run it with sufficient privileges or check BTF availability:

```bash
ls -lh /sys/kernel/btf/vmlinux
```

Verify the build artifacts:

```bash
ls -lh vmlinux.h
ls -lh vantage_ringbuf_edt.o
ls -lh target/release/vantage-5G
```

Verify the binary:

```bash
./target/release/vantage-5G --help
```

Expected commands:

```text
set
reset
monitor
```

The current `monitor` command expects `vantage_ringbuf_edt.o` in the project root. This file is generated by `make build`.

## 7. Deploy the Test Service Pod

Deploy the provided iperf3 server:

```bash
kubectl apply -f iperf3-deployment.yaml
```

Check the Pod:

```bash
kubectl get pods -l app=iperf-server -o wide
```

Get the Pod name and IP:

```bash
POD_NAME=$(kubectl get pods -l app=iperf-server -o jsonpath='{.items[0].metadata.name}')
POD_IP=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.podIP}')

echo "POD_NAME=$POD_NAME"
echo "POD_IP=$POD_IP"
```

## 8. Run Vantage Monitor

The monitor command requires root privileges.

Run it in terminal 1:

```bash
sudo ./target/release/vantage-5G monitor
```

The monitor command performs the following actions:

* Starts a Prometheus exporter on port `9090`.
* Loads `vantage_ringbuf_edt.o`.
* Pins BPF maps under `/sys/fs/bpf`.
* Attaches `fentry/tcp_retransmit_skb`.
* Polls the BPF ring buffer.
* Exports packet and TCP retransmission metrics.

Verify the metrics endpoint from another terminal:

```bash
curl http://127.0.0.1:9090/metrics | grep vantage
```

Expected metric names:

```text
vantage_tenant_tx_bytes_total
vantage_tenant_tx_packets_total
vantage_node_tcp_retransmit_total
```

If accessing from another machine:

```bash
curl http://<NODE_IP>:9090/metrics | grep vantage
```

## 9. Attach the Packet Sniffer to the Pod Interface

Run the helper script in terminal 2:

```bash
chmod +x ready.sh
./ready.sh
```

The script performs the following:

* Finds the `iperf-server` Pod.
* Reads the Pod-side `eth0` iflink.
* Resolves the host-side veth or lxc interface.
* Adds a `clsact` qdisc.
* Attaches the pinned `vantage_telemetry_sniffer` program to ingress and egress.
* Starts an iperf3 server loop inside the Pod.

Check that the tc filter is attached:

```bash
tc qdisc show
tc filter show dev <TARGET_DEV> ingress
tc filter show dev <TARGET_DEV> egress
```

Replace `<TARGET_DEV>` with the interface printed by `ready.sh`.

## 10. Test Baseline Throughput

From a client that can reach the service Pod IP, run:

```bash
iperf3 -c "$POD_IP" -R
```

The `-R` option means reverse mode. The remote iperf3 server sends traffic back to the client.

This is the important direction for this project:

```text
Service Pod -> Client / UE
```

While traffic is running, check the Vantage monitor terminal.

You should see telemetry logs similar to:

```text
[TELEMETRY] Pod IP: ... | size: ... Bytes | metric updated
```

Also verify Prometheus metrics:

```bash
curl http://127.0.0.1:9090/metrics | grep vantage_tenant_tx
```

## 11. Set Bandwidth Limit

Use the `set` command to apply an egress bandwidth limit to the service Pod.

Example: limit the service Pod egress bandwidth to 100 Mbps.

```bash
./target/release/vantage-5G set \
  --pod "$POD_NAME" \
  --namespace default \
  --bw-mbps 100
```

Short option form:

```bash
./target/release/vantage-5G set -p "$POD_NAME" -n default -b 100
```

Verify the annotation:

```bash
kubectl get pod "$POD_NAME" -o jsonpath='{.metadata.annotations.kubernetes\.io/egress-bandwidth}'
echo
```

Expected output:

```text
100M
```

Run iperf3 again:

```bash
iperf3 -c "$POD_IP" -R
```

The measured throughput should be close to the configured bandwidth limit, depending on kernel, Cilium configuration, routing mode, node device, and test path.

## 12. Reset Bandwidth Limit

Remove the bandwidth annotation:

```bash
./target/release/vantage-5G reset \
  --pod "$POD_NAME" \
  --namespace default
```

Short option form:

```bash
./target/release/vantage-5G reset -p "$POD_NAME" -n default
```

Verify that the annotation is removed:

```bash
kubectl get pod "$POD_NAME" -o jsonpath='{.metadata.annotations.kubernetes\.io/egress-bandwidth}'
echo
```

Run iperf3 again:

```bash
iperf3 -c "$POD_IP" -R
```

The throughput should no longer be constrained by the previously configured Vantage-5G bandwidth limit.

## 13. Prometheus Integration

Vantage-5G exposes metrics on:

```text
http://<NODE_IP>:9090/metrics
```

Example Prometheus scrape configuration:

```yaml
scrape_configs:
  - job_name: "vantage-5g"
    scrape_interval: 1s
    static_configs:
      - targets:
          - "<NODE_IP>:9090"
```

Useful PromQL queries:

Throughput in Mbps:

```promql
rate(vantage_tenant_tx_bytes_total[5s]) * 8 / 1000000
```

Packets per second:

```promql
rate(vantage_tenant_tx_packets_total[5s])
```

TCP retransmission increase over 30 seconds:

```promql
increase(vantage_node_tcp_retransmit_total[30s])
```

Scrape health:

```promql
up{job="vantage-5g"}
```

Grafana should be connected after Prometheus scraping and PromQL validation are confirmed.

## 14. CLI Reference

### 14.1 `set`

Set egress bandwidth for a Pod.

```bash
./target/release/vantage-5G set \
  --pod <POD_NAME> \
  --namespace <NAMESPACE> \
  --bw-mbps <LIMIT_MBPS>
```

Example:

```bash
./target/release/vantage-5G set \
  --pod iperf-server-xxxxx \
  --namespace default \
  --bw-mbps 100
```

This patches the following Pod annotation:

```text
kubernetes.io/egress-bandwidth: "100M"
```

### 14.2 `reset`

Remove egress bandwidth control from a Pod.

```bash
./target/release/vantage-5G reset \
  --pod <POD_NAME> \
  --namespace <NAMESPACE>
```

Example:

```bash
./target/release/vantage-5G reset \
  --pod iperf-server-xxxxx \
  --namespace default
```

### 14.3 `monitor`

Start the eBPF telemetry and Prometheus exporter.

```bash
sudo ./target/release/vantage-5G monitor
```

The command expects:

```text
vantage_ringbuf_edt.o
```

to exist in the project root.

## 15. Troubleshooting

### 15.1 `vantage_ringbuf_edt.o` not found

Build the eBPF object and Rust CLI:

```bash
make build
```

Verify the object file:

```bash
ls -lh vantage_ringbuf_edt.o
```

If `make build` fails, check required tools:

```bash
make check
```

### 15.2 `K8s connection failed`

Check kubeconfig:

```bash
kubectl get nodes
echo "$KUBECONFIG"
```

If needed:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

### 15.3 Bandwidth limit does not apply

Check Cilium Bandwidth Manager:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep BandwidthManager
```

Check the Pod annotation:

```bash
kubectl get pod "$POD_NAME" -o yaml | grep -A5 annotations
```

Check Cilium bandwidth state:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf bandwidth list
```

### 15.4 `ready.sh` cannot find the Pod

Check that the iperf3 Pod exists:

```bash
kubectl get pods -l app=iperf-server -o wide
```

If no Pod exists:

```bash
kubectl apply -f iperf3-deployment.yaml
```

### 15.5 No telemetry events

Check that `monitor` is running:

```bash
curl http://127.0.0.1:9090/metrics | grep vantage
```

Check that `ready.sh` attached the tc filter to the correct interface.

```bash
tc qdisc show
```

Check BPF pin paths:

```bash
sudo ls -l /sys/fs/bpf/vantage
sudo ls -l /sys/fs/bpf/tc/globals
```

### 15.6 Permission denied

Run monitor with root privileges:

```bash
sudo ./target/release/vantage-5G monitor
```

## 16. Known Limitations

Current limitations:

* Bandwidth control is Pod-based, not UE-based.
* `set/reset` currently use Kubernetes Pod annotations.
* The CLI does not directly update custom eBPF bandwidth maps.
* The CLI does not yet support service-level abstraction.
* The CLI does not yet support automatic policy decisions.
* The eBPF object is built through `make build`, but Cargo does not yet build it automatically.
* `ready.sh` is a PoC helper script and assumes an `iperf-server` Pod.
* Cilium remains the datapath authority.
* Vantage-5G should not directly compete with or replace Cilium.
* Direct manipulation of Cilium-managed BPF maps is treated as experimental and should not be used as the stable control path.

## 17. Design Notes

Vantage-5G is intentionally designed as a Cilium-compatible auxiliary tool.

The stable control path is:

```text
Vantage CLI
  -> Kubernetes API
  -> Pod annotation
  -> Cilium Bandwidth Manager
  -> eBPF / EDT enforcement
```

The experimental control path is:

```text
Vantage CLI
  -> custom eBPF map
  -> custom TC/EDT program
```

The experimental path is not the default because Cilium owns the Kubernetes datapath, BPF map lifecycle, endpoint identity, and datapath reconciliation.

## Future Work

Planned directions:

* Service-level QoS command:

```bash
vantage-5G set-service \
  --service video \
  --namespace default \
  --bw-mbps 20
```

* UE-aware QoS policy model:

```bash
vantage-5G apply-policy \
  --ue-ip 10.45.1.23 \
  --service video \
  --profile premium
```

* Prometheus-based QoS validation.
* Grafana dashboard.
* MCP tool/resource integration.
* Semantic metric aggregation.
* AI-agent-based closed-loop QoS control.
* Cargo-integrated eBPF build pipeline, such as `build.rs` or `libbpf-cargo`.
* Safer and more robust interface attachment logic.

## Cleanup

Remove the test deployment:

```bash
kubectl delete -f iperf3-deployment.yaml
```

Remove tc qdisc from the target interface if needed:

```bash
sudo tc qdisc del dev <TARGET_DEV> clsact
```

Remove pinned BPF objects if needed:

```bash
sudo rm -rf /sys/fs/bpf/vantage
sudo rm -f /sys/fs/bpf/tc/globals/telemetry_rb
sudo rm -f /sys/fs/bpf/tc/globals/tcp_retransmit_counter
```

## Project Summary

Vantage-5G is a manual Rust CLI PoC for service-side QoS control in black-box 5G Core environments.

It does not replace Cilium.

It uses Cilium-compatible bandwidth control as the stable path and provides eBPF telemetry for future closed-loop QoS automation.
