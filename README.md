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
- Policy: `{rx_bps, tx_bps}` per UE. `tx_bps = 0` is an explicit downlink **killswitch**; `rx_bps = 0` means uplink **uncapped** (not blocked). The two zeros are deliberately asymmetric: `set --rx-mbps 0 --tx-mbps 0` blocks downlink only.
- No automation, no policy engine. An admin runs `vantage-5G set …` when they want to change something.
- Enforcement: XDP token-bucket on ingress; tc-bpf EDT pacing on egress (relies on `fq` root qdisc).
- Metrics: per-UE RX/TX bytes, packets, drops via Prometheus on port 9090.

Phase 2 (later) will extend the policy key to a 5-tuple LPM_TRIE for micro-segmentation. Not yet in this build.

## 3. Requirements

| Component | Minimum |
|---|---|
| OS | Ubuntu 22.04 / 24.04 |
| Kernel | Linux 5.15+ (BTF at `/sys/kernel/btf/vmlinux`) |
| Tools | `clang`, `llvm`, `bpftool` (from `linux-tools-$(uname -r)`), `iproute2` (`tc`, `ip`), `libbpf-dev`, `libelf-dev`, `zlib1g-dev` |
| Toolchain | Rust stable (`rustup`) |
| NIC | XDP-capable driver preferred; `xdpgeneric` used by default so any NIC works. |
| Privilege | Every `vantage-5G` subcommand (`load`, `unload`, `set`, `reset`, `list`, `stats`, `monitor`) needs root: the pins under `/sys/fs/bpf` are root-only. `setup.sh` / `detach.sh` run as root or as a user with `sudo` rights (they call `sudo` themselves). `make build` runs as a normal user. |

`bpftool` is required by both `make build` (generates `vmlinux.h`) and `setup.sh`. On Ubuntu 22.04 **and** 24.04 there is no installable `bpftool` package (`apt install bpftool` fails with "has no installation candidate"); `/usr/sbin/bpftool` comes from `linux-tools-common` and is only a wrapper that needs the tools package of the **running** kernel, `linux-tools-$(uname -r)`. The same command works on both releases:

```bash
sudo apt-get install -y build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config \
    linux-tools-common "linux-tools-$(uname -r)" iproute2 iperf3
bpftool version        # must print a version, not "WARNING: bpftool not found for kernel ..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

After a kernel upgrade and reboot, install `linux-tools-$(uname -r)` again for the new kernel (`linux-tools-generic` only tracks the newest generic kernel, which may not be the one running). `make check` checks that `bpftool version` actually runs (not only that a `bpftool` exists on `PATH`).

**Memory and CPU count.** `load` creates four maps. The three per-UE state maps (`rx_state_map`, `tx_tstamp_map`, `ue_stats_map`) are `LRU_HASH` with 16384 entries each; LRU maps cannot be allocated lazily, so all of it — about **4.5 MiB** of kernel memory in total (the `memlock` sum in `bpftool map show` on 6.8; the 5.15 kernel reports a smaller estimate, about 1.5 MiB) — is allocated at `load`, whatever the number of UEs. `ue_policy_map` is a `HASH` of 1024 entries (at most 1024 UEs with a policy; the 1025th `set` fails). On kernels before 6.16 (Ubuntu 22.04's 5.15 and 24.04's 6.8) each CPU that touches an LRU map takes 128 entries for itself, so on a server with **more than 128 CPUs** (`nproc`) active UEs' state can be evicted even with few UEs (a UE then briefly gets a full RX bucket or loses its TX backlog). Up to 128 CPUs, or on 6.16+, this does not happen.

## 4. Build

```bash
git clone https://github.com/uni2u/vantage-5g.git
cd vantage-5g

make check      # verifies clang / tc / ip / BTF, and that `bpftool version` actually runs
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

0. Pre-flight: refuses (exit 3, nothing changed) if the NIC already has an XDP program in native/offload mode, a generic XDP program that is not Vantage's, a non-Vantage egress filter at pref 1, or a classic `ingress` qdisc. Attached programs are identified by id against the pinned programs (`bpftool prog show pinned`), or by their kernel name via `bpftool prog show id N` (a Vantage program left from an earlier `load`), so this also works with iproute2 5.15 (Ubuntu 22.04), which prints no program names. `bpftool` is required: without a working one `setup.sh` exits 2 before changing anything (install `linux-tools-$(uname -r)`, see §3).
1. `tc qdisc replace dev <iface> root fq` — required for `skb->tstamp` pacing.
2. `tc qdisc add dev <iface> clsact` only if missing — hook point for the tc-bpf egress filter (never deleted by `setup.sh`).
3. `ip -force link set dev <iface> xdpgeneric pinned /sys/fs/bpf/vantage/vantage_rx_policer` — atomic replace on re-run.
4. `tc filter replace dev <iface> egress protocol all pref 1 handle 1 bpf da pinned /sys/fs/bpf/vantage/vantage_tx_pacer` — atomic replace on re-run; stale Vantage pacers at other prefs (left by older `setup.sh`) are removed afterwards.
5. Verifies the result (generic XDP, root `fq`, `clsact`, exactly one Vantage egress filter, attached program ids equal to the pinned ones) and exits 4 if it is not as expected.

