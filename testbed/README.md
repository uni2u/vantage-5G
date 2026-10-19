# Vantage-5G local testbed

Scripts that build and exercise Vantage-5G on a developer machine before it is installed on a physical service node. The goal is to catch defects at the cheapest level that can show them. Everything here runs the **same operator path as the top-level [README](../README.md)** (`make build` → `vantage-5G load` → `./setup.sh` → `set` → iperf3 → killswitch → `./detach.sh` → `unload`) against an emulated N6 link; a defect that would hit an operator following the README must also fail here.

The scripts were developed on a macOS (x86_64) host. `l2-vbox.sh` and `l3-vbox.sh` use `hdiutil`, so they run on macOS only; `dev.sh`, `l1-docker.sh` and `run-tests.sh` are plain bash.

## Contents

1. [Levels](#1-levels)
2. [Requirements](#2-requirements)
3. [dev.sh — one-off commands in the dev container](#3-devsh--one-off-commands-in-the-dev-container)
4. [l1-docker.sh — L1 run in Docker](#4-l1-dockersh--l1-run-in-docker)
5. [l2-vbox.sh — L2 run in a VirtualBox Ubuntu VM](#5-l2-vboxsh--l2-run-in-a-virtualbox-ubuntu-vm)
5a. [l3-vbox.sh — L3 run: Open5GS + UERANSIM and a separate service node](#5a-l3-vboxsh--l3-run-open5gs--ueransim-and-a-separate-service-node)
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
| **L2** | VirtualBox VM, stock Ubuntu 24.04 (`noble`, default) or 22.04 (`jammy`) | `./testbed/l2-vbox.sh` / `VT_RELEASE=jammy ./testbed/l2-vbox.sh` | All of L1 plus `setup.sh` (re-runs without a hook gap, re-run under load, non-root user, `ingress` refusal, missing `bpftool`, `--xdp-mode` switching, multi-queue `mq` layout with `VT_N6_TXQ`), downlink pacing, the top-level README §8 four concurrent sessions and a 4-flow-per-UE downlink cap check | Real 5G path (GTP, UPF NAT), physical NIC and its driver's native XDP / hardware queues |
| **L3** | Two VirtualBox VMs: `vantage-core` (Ubuntu 22.04, Open5GS reference install + UERANSIM) and `vantage-svc` (the L2 noble VM) joined by an internal-network N6 | `./testbed/l3-vbox.sh up`, then `./testbed/l3-vbox.sh test` | Real UE addresses through a 5G core (GTP-U, UPF, `ogstun`): the quickstart NAT failure mode, top-level README §3.2 (NAT exception A and B, `ip_forward`, return route, end-to-end check) and §8 (four sessions bound with `iperf3 -B <UE IP>`, counter/iperf verdicts), killswitch, on a virtio NIC instead of veth | Physical NIC, native XDP on a real driver, hardware queues, throughput above UERANSIM's userspace GTP capacity |
| **L4** | Physical Ubuntu server | [`docs/install-runbook.md`](../docs/install-runbook.md) (run by hand) | Real NIC, driver, multi-queue, real core | — |

Pick the lowest level that can show the change: contracts only → L0; BPF or CLI logic → L1; anything touching `setup.sh`, qdiscs or TX pacing → L2 (both releases, since iproute2 differs: 5.15 on 22.04 prints no program names). A level that was not run is not a pass.

## 2. Requirements

| For | Needs |
|---|---|
| L0 | `python3` (3.8+) |
| L1, `dev.sh` | Docker with privileged containers (Docker Desktop on macOS works). Internet on first run: the `vantage-dev` image installs Ubuntu packages and Rust (`testbed/docker/Dockerfile`) |
| L2 | macOS host (x86_64; the VM uses the `amd64` Ubuntu cloud image), VirtualBox (`VBoxManage` on `PATH`), `curl`, `ssh`, `ssh-keygen`, `rsync`, `hdiutil`. Internet on first run (cloud image download, packages and Rust installed by cloud-init inside the VM). About 20 GB of disk per VM; the VM gets 4 vCPUs and 4 GB RAM |
| L3 | As L2, plus the noble L2 VM (`vantage-svc`, created by `./testbed/l2-vbox.sh`), `jq` and `python3` on the host. Internet on first `up` (MongoDB repo, Open5GS PPA, UERANSIM from GitHub). `vantage-core` gets 4 vCPUs, 6 GB RAM, 20 GB disk; first `up` takes about 10–30 minutes (UERANSIM build) |

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
- Passes `T` (default 15) and, when set on the host, `VT_SETUP_AS`, `VT_NONROOT_USER`, `VT_NO_BPFTOOL`, `VT_NAT`, `VT_NETEM`, `VT_XDP_MODE`, `VT_N6_TXQ` into the container (`docker run -e`). The container has no `ubuntu` user and no `sch_fq`, so the `setup.sh`-related variables have no visible effect there; `VT_XDP_MODE` selects the slot of the manual attach and `VT_N6_TXQ` the queue count of the topology.
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

## 5a. `l3-vbox.sh` — L3 run: Open5GS + UERANSIM and a separate service node

```bash
./testbed/l3-vbox.sh up         # create/provision vantage-core, add NIC2 to vantage-svc, start the RAN
./testbed/l3-vbox.sh test       # scenarios (a) and (b) below; results in _workspace/l3-<ts>/
./testbed/l3-vbox.sh ssh-core   # shell on vantage-core (ssh 127.0.0.1:2524)
./testbed/l3-vbox.sh ssh-svc    # shell on vantage-svc  (ssh 127.0.0.1:2522)
./testbed/l3-vbox.sh down       # stop gNB/UEs, power both VMs off
./testbed/l3-vbox.sh delete     # delete vantage-core; remove vantage-svc's NIC2 (the VM itself stays)
```

Topology (mirrors the target deployment: the UPF host and the service node are different machines):

```
 vantage-core (Ubuntu 22.04)                                          vantage-svc (Ubuntu 24.04)
 ┌─ netns ran ──────────────────────┐   ┌─ root ns ──────────────────────────┐
 │ nr-ue x2: uesimtun0 10.45.0.2    │   │ AMF NGAP 10.100.0.5, UPF GTP-U .7    │      intnet "vantage-n6"
 │           uesimtun1 10.45.0.3    │═══│ ogstun 10.45.0.1/16 -> routing ->    │ enp0s8 ═══════════ enp0s8 10.200.0.2/24
 │ nr-gnb 10.100.0.2 (ran1)         │veth│ enp0s8 10.200.0.1/24 (UPF N6)       │                    ▲ Vantage XDP + tc/fq (<IF>)
 └──────────────────────────────────┘   └────────────────────────────────────┘
```

- **vantage-core**: 4 vCPU / 6 GB, NIC1 NAT (internet, SSH), NIC2 internal network `vantage-n6` (MAC `08:00:27:a0:6e:01`). `testbed/vbox/core-user-data.tmpl` installs build dependencies; `testbed/vbox/core-provision.sh` (run by `up` over SSH, idempotent, log `/var/log/vantage-core-provision.log` and `_workspace/l3-core-provision.log`) follows the Open5GS quickstart: MongoDB 8.0 from `repo.mongodb.org`, `ppa:open5gs/latest` (not pinned — `latest` installs whatever the PPA has; the installed version is printed by `up` and recorded in every run's `env.txt`; 2.8.0 at the time of writing), two subscribers with `open5gs-dbctl add` (IMSI `999700000000001`/`…002`, the K/OPc of UERANSIM's `config/open5gs-ue.yaml`; `open5gs-dbctl` is not in the Ubuntu package, so it is fetched from `misc/db/` of the installed version's tag and checked with `sha256sum -c` against a hash pinned for 2.8.0 — another version needs `DBCTL_SHA256=<sha256>` for `up`), UERANSIM built from source (`UERANSIM_REF`, default `v3.2.7`, whose clone must resolve to commit `1d1e154f…`; another tag needs `UERANSIM_COMMIT=<sha>`) in `/opt/UERANSIM`. One deviation, taken from the quickstart's own "gNB on another host" diff: AMF NGAP and UPF GTP-U listen on `10.100.0.5` / `10.100.0.7` (a veth to netns `ran`) instead of `127.0.0.5` / `127.0.0.7`. The gNB and both UEs (`nr-ue -n 2`) run in netns `ran`, so UE addresses are not local to the UPF host and downlink really goes ogstun → UPF → GTP-U → gNB → UE.
- **NAT state**: `testbed/vbox/core-ran.sh nat-reference` applies the quickstart's "UE WAN connectivity" commands verbatim (`sysctl -w net.ipv4.ip_forward=1`, `iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE`, IPv6 likewise) and removes everything scenario (b) added. `test` starts and ends with it.
- **vantage-svc**: the L2 noble VM. `up` powers it off once to add NIC2 (`vantage-n6`, MAC `08:00:27:a0:6e:02`) with `VBoxManage modifyvm`, then writes `/etc/netplan/60-vantage-n6.yaml` (10.200.0.2/24, matched by MAC). L2 ignores this NIC; the return route `10.45.0.0/16 via 10.200.0.1` exists only during an L3 test (L2's `netns-topo.sh` uses the same prefix on `vt-n6`).
- RAN: `core-ran.sh up` (creates netns `ran`, restarts `open5gs-amfd`/`open5gs-upfd`/`open5gs-smfd`, starts `nr-gnb` and `nr-ue` as transient systemd units `vt-gnb`/`vt-ue`; logs with `journalctl -u vt-gnb -u vt-ue`). `test` runs it again if the two `uesimtunN` are missing (e.g. after a reboot of vantage-core).

`test` steps (`summary.txt`, one `.log` per step; the commands are the documented ones from the top-level README and `docs/install-runbook.md` chapters 1 and 4):

| Step | What |
|---|---|
| `build`, `load`, `setup.sh` | operator path on vantage-svc, `./setup.sh <IF>` on the virtio N6 NIC |
| `ue-addr-8.1`, `nr-binder-in-build` | README §8.1 on the UE side: `uesimtunN` addresses in 10.45.0.0/16, `ip route get <SVC> from <UE>` → `dev uesimtunN`; `nr-binder` and `libdevbnd.so` in UERANSIM `build/` |
| `a-n6-sees-upf-ip-only` | (a) quickstart NAT: `tcpdump` on `<IF>` during `ping -I uesimtun0` shows only `10.200.0.1`, and the README §3.2 end-to-end filter `net 10.45.0.0/16` captures nothing |
| `a-policy-never-matches` | (a) with `set` 2/2 Mbps for both UEs, `iperf3 -B <UE>` UL and DL run far above the cap and `stats` has no UE rows |
| `b1-nat-exception-A` | README §3.2 (1) method A (`-I POSTROUTING 1 … -d <SVC_NET> -j ACCEPT`), ACCEPT listed above MASQUERADE, `conntrack -D` |
| `b2-ip-forward` | README §3.2 (2): sysctl.d file, `sysctl --system`, `-P FORWARD ACCEPT`, `ip route get <SVC>` |
| `b3-no-route-replies-lost` | without (3): requests from the UE IP reach `<IF>`, no reply leaves it (README's diagnosis "fix (3)") |
| `b3-return-route`, `b-e2e-ue-ip-on-n6` | README §3.2 (3) and "Check end to end": request **and** reply with the UE IP on `<IF>` |
| `b-baseline-no-policy` | four sessions without policy = capacity of the UERANSIM path; picks the caps (README's 10/20 and 3/5 if every session ≥ 60 Mbps, else 4/6 and 2/3; override `VT_L3_CAPS="A_rx A_tx B_rx B_tx"`) |
| `set-A`, `set-B`, `iperf-verdict`, `counter-verdict` | README §8.2–8.5: four concurrent `iperf3 -B <UE IP>` sessions (run directory `run/`, `spec.csv`, `stats_t1/t2.txt` at 5 s and 25 s) |
| `b-stats-has-ue-rows`, `b-no-session-over-cap` | functional checks: both UE addresses counted; no row above cap +10% in either verdict |
| `b-dl-udp-pacer-control`, `b-dl-kernel-fq-control` | evidence for an under-cap DL: UDP DL at 2× A's cap (counter must be within ±10%), and the kernel's `fq maxrate` on the same NIC (recorded) |
| `iperf-verdict-class` (INFO) | written only when `iperf-verdict` failed: "environment" if no row is over cap, `tx_drops` are 0 and the UDP control passed |
| `killswitch` | `--tx-mbps 0` for UE-B: `(killswitch: DL blocked)`, `ping -I uesimtun1` fails, UE-A pings, `iperf3 -R` for UE-B cannot connect (cap-0 verdict), TX_DROPS rises; restore |
| `b1-nat-exception-B` | README §3.2 (1) method B (replace the MASQUERADE rule with `! -d <SVC_NET>`): UE IP visible again |
| `detach`, `unload` | `./detach.sh <IF>`, `vantage-5G unload` |

Cleanup: an exit trap (normal end, failure, Ctrl-C, ssh drop) kills background captures, runs `detach.sh <IF>` and `unload`, removes the return route and iperf3/tcpdump on vantage-svc, and puts vantage-core back to the quickstart NAT state (`nat-reference-end.log`). `killswitch` restores UE-B's policy even when one of its checks fails. `test` starts both VMs if they are off (e.g. after `down`). `VT_L3_FORCE_KS_FAIL=1` makes the killswitch step fail on purpose (harness self-test).

Result directory `_workspace/l3-<ts>/`: `summary.txt`, `env.txt` (versions, addresses, host `uptime`), `commit.txt`, per-step logs, `*.tcpdump.txt`/`*.ue.txt` captures, `baseline/` and `run/` (iperf3 JSON, `spec.csv`, `stats_*.txt`, `rates.txt`, `uptime.txt`), `verdict.txt`, `verdict_counters.txt`, `tx_drops.txt`, `ctl_*` control runs.

## 6. Environment variables

Read by the scripts shown; "→ VM" means `l2-vbox.sh` forwards it to `run-tests.sh` in the VM. Every `VT_*` variable marked "→ VM" is also forwarded into the L1 container by `l1-docker.sh` (when set).

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
| `VT_XDP_MODE` | unset (= `generic`) | `run-tests.sh` → VM | `generic` or `native` (anything else exits 1). Unset: every `setup.sh` call is the operator default `setup.sh vt-n6` (generic). Set: every call passes `--xdp-mode <mode>`, and the attach check expects that slot (`xdpgeneric` / `xdpdrv`). Without fq (L1) it selects the slot of the manual attach. `native` on `vt-n6` uses the veth driver's native XDP, not a physical NIC driver |
| `VT_N6_TXQ` | `1` | `netns-topo.sh` → VM | Number of TX and RX queues of both ends of the N6 veth pair (`ip link add … numtxqueues n numrxqueues n`); must be a positive integer. With `n ≥ 2` `setup.sh` must build root `mq` with an `fq` child on every TX queue, and `setup.sh-mq-repair` runs. The checks read the queue count from `/sys/class/net/vt-n6/queues/tx-*` |
| `VT_N6_TXQ_MAX` | `VT_N6_TXQ` | `netns-topo.sh` → VM | Queues **allocated** to both ends of the N6 veth (`numtxqueues`/`numrxqueues`); must be ≥ `VT_N6_TXQ`. When larger, `netns-topo.sh up` reduces the active queues to `VT_N6_TXQ` with `ethtool -L … rx n tx n` on both ends (exit 1 if that fails). With `VT_N6_TXQ < 4 ≤ VT_N6_TXQ_MAX` the `setup.sh-txq-grow` step runs, e.g. `VT_N6_TXQ=2 VT_N6_TXQ_MAX=8` |

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
- `VT_N6_TXQ=n` gives `vt-n6` and `vt-n6c` `n` TX and `n` RX queues each (native XDP on veth needs at least as many RX queues as the peer has TX queues); `up` exits 1 if `vt-n6` does not end up with `n` TX queues. veth is a no-queue device, so its root qdisc is `noqueue` — not `mq` — before `setup.sh` and again after `detach.sh`, whatever the queue count.
- `up` deletes any previous topology first, then pings `10.99.0.1` from both UEs and exits 1 if either fails.
- The `d4-fwd-overload-then-tcp` step adds a temporary netns `vt-src` (`10.98.0.2/24`, veth `vt-s0`/`vt-s1`, root side `10.98.0.1`) to send forwarded downlink traffic, and restores `net.ipv4.ip_forward` afterwards.

Run by hand (as root, from the repository root): `sudo ./testbed/netns-topo.sh up`, `sudo ./testbed/netns-topo.sh down`. In the VM, open a shell with `./testbed/l2-vbox.sh ssh`; the synced tree is `~/work`.

## 8. What `run-tests.sh` does

Runs as root from the repository root (it `cd`s there itself). "Expected attach state" below means: XDP only in the requested slot (`xdpgeneric`, or `xdpdrv` with `VT_XDP_MODE=native`) running the pinned policer; root `fq` when `vt-n6` has one TX queue, otherwise root `mq` with an `fq` child on every TX queue; `clsact`; exactly one egress filter, `pref 1 handle 0x1 direct-action`, running the pinned pacer. Each step writes one line to `summary.txt` and its output to `<step>.log`, except `iperf-verdict` / `counter-verdict` (output in `verdict.txt` / `verdict_counters.txt`) and SKIP lines (no log). In order:

| Step | Checks |
|---|---|
| `build` | `make build` (stops everything on failure) |
| `verifier` | `bpftool prog loadall` of both objects into a temporary bpffs dir (falls back to `type classifier` on old bpftool) |
| `load`, `load-idempotent` | `vantage-5G load` creates the six pins; a second `load` succeeds |
| `map-sizes-d25` | three `lru_hash` maps with `max_entries 16384`, `ue_policy_map` `hash` 1024; records `nproc` and the `memlock` total |
| `topology` | `netns-topo.sh up` |
| `setup.sh-no-bpftool` | with every `bpftool` hidden, `setup.sh vt-n6` exits 2 and changes nothing |
| `setup.sh`, `setup.sh-no-bpftool-attached`, `setup.sh-rerun`, `attached-after-rerun` | fq kernels only: attach, refusal without bpftool on an attached NIC, re-run keeps the expected attach state (below). Without fq: `SKIP setup.sh`, `attach-manual` (clsact + XDP in the `VT_XDP_MODE` slot + egress filter by hand) and `attach-manual-xdp-slot` (only that slot, pinned policer id) |
| `setup.sh-rerun-no-gap` | fq only: `tc monitor` and `ip monitor link` run while `setup.sh` is re-run on the attached NIC. FAIL on any `deleted` qdisc/filter event for `vt-n6`, any link event for `vt-n6` without an XDP program, or different qdisc handles / XDP and filter prog ids afterwards. Most useful with `VT_N6_TXQ ≥ 2` (mq + n fq children) |
| `setup.sh-mq-repair` | fq and `VT_N6_TXQ ≥ 2` only (SKIP otherwise): a plain root `fq` (as an older `setup.sh` left it), then one `mq` child replaced by `pfifo`; each time `setup.sh` must end in the expected state. Then a root `handle 1:` qdisc that is not `mq` (`prio`, else `htb`, else `fq_codel`, whichever the kernel has; someone else's qdisc on the handle `setup.sh` uses for its `mq`): `setup.sh` must exit 3 and change nothing; after deleting it `setup.sh` attaches again |
| `set-A`, `set-B` | `10.45.1.23` rx 10 / tx 20, `10.45.1.24` rx 3 / tx 5 |
| `setup.sh-partial-exit5` | fq only: after `detach.sh`, `setup.sh` runs (as root, with the `VT_XDP_MODE` flag) with a `tc` wrapper first on `PATH` that fails `tc filter replace`: it must exit 5 and print `… may be partially attached …`; `detach.sh` then cleans up and a normal `setup.sh` reaches the expected attach state |
| `setup.sh-txq-grow` | fq and `VT_N6_TXQ < 4 ≤ VT_N6_TXQ_MAX` only (SKIP otherwise), right after `xdp-mode-switch`: `detach.sh`, `ethtool -L vt-n6 tx 2`, `setup.sh`, then `ethtool -L vt-n6 tx 4` **without** re-running `setup.sh`: the expected attach state must hold for all 4 active queues (`setup.sh` puts `fq` on every allocated queue, not only the active ones), and UE-A's `iperf3 -R -P 8` (own server on port 5205) must carry traffic (≥ 2 Mbps) and must not exceed its 20 Mbps tx cap by more than 10% (`counter_verdict.py` on `spec_txq_grow.csv`; under cap is not judged here). A re-run of `setup.sh` then still passes, and the original queue count is restored |
| `xdp-mode-switch` | fq only: `setup.sh vt-n6 --xdp-mode <other>` then `--xdp-mode <VT_XDP_MODE>` (generic → native → generic by default). After each: only the requested slot holds the pinned policer, TC side as expected, UE-A pings are counted in `rx_pkts`. Then `setup.sh --xdp-mode <mode> vt-n6` (flag before the interface) and `--xdp-mode bogus` (exit 1, nothing changed) |
| (iperf3) | Four concurrent sessions from the UE namespaces to `10.99.0.1` ports 5201–5204 (README §8); without fq only the two uplink sessions (`SKIP dl-pacing`). Counter snapshots `stats_t1.txt`/`stats_t2.txt` at 5 s and `T−1` s |
| `setup.sh-rerun-under-load` | fq only: `setup.sh` re-run in the middle of the iperf3 run; the verdicts below cover that moment |
| `iperf-verdict`, `counter-verdict` | `iperf_verdict.py` / `counter_verdict.py` on `spec.csv` (±10%) |
| `d16-tx-segments` | fq only: UE-A `tx_bytes / tx_packets ≤ 1514` (TX counts wire segments) |
| `dl-multiflow-ue-cap` | fq only: UE-A and UE-B each run `iperf3 -R -P 4` (4 downlink flows) at the same time; `counter_verdict.py` on `spec_multiflow.csv` must find each UE's `tx_bytes` rate within ±10% of its tx cap (20 / 5 Mbps), i.e. the cap holds for the sum of the flows, also when they are spread over several `fq` instances. The log lists the bytes each `fq` sent; with `VT_N6_TXQ ≥ 2` and fewer than two queues used it prints a `WARN` (flow hashing put everything on one queue; not a FAIL) |
| `killswitch` | `tx-mbps 0` for UE-B: ping fails, `tx_drops` rises, UE-A unaffected; on fq kernels also survives a `setup.sh` re-run |
| `reset` | UE-B disappears from `list` |
| `d7-reset-clears`, `d26-same-set-keeps-state`, `d26-changed-set-clears` | `reset` removes `rx_state_map`/`tx_tstamp_map` entries; same-value `set` prints `(unchanged; rx/tx state kept)` and keeps them byte-for-byte; a changed rx or tx clears them |
| `d6-small-pkt-no-starvation` | rx 1 Mbps, 64-byte UDP flood: admitted rate 0.9–1.2 Mbps |
| `d4-fwd-overload-then-tcp` | 100 Mbit/s forwarded UDP against tx 1 Mbps: `tx_drops` rise, EDT slot ≤ ~2 s ahead, a TCP session right after still connects (and stays ≤ 1.1 Mbps on fq); rx counters count for an `rx 0` UE |
| `setup.sh-nonroot` | fq only: re-run, `detach.sh`, fresh `setup.sh` as `VT_NONROOT_USER` |
| `unload-refused-while-attached` | `unload` exits non-zero, prints `detach.sh vt-n6`, pins and hooks unchanged |
| `detach-rc` | `detach.sh` as `nobody` exits 4 without changing anything; on a missing interface exits 1 |
| `detach` | `detach.sh vt-n6` leaves no XDP program and no bpf egress filter; on fq kernels also no `fq`/`mq` qdisc (veth's own default is `noqueue`) |
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
| `env.txt` | Kernel (`uname -r`), `no-git` (L1/L2 copy the tree without `.git`; use `commit.txt`. A direct `run-tests.sh` run in a checkout writes `git describe --always --dirty` here), `os=…`, `iproute2=…`, `bpftool=<path used by the test>`, `setup_as=… no_bpftool=…`, `xdp_mode=… (setup.sh args: …) n6_txq=…`, `has_fq=0/1`, `root_pins_before=` (pins left in the bpffs root by older builds) |
| `spec.csv` | The sessions that were run (`label,ue_ip,direction,cap_mbps,json_path`) |
| `a_ul.json`, `b_ul.json`, `a_dl.json`, `b_dl.json` | `iperf3 -J` output of the concurrent sessions (`*_dl.json` only with fq) |
| `verdict.txt` | `iperf_verdict.py` table: steady-state goodput vs cap |
| `verdict_counters.txt` | `counter_verdict.py` table: `rx_bytes`/`tx_bytes` rate between the two snapshots vs cap |
| `stats_t1.txt`, `stats_t2.txt` | `t=<epoch>` + `vantage-5G stats` at 5 s and `T−1` s |
| `stats_after_iperf.txt`, `list.txt` | `stats` after the run, `list` after the two `set`s |
| `attach-before-rerun.txt`, `attach-after-rerun.txt` | `ip -d link`, `tc qdisc`, `tc filter … egress` around the `setup.sh` re-run (fq only) |
| `d4_udp.json`, `d4_tcp.json`, `d6_udp.json` | iperf3 output of the regression steps |
| `spec_txq_grow.csv`, `a_dl_p8.json`, `stats_grow_t1.txt`, `stats_grow_t2.txt`, `verdict_txq_grow.txt` | `setup.sh-txq-grow` inputs and counter verdict |
| `rerun-no-gap.tc`, `rerun-no-gap.link` | `tc monitor` / `ip monitor link` output captured during `setup.sh-rerun-no-gap` |
| `spec_multiflow.csv`, `a_dl_p4.json`, `b_dl_p4.json`, `stats_mf_t1.txt`, `stats_mf_t2.txt` | `dl-multiflow-ue-cap`: spec, iperf3 output and counter snapshots (judged by `counter_verdict.py`; result in `dl-multiflow-ue-cap.log`) |

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
- **Emulated N6 only.** veth pairs, no GTP and no real UPF. `VT_XDP_MODE=native` exercises the veth driver's native XDP and `VT_N6_TXQ` gives veth software TX queues (so the `mq` + per-queue `fq` layout and cross-queue pacing are tested), but a physical NIC driver's native XDP support, its hardware queues and IRQ/XPS mapping, BIG TCP / GRO sizes and the core's NAT behaviour are only checked on the physical server (runbook §6).
- **L3: locally generated TCP on the virtio N6 NIC under-delivers with any shaper.** With iperf3 servers on vantage-svc itself (as README §8 does), a single TCP DL flow paced to a few Mbps reached about 50–85% of the cap in our runs, and the kernel's `fq maxrate` and `tbf` on the same NIC do the same or worse; UDP DL and TCP forwarded through vantage-svc (likely cause: TCP small-queue back-pressure waits for the VM NIC's TX completions; not seen on L2's veth) reach the cap through the same pacer. `b-dl-udp-pacer-control` and `b-dl-kernel-fq-control` record this in every run. The four-session run usually lands within tolerance; a DL row a few percent under is environment when those controls agree. UERANSIM's userspace GTP-U limits the path to tens of Mbps per session under load, hence the small caps.
- **`unload` guard is per network namespace.** Attachments inside the UE/core namespaces would not be seen; the tests attach only in the service-node namespace.
- **`VT_*` on L1.** `l1-docker.sh` forwards them, but without `sch_fq` and without an `ubuntu` user the `setup.sh`-related ones (`VT_SETUP_AS`, `VT_NONROOT_USER`, the `--xdp-mode` steps) only take effect on L2.

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
| `l3-vbox.sh` | L3: `up` / `test` / `ssh-core` / `ssh-svc` / `down` / `delete` (§5a) |
| `vbox/vm-lib.sh` | VirtualBox helpers shared by `l2-vbox.sh` and `l3-vbox.sh` (create VM from the cloud image, wait for SSH/cloud-init, power off, delete) |
| `vbox/core-user-data.tmpl`, `vbox/core-provision.sh`, `vbox/core-ran.sh` | L3 core VM: cloud-init, Open5GS/MongoDB/UERANSIM provisioning, RAN netns and quickstart NAT state |
| `vbox/l3-test.sh` | Body of `l3-vbox.sh test` |
| `run-tests.sh` | Test body shared by L1 and L2 (§8) |
| `netns-topo.sh` | Emulated UE / core / N6 topology (§7) |
| `docker/Dockerfile` | `vantage-dev` image: Ubuntu 24.04, clang/llvm/libbpf, linux-tools, iproute2, iptables, iperf3, tcpdump, Rust (rustfmt, clippy) |
| `vbox/user-data.tmpl` | cloud-init for the L2 VM |
| `../.claude/skills/vantage-testbed/scripts/iperf_verdict.py`, `counter_verdict.py` | Verdict scripts (also used for physical-server results) |
| `../.claude/skills/vantage-boundary-check/scripts/contract_check.py` | L0 contract check |
