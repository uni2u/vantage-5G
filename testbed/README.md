# Vantage-5G local testbed

Scripts that build and exercise Vantage-5G on a developer machine before it is installed on a physical service node. The goal is to catch defects at the cheapest level that can show them. Everything here runs the **same operator path as the top-level [README](../README.md)** (`make build` → `vantage-5G load` → `./setup.sh` → `set` → iperf3 → killswitch → `./detach.sh` → `unload`) against an emulated N6 link; a defect that would hit an operator following the README must also fail here.

The scripts were developed on a macOS (x86_64) host. `l2-vbox.sh` uses `hdiutil`, so it runs on macOS only; `dev.sh`, `l1-docker.sh` and `run-tests.sh` are plain bash.

## Contents

1. [Levels](#1-levels)
2. [Requirements](#2-requirements)
3. [dev.sh — one-off commands in the dev container](#3-devsh--one-off-commands-in-the-dev-container)
4. [l1-docker.sh — L1 run in Docker](#4-l1-dockersh--l1-run-in-docker)
5. [l2-vbox.sh — L2 run in a VirtualBox Ubuntu VM](#5-l2-vboxsh--l2-run-in-a-virtualbox-ubuntu-vm)
6. [Environment variables](#6-environment-variables)
7. [Emulated topology (netns-topo.sh)](#7-emulated-topology-netns-toposh)
8. [What run-tests.sh does](#8-what-run-testssh-does)
9. [Result directory and how to read it](#9-result-directory-and-how-to-read-it)
10. [Known limits](#10-known-limits)
11. [Troubleshooting](#11-troubleshooting)
12. [Files](#12-files)

## 1. Levels

| Level | Environment | Command | Covers | Cannot cover |
|---|---|---|---|---|
| **L0** | any host with Python 3.8+ | `python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .` | Static contracts: C struct ↔ Rust `#[repr(C)]`, map/program names, pin paths in `setup.sh`/`detach.sh`, Prometheus metric names ↔ top-level README. Exit 1 on any FAIL | Anything that runs |
| **L1** | Docker (Docker Desktop kernel), privileged Ubuntu 24.04 container | `./testbed/l1-docker.sh` | Build, verifier, `load` (and idempotent re-load), attach, uplink RX policing with two concurrent sessions, killswitch, `set`/`reset` state handling, `unload` guard, `detach.sh` exit codes, upgrade from older pins | `sch_fq` is missing → `setup.sh`, downlink EDT pacing and the non-root / `ingress` checks are skipped |
| **L2** | VirtualBox VM, stock Ubuntu 24.04 (`noble`, default) or 22.04 (`jammy`) | `./testbed/l2-vbox.sh` / `VT_RELEASE=jammy ./testbed/l2-vbox.sh` | All of L1 plus `setup.sh` (re-runs, re-run under load, non-root user, `ingress` refusal, missing `bpftool`), downlink pacing and the top-level README §8 four concurrent sessions | Real 5G path (GTP, UPF NAT), physical NIC, native XDP |
| **L3** | Open5GS + UERANSIM VM and service VM | not built yet | Real UE addresses through a core, NAT on/off | Physical NIC |
| **L4** | Physical Ubuntu server | [`docs/install-runbook.md`](../docs/install-runbook.md) (run by hand) | Real NIC, driver, multi-queue, real core | — |

Pick the lowest level that can show the change: contracts only → L0; BPF or CLI logic → L1; anything touching `setup.sh`, qdiscs or TX pacing → L2 (both releases, since iproute2 differs: 5.15 on 22.04 prints no program names). A level that was not run is not a pass.

## 2. Requirements

| For | Needs |
|---|---|
| L0 | `python3` (3.8+) |
| L1, `dev.sh` | Docker with privileged containers (Docker Desktop on macOS works). Internet on first run: the `vantage-dev` image installs Ubuntu packages and Rust (`testbed/docker/Dockerfile`) |
| L2 | macOS host (x86_64; the VM uses the `amd64` Ubuntu cloud image), VirtualBox (`VBoxManage` on `PATH`), `curl`, `ssh`, `ssh-keygen`, `rsync`, `hdiutil`. Internet on first run (cloud image download, packages and Rust installed by cloud-init inside the VM). About 20 GB of disk per VM; the VM gets 4 vCPUs and 4 GB RAM |

## 3. `dev.sh` — one-off commands in the dev container

```bash
./testbed/dev.sh 'make build'
./testbed/dev.sh 'cargo clippy --release'
./testbed/dev.sh 'make bpf && bpftool prog loadall vantage_tx_pacer.o /sys/fs/bpf/t type tc'
./testbed/dev.sh 'cargo build --release -q && ./target/release/vantage-5G --help'
```

- Builds (quietly) the `vantage-dev:latest` image from `testbed/docker/`, then runs the given command with `bash -c` as root in a `--privileged` container with `/sys/fs/bpf` mounted.
- The repository is mounted **read-only** at `/src` and copied to `/work` (without `target/`, `_workspace*`, `.git`); the command runs in `/work`. Nothing it writes reaches the host tree.
- Two named Docker volumes persist between runs: `vantage-cargo-registry` (cargo registry) and `vantage-target` (`/work/target`, so Rust builds are incremental).
- The container is removed after the command (`--rm`); BPF pins it created disappear with it.
- No `sch_fq` here either (same kernel as L1).

## 4. `l1-docker.sh` — L1 run in Docker

```bash
./testbed/l1-docker.sh            # iperf3 sessions of 15 s
T=30 ./testbed/l1-docker.sh
```

- Same image, mounts and volumes as `dev.sh`; additionally mounts `_workspace/l1-<YYYYmmdd_HHMMSS>/` as `/results`, writes `commit.txt` there on the host (`git describe --always --dirty`, see §9) and runs `bash testbed/run-tests.sh` with `OUT=/results`.
- Only `T` (default 15) is passed into the container. The `VT_*` variables of §6 are **not** forwarded by `l1-docker.sh`.
- Prints `L1 results: <dir>` and exits with `run-tests.sh`'s exit code (0 = no FAIL line in `summary.txt`).

## 5. `l2-vbox.sh` — L2 run in a VirtualBox Ubuntu VM

```bash
./testbed/l2-vbox.sh                       # noble (24.04): create VM on first use, then test
VT_RELEASE=jammy ./testbed/l2-vbox.sh      # jammy (22.04)
T=20 VT_SETUP_AS=ubuntu ./testbed/l2-vbox.sh
./testbed/l2-vbox.sh ssh                   # shell into the VM (starts it if needed)
./testbed/l2-vbox.sh stop                  # ACPI power-off
./testbed/l2-vbox.sh delete                # power off, unregister, delete disk and VM dir
```

Subcommands: `test` (default), `ssh`, `stop`, `delete`; anything else prints `usage: … [test|ssh|stop|delete]` and exits 1. `VT_RELEASE` selects the VM for every subcommand (e.g. `VT_RELEASE=jammy ./testbed/l2-vbox.sh ssh`).

| `VT_RELEASE` | VM name | SSH port (host `127.0.0.1`) |
|---|---|---|
| `noble` (default) | `vantage-svc` | 2522 |
| `jammy` | `vantage-svc-jammy` | 2523 |

First `test` run (no VM yet; `ssh` does not create one):

1. Creates an ed25519 key `~/.cache/vantage-5g/ssh/id_ed25519` (once, shared by both VMs).
2. Downloads `https://cloud-images.ubuntu.com/<release>/current/<release>-server-cloudimg-amd64.vmdk` into `~/.cache/vantage-5g/` (once per release), clones it to a 20 GB VDI.
3. Builds a cloud-init NoCloud seed ISO from `testbed/vbox/user-data.tmpl` (user `ubuntu` with NOPASSWD sudo and the key; packages: clang, llvm, libbpf-dev, linux-tools-generic and `linux-tools-$(uname -r)`, iproute2, iptables, iperf3, tcpdump, …; Rust via rustup for root, with `cargo`/`rustc` linked into `/usr/local/bin`).
4. Creates the VM (4 vCPU, 4096 MB, virtio NIC on NAT with port-forward `127.0.0.1:<port> → 22`, serial console logged to `console.log`), boots it headless and waits about 10 minutes (120 tries, 5 s apart) for SSH, then for cloud-init (the first boot installs the toolchain and takes several minutes).

Every `test` run then:

1. `rsync`s the repository to `~ubuntu/work/` in the VM (without `target/`, `_workspace*`, `.git`),
2. runs `sudo -i env OUT=/home/ubuntu/results-<ts> T=<T> [VT_* …] bash /home/ubuntu/work/testbed/run-tests.sh` in the VM,
3. copies the results back to `_workspace/l2-<release>-<YYYYmmdd_HHMMSS>/` and writes `commit.txt` there (`git describe --always --dirty` of the host tree plus `release=<release> vm=<name>`),
4. prints `L2 results: <dir>` and exits with `run-tests.sh`'s exit code.

The VM keeps running after a test (the next run starts faster); `stop` it when done. Two runs must not use the same VM at the same time (they share `/sys/fs/bpf/vantage` and the `vt-*` interfaces).

## 6. Environment variables

Read by the scripts shown; "→ VM" means `l2-vbox.sh` forwards it to `run-tests.sh` in the VM.

| Variable | Default | Used by | Effect |
|---|---|---|---|
| `T` | `15` (`l1-docker.sh`, `run-tests.sh`), `30` (`l2-vbox.sh`) | all three | Duration of each iperf3 session in seconds. The counter snapshots are taken at 5 s and at `T−1` s, so use `T ≥ 10` |
| `VT_RELEASE` | `noble` | `l2-vbox.sh` | `noble` (24.04) or `jammy` (22.04); anything else exits 1 |
| `VT_SSH_PORT` | `2522` / `2523` | `l2-vbox.sh` | Host port forwarded to the VM's SSH: set in the VM's NAT port-forward when the VM is created, and used for every SSH/rsync connection. For an existing VM it must match the forward it was created with |
| `VM` | `vantage-svc` / `vantage-svc-jammy` | `l2-vbox.sh` | VirtualBox VM name |
| `VT_CACHE` | `~/.cache/vantage-5g` | `l2-vbox.sh` | Cloud images, SSH key and VM directories (`<cache>/vm/<VM>/`) |
| `OUT` | `./_workspace/test-<ts>` | `run-tests.sh` | Result directory (set by `l1-docker.sh` / `l2-vbox.sh`) |
| `VT_SETUP_AS` | empty (root) | `run-tests.sh` → VM | Run every `setup.sh` / `detach.sh` call as this user via `sudo -n -u <user>`, i.e. the operator path `./setup.sh <iface>` without `sudo`. The user needs NOPASSWD sudo (`ubuntu` in the VM) |
| `VT_NONROOT_USER` | `ubuntu` | `run-tests.sh` → VM | User for the fixed `setup.sh-nonroot` step; the step is SKIPped if the user is missing or has no NOPASSWD sudo |
| `VT_NAT` | `0` | `netns-topo.sh` → VM | `1` adds `iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o vt-n6c -j MASQUERADE` in the core namespace, like the Open5GS quickstart. The service node then sees only `10.99.0.2`, no policy matches and the verdicts **fail on purpose** — use it to see that failure mode |
| `VT_NETEM` | empty | `netns-topo.sh` → VM | netem arguments applied as root qdisc on the core's UE-facing links to mimic the radio leg, e.g. `VT_NETEM="delay 10ms rate 200mbit"` |
| `VT_NO_BPFTOOL` | `0` | `run-tests.sh` → VM | Accepted for compatibility and only recorded in `env.txt`. The missing-`bpftool` checks (`setup.sh-no-bpftool*`) run on every run anyway |

## 7. Emulated topology (`netns-topo.sh`)

`run-tests.sh` calls `testbed/netns-topo.sh up` (and `down` on exit). The current network namespace plays the **service node**; Vantage attaches to its N6 interface `vt-n6`.

```
 netns vt-ue-a                netns vt-core                          root netns = "service node"
 +-------------------+        (UPF-like router: ip_forward=1,        +------------------------------+
 | vt-ua 10.45.1.23  |--veth--| vt-ca   proxy_arp on vt-ca/vt-cb)    |                              |
 +-------------------+        |                                      |  vt-n6 10.99.0.1/24          |
                              |  vt-n6c 10.99.0.2/24 ====== veth ======|    ^ XDP (UL/RX) and         |
 netns vt-ue-b                |                                      |    | tc egress (DL/TX) here   |
 +-------------------+        |                                      |                              |
 | vt-ub 10.45.1.24  |--veth--| vt-cb                                |  route 10.45.0.0/16          |
 +-------------------+                                               |    via 10.99.0.2 dev vt-n6   |
                              VT_NETEM: root netem on vt-ca, vt-cb   +------------------------------+
                              VT_NAT=1: MASQUERADE 10.45.0.0/16 out vt-n6c
```

- UEs have `/32` addresses and a default route on their veth; the core routes each `/32` to its UE link and has `default via 10.99.0.1`.
- `up` deletes any previous topology first, then pings `10.99.0.1` from both UEs and exits 1 if either fails.
- The `d4-fwd-overload-then-tcp` step adds a temporary netns `vt-src` (`10.98.0.2/24`, veth `vt-s0`/`vt-s1`, root side `10.98.0.1`) to send forwarded downlink traffic, and restores `net.ipv4.ip_forward` afterwards.

Run by hand (as root, from the repository root): `sudo ./testbed/netns-topo.sh up`, `sudo ./testbed/netns-topo.sh down`. In the VM, open a shell with `./testbed/l2-vbox.sh ssh`; the synced tree is `~/work`.

## 8. What `run-tests.sh` does

Runs as root from the repository root (it `cd`s there itself). Each step writes one line to `summary.txt` and its output to `<step>.log`, except `iperf-verdict` / `counter-verdict` (output in `verdict.txt` / `verdict_counters.txt`) and SKIP lines (no log). In order:

| Step | Checks |
|---|---|
| `build` | `make build` (stops everything on failure) |
| `verifier` | `bpftool prog loadall` of both objects into a temporary bpffs dir (falls back to `type classifier` on old bpftool) |
| `load`, `load-idempotent` | `vantage-5G load` creates the six pins; a second `load` succeeds |
| `map-sizes-d25` | three `lru_hash` maps with `max_entries 16384`, `ue_policy_map` `hash` 1024; records `nproc` and the `memlock` total |
| `topology` | `netns-topo.sh up` |
| `setup.sh-no-bpftool` | with every `bpftool` hidden, `setup.sh vt-n6` exits 2 and changes nothing |
| `setup.sh`, `setup.sh-no-bpftool-attached`, `setup.sh-rerun`, `attached-after-rerun` | fq kernels only: attach, refusal without bpftool on an attached NIC, re-run keeps exactly one XDP program and one egress filter with the pinned ids. Without fq: `SKIP setup.sh` and `attach-manual` (clsact + `xdpgeneric` + egress filter by hand) |
| `set-A`, `set-B` | `10.45.1.23` rx 10 / tx 20, `10.45.1.24` rx 3 / tx 5 |
| (iperf3) | Four concurrent sessions from the UE namespaces to `10.99.0.1` ports 5201–5204 (README §8); without fq only the two uplink sessions (`SKIP dl-pacing`). Counter snapshots `stats_t1.txt`/`stats_t2.txt` at 5 s and `T−1` s |
| `setup.sh-rerun-under-load` | fq only: `setup.sh` re-run in the middle of the iperf3 run; the verdicts below cover that moment |
| `iperf-verdict`, `counter-verdict` | `iperf_verdict.py` / `counter_verdict.py` on `spec.csv` (±10%) |
| `d16-tx-segments` | fq only: UE-A `tx_bytes / tx_packets ≤ 1514` (TX counts wire segments) |
| `killswitch` | `tx-mbps 0` for UE-B: ping fails, `tx_drops` rises, UE-A unaffected; on fq kernels also survives a `setup.sh` re-run |
| `reset` | UE-B disappears from `list` |
| `d7-reset-clears`, `d26-same-set-keeps-state`, `d26-changed-set-clears` | `reset` removes `rx_state_map`/`tx_tstamp_map` entries; same-value `set` prints `(unchanged; rx/tx state kept)` and keeps them byte-for-byte; a changed rx or tx clears them |
| `d6-small-pkt-no-starvation` | rx 1 Mbps, 64-byte UDP flood: admitted rate 0.9–1.2 Mbps |
| `d4-fwd-overload-then-tcp` | 100 Mbit/s forwarded UDP against tx 1 Mbps: `tx_drops` rise, EDT slot ≤ ~2 s ahead, a TCP session right after still connects (and stays ≤ 1.1 Mbps on fq); rx counters count for an `rx 0` UE |
| `setup.sh-nonroot` | fq only: re-run, `detach.sh`, fresh `setup.sh` as `VT_NONROOT_USER` |
| `unload-refused-while-attached` | `unload` exits non-zero, prints `detach.sh vt-n6`, pins and hooks unchanged |
| `detach-rc` | `detach.sh` as `nobody` exits 4 without changing anything; on a missing interface exits 1 |
| `detach` | `detach.sh vt-n6` leaves no XDP program and no bpf egress filter |
| `setup.sh-ingress-refused` | fq only: with an `ingress` qdisc present, `setup.sh` exits 3 and changes nothing |
| `unload` | `unload` succeeds and leaves no Vantage pins in `/sys/fs/bpf` |
| `upgrade-from-hash-pins`, `upgrade-from-lru1024-pins` | load + attach an older build (state maps `HASH`/1024, or `LRU_HASH`/1024), then the new `load` must exit 1 with `max_entries 1024 -> 16384` and the procedure, leave everything unchanged, and the documented `detach → unload → load → setup → set` must work |

On exit (also on failure) a trap restores hidden `bpftool` binaries, detaches, kills `iperf3`, removes the topology and unloads.

## 9. Result directory and how to read it

L1: `_workspace/l1-<ts>/`; L2: `_workspace/l2-<release>-<ts>/` (`_workspace*` is git-ignored).

| File | Content |
|---|---|
| `summary.txt` | One line per step: `[PASS]`, `[FAIL] <step> see <step>.log` (`see verdict.txt` / `see verdict_counters.txt` for the two verdict steps), or `[SKIP] <step> <reason>` (no log). **Read this first.** The script's exit code is 1 if any line is `FAIL` |
| `<step>.log` | stdout+stderr of that step; for a FAIL the last lines say which expectation was not met |
| `commit.txt` | Tested tree as `git describe --always --dirty` of the host checkout: the short HEAD hash, with `-dirty` appended when **tracked** files had uncommitted changes (the run then tested HEAD plus those changes; untracked new files are not reflected). L2 also `release=<release> vm=<name>`. Results recorded before this change hold only the HEAD hash even if the tree was dirty |
| `env.txt` | Kernel (`uname -r`), `no-git` (L1/L2 copy the tree without `.git`; use `commit.txt`. A direct `run-tests.sh` run in a checkout writes `git describe --always --dirty` here), `os=…`, `iproute2=…`, `bpftool=<path used by the test>`, `setup_as=… no_bpftool=…`, `has_fq=0/1`, `root_pins_before=` (pins left in the bpffs root by older builds) |
| `spec.csv` | The sessions that were run (`label,ue_ip,direction,cap_mbps,json_path`) |
| `a_ul.json`, `b_ul.json`, `a_dl.json`, `b_dl.json` | `iperf3 -J` output of the concurrent sessions (`*_dl.json` only with fq) |
| `verdict.txt` | `iperf_verdict.py` table: steady-state goodput vs cap |
| `verdict_counters.txt` | `counter_verdict.py` table: `rx_bytes`/`tx_bytes` rate between the two snapshots vs cap |
| `stats_t1.txt`, `stats_t2.txt` | `t=<epoch>` + `vantage-5G stats` at 5 s and `T−1` s |
| `stats_after_iperf.txt`, `list.txt` | `stats` after the run, `list` after the two `set`s |
| `attach-before-rerun.txt`, `attach-after-rerun.txt` | `ip -d link`, `tc qdisc`, `tc filter … egress` around the `setup.sh` re-run (fq only) |
| `d4_udp.json`, `d4_tcp.json`, `d6_udp.json` | iperf3 output of the regression steps |

Interpreting the verdicts (same scripts and format as the top-level README §8.5):

- `counter-verdict` is the authoritative throughput check: it measures exactly what the cap governs (L2 bytes including headers and the opposite session's ACKs). On a quiet host expect a few tenths of a percent.
- `iperf-verdict` reads goodput, so uplink rows are normally 1–7% under the cap; `unstable CV>0.15` on uplink rows is a warning, not a failure.
- A row **over** the cap is a product problem (shaping not applied or admitting too much).
- Rows **under** the cap, with `tx_drops` 0 in `stats_after_iperf.txt`, usually mean the host was too busy (see §10). Re-run on a quiet host, or compare in the same VM against the kernel's own shapers, with Vantage detached (`./detach.sh vt-n6`) or both UEs `reset`, e.g. `tc qdisc replace dev vt-n6 root fq maxrate 20mbit` for downlink, and `tc qdisc add dev vt-n6 clsact` then `tc filter add dev vt-n6 ingress matchall action police rate 10mbit burst 312500 drop` for uplink (the ingress filter needs `clsact`, which `detach.sh` removes). These are not per-UE caps: `fq maxrate` limits each flow, the police filter all ingress traffic, so run one session at a time. If they miss too, the environment is the bottleneck.
- `SKIP` lines carry their reason; a SKIP on L1 (`setup.sh`, `dl-pacing`) is covered by L2, not passed.

To re-judge a stored run by hand:

```bash
d=$(ls -d _workspace/l2-jammy-2* | tail -1)     # latest jammy run, or any result directory
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py $d/spec.csv [--skip 5 --tol 0.10 --cv-warn 0.15]
python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py $d/spec.csv $d/stats_t1.txt $d/stats_t2.txt [--tol 0.10]
```

## 10. Known limits

- **No `sch_fq` in Docker Desktop's kernel (L1).** EDT pacing needs a root `fq` qdisc, so `setup.sh` cannot run and downlink pacing is untestable; `run-tests.sh` detects this (`has_fq=0` in `env.txt`) and attaches without fq. Use L2.
- **Throughput depends on the host.** Both levels run iperf3 on the same machine as the datapath. A busy host (other VMs, builds) makes sessions fall **under** their caps; counter and iperf verdicts then fail although the datapath is fine. Check host load before trusting an under-cap result (`uptime`; on macOS also the VM's `VBoxHeadless` CPU in Activity Monitor). Over-cap results are not caused by load.
- **Emulated N6 only.** veth pairs, `xdpgeneric`, a single queue, no GTP and no real UPF: native XDP, multi-queue NICs (`mq` root qdisc), BIG TCP / GRO sizes and the core's NAT behaviour are only checked on the physical server (runbook §6).
- **`unload` guard is per network namespace.** Attachments inside the UE/core namespaces would not be seen; the tests attach only in the service-node namespace.
- **`l1-docker.sh` forwards only `T`.** `VT_NAT`, `VT_NETEM`, `VT_SETUP_AS` take effect on L2 only.

## 11. Troubleshooting

**`l2-vbox.sh` prints `[-] ssh not reachable; boot log: …/console.log`** — read the serial boot log first: `~/.cache/vantage-5g/vm/vantage-svc/console.log` (`vantage-svc-jammy` for 22.04). Typical causes: the cloud image download was interrupted (delete `~/.cache/vantage-5g/<release>-server-cloudimg-amd64.vmdk` and the VM with `./testbed/l2-vbox.sh delete`, then re-run), cloud-init failed (search the log for `cloud-init` errors), or another process holds the SSH port (`lsof -iTCP:2522`; or set `VT_SSH_PORT` before the VM is created).

**`VirtualBox (VBoxManage) not found`** — install VirtualBox or put `VBoxManage` on `PATH`.

**Waiting for cloud-init takes long** — expected on first boot (packages and Rust). `./testbed/l2-vbox.sh ssh` then `cloud-init status --long` and `sudo tail -f /var/log/cloud-init-output.log` show progress.

**Docker errors from `l1-docker.sh` / `dev.sh`** (`Cannot connect to the Docker daemon`, image build fails) — start Docker Desktop; an image build failure is an environment failure, not a product result. Report it separately.

**Leftovers after an aborted run** — the exit trap normally cleans up (and the L1 container is removed anyway). In the VM (`./testbed/l2-vbox.sh ssh`, then `cd ~/work`), by hand: `sudo ./detach.sh vt-n6; sudo ./target/release/vantage-5G unload; sudo ./testbed/netns-topo.sh down; sudo pkill -x iperf3`.

**`[FAIL] build`** — read `build.log`. Every later step is skipped (`[SKIP] rest build failed`).

**All throughput rows under cap on one release only** — compare with the other release on the same host and with the kernel-shaper check in §9 before treating it as a defect.

## 12. Files

| Path | Role |
|---|---|
| `dev.sh` | One-off command in the dev container |
| `l1-docker.sh` | L1: `run-tests.sh` in a privileged container |
| `l2-vbox.sh` | L2: create/start the VirtualBox VM, sync the tree, run `run-tests.sh`, fetch results; `ssh` / `stop` / `delete` |
| `run-tests.sh` | Test body shared by L1 and L2 (§8) |
| `netns-topo.sh` | Emulated UE / core / N6 topology (§7) |
| `docker/Dockerfile` | `vantage-dev` image: Ubuntu 24.04, clang/llvm/libbpf, linux-tools, iproute2, iptables, iperf3, tcpdump, Rust (rustfmt, clippy) |
| `vbox/user-data.tmpl` | cloud-init for the L2 VM |
| `../.claude/skills/vantage-testbed/scripts/iperf_verdict.py`, `counter_verdict.py` | Verdict scripts (also used for physical-server results) |
| `../.claude/skills/vantage-boundary-check/scripts/contract_check.py` | L0 contract check |