Re-running `setup.sh` on an attached NIC is safe: neither hook is removed at any point.

Exit codes: `0` attached and verified, `1` usage / no such interface, `2` programs not loaded (`load` first) or `bpftool` not usable, `3` conflicting hook found (nothing changed), `4` post-attach check failed (current state is printed). `setup.sh` may be run as root or by a user with `sudo` rights (`./setup.sh enp0s3`).

## 6. Set / reset / inspect per-UE policy

```bash
# Set: UE at 10.45.1.23 gets 10 Mbps uplink admit, 20 Mbps downlink pace.
sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20

# Killswitch: block downlink to this UE entirely (uplink still policed at 10 Mbps).
sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 0

# Uplink uncapped, downlink 20 Mbps (rx 0 = no RX limit; counters still count).
sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 0 --tx-mbps 20

# Clear all shaping for a UE (traffic bypasses shaping and is no longer counted).
sudo ./target/release/vantage-5G reset --ue-ip 10.45.1.23

# Dump every UE with a policy.
sudo ./target/release/vantage-5G list

# Dump per-UE counters (all UEs, or filtered).
sudo ./target/release/vantage-5G stats
sudo ./target/release/vantage-5G stats --ue-ip 10.45.1.23
```

- `--rx-mbps` / `--tx-mbps` accept 0–400000 (400 Gbps); anything else is rejected by the argument parser (exit 2).
- `set` resets the UE's RX token bucket (`rx_state_map`) and TX EDT slot (`tx_tstamp_map`) only when the policy value (rx or tx) changes, so a new rate applies from the next packet instead of inheriting an old backlog; the UE then starts with a full bucket (250 ms of its RX rate, at least 67 050 bytes). Setting the same values again only rewrites the policy and keeps the state (the output ends with `(unchanged; rx/tx state kept)`), so re-applying policies periodically causes no burst and does not forget a backlog. `reset` always removes the policy and the state together. To force a state reset, run `reset` and then `set`.
- `reset` of a UE without a policy prints `no policy for UE … (nothing to clear)` and exits 0; any other failure (e.g. not root) exits non-zero.
- Counters (`stats`) are kept after `reset`; they are only counted while the UE has a policy.

## 7. Monitor — Prometheus exporter

```bash
sudo ./target/release/vantage-5G monitor           # binds :9090
# or a different port:
sudo ./target/release/vantage-5G monitor --port 9191
```

Exposed series (all labeled with `ue_ip`):

```
vantage_ue_rx_bytes_total       # L2 bytes admitted by the RX policer
vantage_ue_rx_packets_total     # frames seen by XDP (generic mode: after GRO, one merged frame = 1)
vantage_ue_rx_drops_total       # dropped by the RX policer
vantage_ue_tx_bytes_total       # L2 bytes scheduled by the TX pacer
vantage_ue_tx_packets_total     # wire segments (a GSO packet counts gso_segs)
vantage_ue_tx_drops_total       # downlink drops: killswitch, or EDT horizon > 2 s (segments)
vantage_ue_policy_rx_bps        # configured RX cap (0 = uncapped)
vantage_ue_policy_tx_bps        # configured TX cap (0 = killswitch)
```

- RX and TX packet counts are not directly comparable: TX counts wire segments, RX counts what the XDP hook sees, which in generic mode is after GRO.
- TX drops include packets the pacer refuses to schedule more than 2 s ahead (the "horizon"), i.e. downlink offered far above the cap, e.g. a UDP flood. This keeps one overloaded UE from black-holing its own later traffic; TCP backs off.
- UEs with `rx_bps = 0` still count RX bytes/packets. UEs without any policy are not counted.
- `monitor` re-opens the pinned maps on every scrape, so it keeps working across `detach → unload → load → setup` without a restart and starts even before `load`. Series of a `reset` UE (policy gauges) or of a UE whose counters were evicted are removed; counters that restart from zero after a reload are seen by Prometheus as a counter reset (`rate()`/`increase()` stay correct). Scrape errors are logged and retried, never fatal.

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

