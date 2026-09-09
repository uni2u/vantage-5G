# Vantage-5G

Per-UE **RX/TX bandwidth control** for services sitting behind a black-box 5G Core (특화망 / private 5G).
Enforcement runs at the **service node**, via **XDP (RX policer)** and **tc-bpf + EDT (TX pacer)**.
Policy is set **manually by an administrator** through a small Rust CLI writing directly into BPF maps.
Metrics are exported to Prometheus for a dashboard.

---

## 1. What this is

- The 5G Core (UPF+gNB) enforces radio-side QoS as 3GPP prescribes, but in private-5G deployments the downlink QER is usually only coarse aggregate. Vantage adds an **application-aware per-UE shaping layer at the service node**, upstream of the UPF, so DL is actually well-behaved and the service also has an autonomous RX policy point.
- The controlled path is:

```
[UE] -- radio -- [gNB] -- N3 -- [5G Core / UPF (black-box)] -- N6 --> [service node N6 NIC] --> [service app]
                                                                              ▲
                                                                              │
                                                             Vantage attaches here.
                                                             XDP on ingress = UL (RX).
                                                             tc-bpf on egress = DL (TX).
```

- Development testbed = **UE emulator + UERANSIM (gNB) + Open5GS (core)**. Target production = a real private-5G core; Vantage never talks to the 5G core, so swapping the testbed for a real core is a re-run of `setup.sh`, not a rewrite.

## 2. Scope (Phase 1, current)

- Identification key: **UE IPv4 address** (as seen on N6).
- Policy: `{rx_bps, tx_bps}` per UE. `tx_bps = 0` is an explicit downlink **killswitch**.
- No automation, no policy engine. An admin runs `vantage-5G set …` when they want to change something.
- Enforcement: XDP token-bucket on ingress; tc-bpf EDT pacing on egress (relies on `fq` root qdisc).
- Metrics: per-UE RX/TX bytes, packets, drops via Prometheus on port 9090.

Phase 2 (later) will extend the policy key to a 5-tuple LPM_TRIE for micro-segmentation. Not yet in this build.

## 3. Requirements

| Component | Minimum |
|---|---|
| OS | Ubuntu 22.04 / 24.04 |
| Kernel | Linux 5.15+ (BTF at `/sys/kernel/btf/vmlinux`) |
| Tools | `clang`, `llvm`, `bpftool`, `iproute2` (`tc`, `ip`), `libbpf-dev`, `libelf-dev` |
| Toolchain | Rust stable (`rustup`) |
| NIC | XDP-capable driver preferred; `xdpgeneric` used by default so any NIC works. |
| Privilege | `root` for `load`, `monitor`, `setup.sh`, `detach.sh`. `set`/`reset`/`list`/`stats` only need read/write on the BPFFS pins. |

```bash
sudo apt-get install -y build-essential clang llvm libbpf-dev libelf-dev bpftool \
    linux-tools-common linux-tools-generic pkg-config iproute2 iperf3
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## 4. Build

```bash
git clone https://github.com/uni2u/vantage-5g.git
cd vantage-5g

make check      # verifies clang / bpftool / tc / ip / BTF
make build      # produces vantage_rx_policer.o, vantage_tx_pacer.o, target/release/vantage-5G
```

Artifacts:

```
vantage_rx_policer.o      # XDP RX policer (per-UE token bucket)
vantage_tx_pacer.o        # tc-bpf egress + EDT (per-UE pacer, killswitch)
target/release/vantage-5G # Rust CLI
```

## 5. Bootstrap — one-time load and attach

Do these in order on the **service node**.

```bash
# 1) Load & pin BPF programs and maps into /sys/fs/bpf/vantage/.
sudo ./target/release/vantage-5G load

# 2) Attach the pinned programs to your N6-facing NIC.
#    Replace enp0s3 with whatever interface faces the 5G Core (N6).
sudo ./setup.sh enp0s3
```

What `setup.sh` does:

1. `tc qdisc replace dev <iface> root fq` — required for `skb->tstamp` pacing.
2. `tc qdisc add dev <iface> clsact` — hook point for the tc-bpf egress filter.
3. `ip link set dev <iface> xdpgeneric pinned /sys/fs/bpf/vantage/vantage_rx_policer`
4. `tc filter add dev <iface> egress bpf da pinned /sys/fs/bpf/vantage/vantage_tx_pacer`

## 6. Set / reset / inspect per-UE policy

```bash
# Set: UE at 10.45.1.23 gets 10 Mbps uplink admit, 20 Mbps downlink pace.
./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20

# Killswitch: block downlink to this UE entirely (uplink still policed at 10 Mbps).
./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 0

# Clear all shaping for a UE (traffic bypasses shaping).
./target/release/vantage-5G reset --ue-ip 10.45.1.23

# Dump every UE with a policy.
./target/release/vantage-5G list