What the cap counts: **all L2 bytes the UE sends (RX) or receives (TX), Ethernet/IP/TCP headers and the TCP ACKs of the opposite-direction session included.** iperf3 reports payload goodput, so it reads a few percent below the cap even when enforcement is exact (about 4.4% header overhead at 1500 MTU, plus ACKs: an uplink session also carries the ACKs of the same UE's downlink session, and vice versa). The exact check is the counter rate: two `stats` snapshots taken during the run, `(rx_bytes₂ − rx_bytes₁) × 8 / Δt` for uplink and the same with `tx_bytes` for downlink, should be within about 1% of the cap.

You can watch the counters live during the test:

```bash
sudo watch -n1 './target/release/vantage-5G stats'
```

## 9. Detach & unload

```bash
sudo ./detach.sh enp0s3                        # remove tc filter, XDP, clsact, root fq
sudo ./target/release/vantage-5G unload         # remove pinned programs & maps
```

- Order matters: `unload` refuses (exit 1, pins untouched) while a Vantage program is still attached to any interface in the current network namespace, and prints `run: sudo ./detach.sh <iface>`. It does not see attachments in other network namespaces.
- `detach.sh` removes every egress filter on the interface (not only Vantage's), XDP in generic and native mode, `clsact` and the root qdisc (the kernel re-creates its default root qdisc; a previous custom root qdisc is **not** restored). It then checks the interface: exit 0 nothing left, exit 1 no such interface, **exit 4** an XDP program, egress filter or `clsact` is still there (listed; e.g. run without root/sudo). Do not `unload` after exit 4.

## 10. Troubleshooting

**`skb->tstamp` seems to be ignored (TX pacing has no effect)** — the interface's root qdisc is not `fq`. `setup.sh` sets it, but if you attach manually make sure `tc qdisc show dev <iface>` prints `qdisc fq …` at root.

**`open pinned ue_policy_map (run `vantage-5G load` first; needs root)`** — the CLI can't open the pinned map: either nothing is loaded (run `sudo ./target/release/vantage-5G load`, once per boot) or the command was run without `sudo`.

**`setup.sh` exits 2 with `bpftool is not usable`** — install `linux-tools-$(uname -r)` (§3); `bpftool version` must work.

**`ip link set … xdpgeneric` succeeds but nothing hits XDP** — the interface may be a virtual link of the wrong kind. Try attaching to the physical N6 NIC directly (not a bridge or VF representor).

**`stats` stays empty for a UE although traffic flows** — the N6 interface may not see the UE's IP at all: a core that NATs UE traffic (e.g. the Open5GS quickstart's `MASQUERADE` rule) makes every UE appear as the UPF's address. Check with `sudo tcpdump -ni <iface> host <UE_IP> -c 5`; if only the UPF address shows up, exclude the service subnet from the core's NAT.

**RX drop counter climbs but throughput isn't shaped** — the traffic isn't going through the interface you attached to. `sudo ip -s link show dev <iface>` should show packet counts moving; `./target/release/vantage-5G stats` should show the same UE's rx_bytes rising.

**Verifier rejects the program after `make build`** — usually a kernel/BTF mismatch. `make check` verifies BTF; if you upgraded the kernel, re-run `make clean && make build` so `vmlinux.h` is regenerated for the running kernel.

**`load` fails with `pinned maps under /sys/fs/bpf/vantage do not match the object`** — the new build changed a map definition (this release: `rx_state_map`, `tx_tstamp_map` and `ue_stats_map` became `LRU_HASH` with 16384 entries; the message lists each difference, e.g. `max_entries 1024 -> 16384`), so the maps pinned by the running version cannot be reused. Nothing was changed; the running version keeps working. Upgrade in this order, then re-apply every policy (they are lost with the old maps):

```bash
sudo ./detach.sh <iface>
sudo ./target/release/vantage-5G unload
sudo ./target/release/vantage-5G load
sudo ./setup.sh <iface>
sudo ./target/release/vantage-5G set --ue-ip ... --rx-mbps ... --tx-mbps ...   # for every UE
```

**`unload` refuses: `Vantage programs are still attached`** — run `sudo ./detach.sh <iface>` for each listed interface, then `unload`. Removing pins by hand while a program is attached does not stop it: the program keeps running with its (now unreachable) maps, and the next `load` creates fresh maps the running program never reads, so `set` would have no effect.

**`ue_policy_map`, `ue_stats_map`, `rx_state_map` or `tx_tstamp_map` directly under `/sys/fs/bpf`** — left by a build older than the `/sys/fs/bpf/vantage/` layout; `unload` only cleans `/sys/fs/bpf/vantage/`. After `detach.sh` + `unload`, remove them with `sudo rm -f /sys/fs/bpf/{ue_policy_map,ue_stats_map,rx_state_map,tx_tstamp_map}`.

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