# Dump per-UE counters (all UEs, or filtered).
./target/release/vantage-5G stats
./target/release/vantage-5G stats --ue-ip 10.45.1.23
```

## 7. Monitor — Prometheus exporter

```bash
sudo ./target/release/vantage-5G monitor           # binds :9090
# or a different port:
sudo ./target/release/vantage-5G monitor --port 9191
```

Exposed series (all labeled with `ue_ip`):

```
vantage_ue_rx_bytes_total       # bytes admitted by the RX policer
vantage_ue_rx_packets_total
vantage_ue_rx_drops_total       # dropped by the RX policer
vantage_ue_tx_bytes_total       # bytes paced by the TX pacer
vantage_ue_tx_packets_total
vantage_ue_tx_drops_total       # dropped by the killswitch
vantage_ue_policy_rx_bps        # configured RX cap
vantage_ue_policy_tx_bps        # configured TX cap (0 = killswitch)
```

Useful PromQL:

```promql
# realized RX throughput per UE, Mbps
rate(vantage_ue_rx_bytes_total[5s]) * 8 / 1e6

# realized TX throughput per UE, Mbps
rate(vantage_ue_tx_bytes_total[5s]) * 8 / 1e6

# RX drops per second — sign that the UE is bumping into its cap
rate(vantage_ue_rx_drops_total[10s])
```

A Grafana dashboard will land in `dashboards/` once the test bed is producing traffic; the exporter is stable and unlikely to change further.

## 8. Verification — Phase 1 completion criteria

Phase 1 is considered done when **two UEs**, each with distinct RX/TX limits, hold their configured rates **simultaneously in both directions**. Concretely, four concurrent `iperf3` sessions.

Assumption: two UEs registered through UERANSIM, IPs `10.45.1.23` (UE-A) and `10.45.1.24` (UE-B); service reachable at `SVC`.

```bash
# On the service node — set the policies.
./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20
./target/release/vantage-5G set --ue-ip 10.45.1.24 --rx-mbps  3 --tx-mbps  5

# On the service node — one iperf3 server per direction per UE.
iperf3 -s -p 5201 &   # UE-A uplink
iperf3 -s -p 5202 &   # UE-B uplink
iperf3 -s -p 5203 &   # UE-A downlink (client uses -R)
iperf3 -s -p 5204 &   # UE-B downlink (client uses -R)

# On UE-A (10.45.1.23):
iperf3 -c $SVC -p 5201 -t 30       # UL — expect ~10 Mbps
iperf3 -c $SVC -p 5203 -t 30 -R    # DL — expect ~20 Mbps

# On UE-B (10.45.1.24):
iperf3 -c $SVC -p 5202 -t 30       # UL — expect ~3 Mbps
iperf3 -c $SVC -p 5204 -t 30 -R    # DL — expect ~5 Mbps
```

Run the four client sessions **concurrently**. Pass criterion: each session settles within ±10% of its configured cap, and UE-A's traffic does not visibly disturb UE-B's rate (or vice versa).

You can watch the counters live during the test:

```bash
watch -n1 './target/release/vantage-5G stats'
```

## 9. Detach & unload

```bash
sudo ./detach.sh enp0s3                        # remove tc filter, XDP, clsact, root fq
sudo ./target/release/vantage-5G unload         # remove pinned programs & maps
```

## 10. Troubleshooting

**`skb->tstamp` seems to be ignored (TX pacing has no effect)** — the interface's root qdisc is not `fq`. `setup.sh` sets it, but if you attach manually make sure `tc qdisc show dev <iface>` prints `qdisc fq …` at root.

**`open ue_policy_map (run 'vantage-5G load' first)`** — the CLI can't find the pinned map. Run `sudo ./target/release/vantage-5G load` once per boot.

**`ip link set … xdpgeneric` succeeds but nothing hits XDP** — the interface may be a virtual link Chromium of the wrong kind. Try attaching to the physical N6 NIC directly (not a bridge or VF representor).

**RX drop counter climbs but throughput isn't shaped** — the traffic isn't going through the interface you attached to. `sudo ip -s link show dev <iface>` should show packet counts moving; `./target/release/vantage-5G stats` should show the same UE's rx_bytes rising.

**Verifier rejects the program after `make build`** — usually a kernel/BTF mismatch. `make check` verifies BTF; if you upgraded the kernel, re-run `make clean && make build` so `vmlinux.h` is regenerated for the running kernel.

**BPF map still populated after `unload`** — the `unload` command removes pins but the kernel keeps the objects alive as long as *something* references them (an attached filter, a pinned link). Run `detach.sh` first.

## 11. Files

| Path | Role |
|---|---|
| `vantage_rx_policer.c` | XDP program: per-UE token-bucket RX policer. |
| `vantage_tx_pacer.c`   | tc-bpf egress program: per-UE EDT TX pacer + killswitch. |
| `src/main.rs`          | Rust CLI: `load`, `unload`, `set`, `reset`, `list`, `stats`, `monitor`. |
| `Cargo.toml`           | Rust deps: `libbpf-rs`, `libbpf-sys`, `prometheus_exporter`, `clap`, `anyhow`. |
| `Makefile`             | `make check / build / clean`. |
| `setup.sh`             | Attach pinned programs to a NIC, set `fq` root qdisc. |
| `detach.sh`            | Undo `setup.sh`. |
| `iperf3-deployment.yaml` | Test workload (used when the service happens to run inside K8s). |
| `install_k8s_singlenode.md` | Optional single-node K8s setup notes (only if you run the service in K8s). |
| `history.md`           | Historical design log. Not required for build or operation. |

## 12. Roadmap

- Phase 2: replace `ue_policy_map` with an `LPM_TRIE` keyed on `(ue_ip, svc_ip, port, proto)` for micro-segmentation, longest-match semantics.
- Grafana dashboard JSON under `dashboards/`.
- Optional systemd unit for `load` at boot.
