# Vantage-5G

Per-UE **RX/TX bandwidth control** for services sitting behind a black-box 5G Core (특화망 / private 5G).
Enforcement runs at the **service node**, via **XDP (RX policer)** and **tc-bpf + EDT (TX pacer)**.
Policy is set **manually by an administrator** through a small Rust CLI writing directly into BPF maps.
Metrics are exported to Prometheus for a dashboard.

---

## Contents

1. [What this is](#1-what-this-is)
2. [Scope (Phase 1, current)](#2-scope-phase-1-current)
3. [Requirements](#3-requirements)
   - [3.1 Host software (service node)](#31-host-software-service-node)
   - [3.2 Network prerequisites (5G core side)](#32-network-prerequisites-5g-core-side)
4. [Build](#4-build)
5. [Bootstrap — one-time load and attach](#5-bootstrap--one-time-load-and-attach)
6. [Set / reset / inspect per-UE policy](#6-set--reset--inspect-per-ue-policy)
7. [Monitor — Prometheus exporter](#7-monitor--prometheus-exporter)
8. [Verification — Phase 1 completion criteria](#8-verification--phase-1-completion-criteria)
9. [Detach & unload](#9-detach--unload)
10. [Troubleshooting](#10-troubleshooting)
11. [Files](#11-files)
12. [CLI reference](#12-cli-reference)
13. [Local development & testing](#13-local-development--testing)
14. [Roadmap](#14-roadmap)

Quick path on a fresh service node: §3.2 (network) → §3.1 (packages) → §4 (`make build`) → §5 (`load`, `setup.sh`) → §6 (`set`) → §8 (measure). A step-by-step install runbook with expected output and failure actions for every step (Korean) is in [`docs/install-runbook.md`](docs/install-runbook.md).

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
- The service node is a **separate server** from the UPF. Vantage only sees what arrives on the service node's N6 NIC, so the UE's own IP address must reach that NIC unchanged (no NAT) and the replies must leave through the same NIC. §3.2 lists what the 5G core side and the service node's routing must provide.

## 2. Scope (Phase 1, current)

- Identification key: **UE IPv4 address** (as seen on N6).
- Policy: `{rx_bps, tx_bps}` per UE. `tx_bps = 0` is an explicit downlink **killswitch**; `rx_bps = 0` means uplink **uncapped** (not blocked). The two zeros are deliberately asymmetric: `set --rx-mbps 0 --tx-mbps 0` blocks downlink only.
- No automation, no policy engine. An admin runs `vantage-5G set …` when they want to change something.
- Enforcement: XDP token-bucket on ingress; tc-bpf EDT pacing on egress (relies on `fq`: root `fq` on a single-queue NIC, one `fq` per TX queue under a root `mq` on a multi-queue NIC).
- Metrics: per-UE RX/TX bytes, packets, drops via Prometheus on port 9090.

Phase 2 (later) will extend the policy key to a 5-tuple LPM_TRIE for micro-segmentation. Not yet in this build.

## 3. Requirements

### 3.1 Host software (service node)

| Component | Minimum |
|---|---|
| OS | Ubuntu 22.04 / 24.04 |
| Kernel | Linux 5.15+ (BTF at `/sys/kernel/btf/vmlinux`) |
| Tools | `clang`, `llvm`, `bpftool` (from `linux-tools-$(uname -r)`), `iproute2` (`tc`, `ip`), `libbpf-dev`, `libelf-dev`, `zlib1g-dev` |
| Toolchain | Rust stable (`rustup`) |
| NIC | Any NIC: `setup.sh` attaches XDP in generic mode (`xdpgeneric`) by default. `--xdp-mode native` (`xdpdrv`) needs driver XDP support (§5). Single- or multi-queue. |
| Privilege | Every `vantage-5G` subcommand (`load`, `unload`, `set`, `reset`, `list`, `stats`, `monitor`) needs root: the pins under `/sys/fs/bpf` are root-only. `setup.sh` / `detach.sh` run as root or as a user with `sudo` rights (they call `sudo` themselves). `make build` runs as a normal user. |

`bpftool` is required by both `make build` (generates `vmlinux.h`) and `setup.sh`. On Ubuntu 22.04 **and** 24.04 there is no installable `bpftool` package (`apt install bpftool` fails with "has no installation candidate"); `/usr/sbin/bpftool` comes from `linux-tools-common` and is only a wrapper that needs the tools package of the **running** kernel, `linux-tools-$(uname -r)`. The same command works on both releases:

```bash
sudo apt-get install -y build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config \
    linux-tools-common "linux-tools-$(uname -r)" iproute2 iperf3 tcpdump ethtool
bpftool version        # must print a version, not "WARNING: bpftool not found for kernel ..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

After a kernel upgrade and reboot, install `linux-tools-$(uname -r)` again for the new kernel (`linux-tools-generic` only tracks the newest generic kernel, which may not be the one running). `make check` checks that `bpftool version` actually runs (not only that a `bpftool` exists on `PATH`).

**Memory and CPU count.** `load` creates four maps. The three per-UE state maps (`rx_state_map`, `tx_tstamp_map`, `ue_stats_map`) are `LRU_HASH` with 16384 entries each; LRU maps cannot be allocated lazily, so all of it — about **4.5 MiB** of kernel memory in total (the `memlock` sum in `bpftool map show` on 6.8; the 5.15 kernel reports a smaller estimate, about 1.5 MiB) — is allocated at `load`, whatever the number of UEs. `ue_policy_map` is a `HASH` of 1024 entries (at most 1024 UEs with a policy; the 1025th `set` fails). On kernels before 6.16 (Ubuntu 22.04's 5.15 and 24.04's 6.8) each CPU that touches an LRU map takes 128 entries for itself, so on a server with **more than 128 CPUs** (`nproc`) active UEs' state can be evicted even with few UEs (a UE then briefly gets a full RX bucket or loses its TX backlog). Up to 128 CPUs, or on 6.16+, this does not happen.

### 3.2 Network prerequisites (5G core side)

Vantage keys every policy on the **UE IP address as it appears on the service node's N6 NIC**, and it shapes downlink only on packets that **leave through that same NIC**. Three things outside Vantage must be true before `set` can have any effect. Check them before installing Vantage; none of them is configured by `setup.sh`.

Example addresses used below (replace with yours):

| Name | Example | Meaning |
|---|---|---|
| `UE_NET` | `10.45.0.0/16` | UE address pool (Open5GS reference install: the `ogstun` subnet) |
| `SVC_NET` | `192.168.100.0/24` | N6 subnet shared by the UPF host and the service node |
| `UPF_N6_IP` | `192.168.100.10` | UPF host's address on `SVC_NET` |
| `SVC_IP` | `192.168.100.20` | Service node's address on its N6 NIC |
| `<IF>` | `enp1s0` | Service node's N6 NIC (the one you pass to `setup.sh`) |

**(1) No NAT for traffic to the service subnet (UPF host).** The Open5GS quickstart adds a masquerade rule so UEs can reach the internet. With it, every UE appears on N6 as `UPF_N6_IP`: `stats` stays empty for the UE addresses and no per-UE policy matches. Look at the rule first:

```bash
# on the UPF host
sudo iptables -t nat -S POSTROUTING
#   e.g.  -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
```

Then either insert an exception in front of it (the `nat` table stops at the first terminating rule, so `ACCEPT` means "leave the source address alone"):

```bash
sudo iptables -t nat -I POSTROUTING 1 -s 10.45.0.0/16 -d 192.168.100.0/24 -j ACCEPT
```

or replace the rule with one that excludes the service subnet:

```bash
sudo iptables -t nat -D POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -d 192.168.100.0/24 ! -o ogstun -j MASQUERADE
```

Check with `sudo iptables -t nat -L POSTROUTING -n -v --line-numbers` (the exception must be listed before the `MASQUERADE` line). If the host uses nftables directly, the same rule is in `sudo nft list ruleset` (`masquerade` in a `postrouting` chain).

The change only affects **new** connections: a connection NATed before it keeps its conntrack entry (established TCP entries live for days) and keeps showing up as `UPF_N6_IP`. Restart the UE sessions, or flush their entries: `sudo apt-get install -y conntrack && sudo conntrack -D -s 10.45.0.0/16` (prints `N flow entries have been deleted`; exits 1 when there was nothing to delete).

These `iptables` commands are not persistent; see "Making (1) and (2) survive a reboot" after (2).

**(2) IP forwarding on the UPF host.** UE packets leave `ogstun` and are routed by the UPF host's kernel to N6:

```bash
# on the UPF host
sysctl net.ipv4.ip_forward                    # must print 1
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-ue-forward.conf
sudo sysctl --system
sudo iptables -S FORWARD | head -1            # "-P FORWARD DROP" (e.g. Docker installed) needs explicit accepts:
sudo iptables -I FORWARD -s 10.45.0.0/16 -d 192.168.100.0/24 -j ACCEPT
sudo iptables -I FORWARD -s 192.168.100.0/24 -d 10.45.0.0/16 -j ACCEPT
```

The UPF host also needs a route to `SVC_NET` (automatic when it is directly connected, as in the example).

**Making (1) and (2) survive a reboot (UPF host).** The `sysctl.d` file above is already persistent; the `iptables` rules are not. Save them **once, after both (1) and (2)**, and pick the method by whether `ufw` manages the firewall:

```bash
sudo ufw status            # "Status: active" -> (A); "inactive" or "command not found" -> (B)
```

- **(A) ufw is active.** Do **not** install `iptables-persistent`: on Ubuntu 24.04 the `ufw` package declares `Breaks: iptables-persistent, netfilter-persistent`, so installing it **removes ufw** without asking. Put the rules into ufw instead. Add a `*nat` block at the top of `/etc/ufw/before.rules`, before its `*filter` line (if a `*nat` block already exists, add the `ACCEPT` line to it, above its `MASQUERADE` line), allow the forwarding with `ufw route`, and reload:

  ```
  *nat
  :POSTROUTING ACCEPT [0:0]
  -A POSTROUTING -s 10.45.0.0/16 -d 192.168.100.0/24 -j ACCEPT
  -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
  COMMIT
  ```

  ```bash
  sudo ufw route allow from 10.45.0.0/16 to 192.168.100.0/24
  sudo ufw route allow from 192.168.100.0/24 to 10.45.0.0/16
  sudo ufw reload
  sudo iptables -t nat -L POSTROUTING -n --line-numbers     # ACCEPT listed above MASQUERADE
  ```

  ufw re-creates these rules at boot, so the manual `iptables` commands of (1) and (2) are then no longer needed.

- **(B) ufw is not used.** First check what the install would remove, then install and save:

  ```bash
  sudo apt-get -s install iptables-persistent | grep -A3 REMOVED   # no output = nothing is removed
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  sudo netfilter-persistent save                                    # writes /etc/iptables/rules.v4 and rules.v6
  ```

  Without `DEBIAN_FRONTEND=noninteractive` the install stops at a debconf dialog ("Save current IPv4 rules?") even with `-y`; either answer is fine because `netfilter-persistent save` runs afterwards. If the dry run lists `ufw` under REMOVED and you still need ufw, use (A). Run `netfilter-persistent save` again after any later rule change.

**(3) Return route on the service node.** Replies to UEs must go back to the UPF **through the N6 NIC Vantage is attached to**; the TX pacer (and the killswitch) is a tc egress hook on that NIC only.

```bash
# on the service node
sudo ip route add 10.45.0.0/16 via 192.168.100.10 dev enp1s0
ip route get 10.45.0.2                        # must print "... via 192.168.100.10 dev enp1s0 ..."
```

`ip route add` is lost on reboot. To make it persistent with netplan, **merge** the route into the configuration; do not overwrite your existing file under `/etc/netplan/` (it may hold DHCP, the gateway, DNS or other interfaces). The safest way is a separate drop-in that contains only the route; netplan merges all files in `/etc/netplan/` in lexical order:

```bash
printf '%s\n' 'network:' '  version: 2' '  ethernets:' '    enp1s0:' '      routes:' \
    '        - to: 10.45.0.0/16' '          via: 192.168.100.10' \
    | sudo tee /etc/netplan/90-vantage-ue-route.yaml
sudo chmod 600 /etc/netplan/90-vantage-ue-route.yaml
sudo netplan get ethernets.enp1s0      # merged result: your existing addresses/dhcp4 plus the new route
sudo netplan try                       # press Enter before the timeout to keep it; no separate apply needed
ip route show 10.45.0.0/16
```

The drop-in file then reads:

```yaml
network:
  version: 2
  ethernets:
    enp1s0:
      routes:
        - to: 10.45.0.0/16
          via: 192.168.100.10
```

- The interface key (`enp1s0`) must be the same ID your existing file uses for the N6 NIC.
- If the existing file already has a `routes:` list for that interface, add the `- to: … via: …` item to that list instead of using the drop-in (the same key in a later file replaces the earlier one rather than appending to it). Check with `sudo netplan get ethernets.enp1s0` that every route is there.
- If `netplan try` reverts (timeout, or your SSH session dropped), **do not** run `netplan apply`; fix the file first.

If the service node's default route already points at `UPF_N6_IP` through `<IF>`, no extra route is needed (`ip route get` above tells you).

**Check end to end** (before or after installing Vantage). On the UE host, send traffic from the UE interface (see §8.1 for finding it); on the service node, watch the N6 NIC:

```bash
# UE host
ping -I uesimtun0 -c 5 192.168.100.20
# service node
sudo tcpdump -ni enp1s0 net 10.45.0.0/16 -c 10
```

Expected: `IP 10.45.x.y > 192.168.100.20: ICMP echo request` **and** `IP 192.168.100.20 > 10.45.x.y: ICMP echo reply` on `enp1s0`. If the source is `192.168.100.10` (the UPF) instead, NAT is still active — fix (1). If requests show up but no replies leave on `enp1s0`, fix (3). If nothing shows up, check (2) and that the UE has a PDU session.

## 4. Build

```bash
git clone https://github.com/uni2u/vantage-5g.git
cd vantage-5g

make check      # verifies cargo / clang / tc / ip / BTF, and that `bpftool version` actually runs
make build      # produces vantage_rx_policer.o, vantage_tx_pacer.o, target/release/vantage-5G
```

Artifacts:

```
vantage_rx_policer.o      # XDP RX policer (per-UE token bucket)
vantage_tx_pacer.o        # tc-bpf egress + EDT (per-UE pacer, killswitch)
target/release/vantage-5G # Rust CLI
```

Makefile targets: `make check` (prints `OK: all required tools and BTF are available.` or the missing piece), `make build` (= `bpf` + `rust`), `make bpf` (only the two `.o` files and `vmlinux.h`), `make rust` (`cargo build --release`), `make clean` (removes the `.o` files, `vmlinux.h` and `cargo clean`). `vmlinux.h` is generated from the running kernel's BTF; after a kernel upgrade run `make clean && make build`. The BPF objects are built with `-D__TARGET_ARCH_x86` by default (`TARGET_ARCH ?= x86`); only x86_64 has been tested.

## 5. Bootstrap — one-time load and attach

Do these in order on the **service node**. `load` needs `vantage_rx_policer.o` and `vantage_tx_pacer.o` from `make build`; it takes them from the first of these directories that holds **both**: the repository root of the executable (`<exe dir>/../..`, i.e. the checkout when you run `<repo>/target/release/vantage-5G` or a symlink to it), the executable's own directory, and only as a last resort the current directory (so `.o` files lying in the directory you happen to run it from, e.g. `/tmp` or an older checkout, never take precedence over the ones built with the binary). So `load` works from any directory as long as the binary stays in `<repo>/target/release/`. If you copied the binary elsewhere, put the two `.o` files next to it or pass `--obj-dir <DIR>` (that directory only, no search). The first output line names the directory used (`[i] BPF objects from /home/ops/vantage-5g`).

```bash
# 1) Load & pin BPF programs and maps into /sys/fs/bpf/vantage/.
sudo ./target/release/vantage-5G load

# 2) Attach the pinned programs to your N6-facing NIC.
#    Replace enp1s0 with whatever interface faces the 5G Core (N6) — <IF> in §3.2.
sudo ./setup.sh enp1s0
#    or, with XDP in driver (native) mode:
sudo ./setup.sh enp1s0 --xdp-mode native
```

`sudo ./setup.sh <iface> [--xdp-mode generic|native]` (`--xdp-mode=native` also works; options and the interface may come in any order; `-h` prints the usage):

- `generic` (default) attaches XDP with `xdpgeneric`, which works on every driver.
- `native` attaches with `xdpdrv` and needs driver XDP support (e.g. veth, virtio_net, ixgbe, i40e, ice, mlx5). If the driver refuses, `setup.sh` prints the kernel's message and the driver name, suggests `--xdp-mode generic` and exits 3 without changing anything.
- If a Vantage program is already attached in the other mode, `setup.sh` detaches it and attaches in the requested mode. The kernel does not allow generic and native at the same time, so RX policing pauses for that moment. If the new attach fails, the previous mode is restored with the **pinned** program and `setup.sh` exits 3 (exit 4 if even the restore fails: the NIC then has no RX policer). If the program attached before was one from an earlier `load`, its prog id changes with that restore. On several physical drivers a native attach/detach reconfigures the rings, which resets the link briefly.

`load` is needed once per boot (pins under `/sys/fs/bpf` do not survive a reboot), and so is `setup.sh`. Policies are stored in the pinned map, so they are lost on reboot as well; re-run `set` for every UE afterwards.

What `setup.sh` does:

0. Pre-flight: refuses (exit 3, nothing changed) if the NIC already has an XDP program (generic or native) that is not Vantage's, an XDP program in offload or multi mode, a non-Vantage egress filter at pref 1, a classic `ingress` qdisc, a qdisc using handle `1:` when a root `mq 1:` has to be created (multi-queue NIC, e.g. a root `prio 1:` or `htb 1:`; remove it with `sudo tc qdisc del dev <iface> root` if nothing needs it, and re-run), or if a kernel module it needs is not available (`sch_fq`, `cls_bpf`, and `sch_ingress` when `clsact` is not there yet; the check is skipped where `modprobe` or `/lib/modules/$(uname -r)` is missing, e.g. in containers). It warns if `/run/vantage-5g.default_qdisc` exists (see the cautions below). Attached programs are identified by id against the pinned programs (`bpftool prog show pinned`), or by their kernel name via `bpftool prog show id N` (a Vantage program left from an earlier `load`), so this also works with iproute2 5.15 (Ubuntu 22.04), which prints no program names. `bpftool` is required: without a working one `setup.sh` exits 2 before changing anything (install `linux-tools-$(uname -r)`, see §3).
1. XDP: `ip -force link set dev <iface> xdpgeneric|xdpdrv pinned /sys/fs/bpf/vantage/vantage_rx_policer` — atomic replace on re-run in the same mode; a mode switch as described above. XDP comes first because it is the only step a driver can refuse (native mode); nothing else has been changed at that point.
2. TX qdisc, by the number of TX queues N (`/sys/class/net/<iface>/queues/tx-*`):
   - N = 1: `tc qdisc replace dev <iface> root fq`.
   - N ≥ 2: root `mq` with handle `1:` and an `fq` on **every mq class** `1:1` … `1:<M>` (hex), where M is `numtxqueues` from `ip -d link` — the allocated TX queues, including those not in use yet. A later `ethtool -L` that raises the channel count therefore needs no `setup.sh` re-run: the new queues are already paced. If the root is already `mq` (any handle) with `fq` on every class, nothing is changed. Otherwise the root `mq 1:` is created once; while that single `tc` command runs, `net.core.default_qdisc` is set to `fq` (if it is something else) so that `mq` creates its children as `fq` from the start, and is restored right after (also on HUP/INT/TERM). Classes whose child is still not `fq` (classes of queues not in use, or when the sysctl cannot be written, as in a container) get `tc qdisc replace … parent 1:<class> fq` in one `tc -batch`.
   `fq` honours `skb->tstamp`, which the pacer sets (EDT).
3. `tc qdisc add dev <iface> clsact` only if missing — hook point for the tc-bpf egress filter (never deleted by `setup.sh`).
4. `tc filter replace dev <iface> egress protocol all pref 1 handle 1 bpf da pinned /sys/fs/bpf/vantage/vantage_tx_pacer` — atomic replace on re-run; stale Vantage pacers at other prefs (left by older `setup.sh`) are removed afterwards.
5. Verifies the result (XDP in the requested mode with the pinned program id; root `fq`, or root `mq` with `fq` on every mq class; `clsact`; exactly one Vantage egress filter with the pinned program id) and exits 4 if it is not as expected.

If a command fails in steps 1–4, after something was already changed, `setup.sh` exits 5 with `[-] step failed (status N, setup.sh line L) after <iface> was already changed.` and `<iface> may be partially attached`. Run `sudo ./detach.sh <iface>`, fix the cause shown, and re-run.

Re-running `setup.sh` on an attached NIC in the same mode is safe: no hook is removed at any point, and an existing root `mq` with `fq` on every class is left untouched.

Cautions:

- **Switching cost (first run only).** The first switch of a multi-queue NIC to `mq` + `fq` — from the kernel's default root `mq`, from a single root `fq` left by an older `setup.sh`, or from an older layout with `fq` only on the queues in use — replaces qdiscs. Every root or per-class qdisc replacement briefly deactivates the whole device and drops the packets queued in **all** its TX queues (while pacing, a few dozen TCP retransmissions in the local test). Later re-runs do not touch the qdisc.
- **`net.core.default_qdisc`.** Creating the root `mq` sets this global sysctl to `fq` for the duration of one `tc` call (a few ms); any other device that creates its default qdisc in that moment gets `fq` as well. `setup.sh` restores the value right after, also on HUP/INT/TERM, and leaves it alone with a warning if something else changed it meanwhile. If `setup.sh` is killed in that window (SIGKILL, OOM, power loss) the value stays `fq`; the original is kept in `/run/vantage-5g.default_qdisc` and the next run warns. To fix: `sudo sysctl -w net.core.default_qdisc=<original>; sudo rm /run/vantage-5g.default_qdisc`.

Exit codes: `0` attached and verified, `1` usage (missing interface, unknown option, invalid `--xdp-mode` value) / no such interface, `2` programs not loaded (`load` first) or `bpftool` not usable, `3` refused, nothing changed (conflicting hook, qdisc on handle `1:`, missing kernel module, or the driver rejected the XDP attach, e.g. no native XDP; exception: a failed mode switch restores the previous mode with the pinned program), `4` post-attach check failed (current state is printed), or a failed mode switch could not be rolled back, `5` a change step failed after something was already changed (partially attached: `detach.sh`, fix, re-run). `setup.sh` may be run as root or by a user with `sudo` rights (`./setup.sh enp1s0`). Full table with messages: §12.9.

Successful output ends with:

```
[+] Vantage-5G attached to enp1s0.
    - RX policer (XDP generic, id 18): /sys/fs/bpf/vantage/vantage_rx_policer
    - TX pacer  (tc egress pref 1): /sys/fs/bpf/vantage/vantage_tx_pacer
    - TX qdisc  root fq
```

(On a multi-queue NIC the last line reads e.g. `TX qdisc  root mq 1: + fq on all 8 mq classes (4 TX queues in use)`.)

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

- `--rx-mbps` / `--tx-mbps` accept 0–400000 (400 Gbps); anything else is rejected by the argument parser (exit 2). 1 Mbps = 1 000 000 bit/s.
- `set` resets the UE's RX token bucket (`rx_state_map`) and TX EDT slot (`tx_tstamp_map`) only when the policy value (rx or tx) changes, so a new rate applies from the next packet instead of inheriting an old backlog; the UE then starts with a full bucket (250 ms of its RX rate, at least 67 050 bytes). Setting the same values again only rewrites the policy and keeps the state (the output ends with `(unchanged; rx/tx state kept)`), so re-applying policies periodically causes no burst and does not forget a backlog. `reset` always removes the policy and the state together. To force a state reset, run `reset` and then `set`.
- `reset` of a UE without a policy prints `no policy for UE … (nothing to clear)` and exits 0; any other failure (e.g. not root) exits non-zero.
- Counters (`stats`) are kept after `reset`; they are only counted while the UE has a policy.
- The UE address must be the one seen on N6 (§3.2). With UERANSIM it is the address of the UE's `uesimtunN` interface (§8.1).

Output of each command: §12.

## 7. Monitor — Prometheus exporter

```bash
sudo ./target/release/vantage-5G monitor           # binds 0.0.0.0:9090
# or a different port:
sudo ./target/release/vantage-5G monitor --port 9191
# scrape the BPF maps every 5 s instead of every 1 s:
sudo ./target/release/vantage-5G monitor --scrape-ms 5000
# listen on localhost only (or one interface address; IPv6 e.g. ::1; :: = all IPv6 addresses,
# and IPv4 too while sysctl net.ipv6.bindv6only=0, the Linux default):
sudo ./target/release/vantage-5G monitor --bind 127.0.0.1
```

The exporter runs in the foreground and serves `http://<bind>:<port>/metrics`. By default it listens on **all IPv4 addresses** (`--bind 0.0.0.0`); `--bind` takes one IPv4 or IPv6 address (no hostname, no CIDR). `--port` accepts `1..=65535`, `--scrape-ms` (time between BPF map reads) `100..=60000`; anything else is rejected with exit 2. If you keep the default bind, restrict access with a firewall when the node is reachable from untrusted networks. Quick check: `curl -s localhost:9090/metrics | grep '^vantage_'`.

Exposed series (all labeled with `ue_ip`):

```
vantage_ue_rx_bytes_total       # L2 bytes admitted by the RX policer
vantage_ue_rx_packets_total     # frames admitted by the RX policer (generic mode: after GRO, one merged frame = 1)
vantage_ue_rx_drops_total       # dropped by the RX policer
vantage_ue_tx_bytes_total       # L2 bytes scheduled by the TX pacer
vantage_ue_tx_packets_total     # wire segments (a GSO packet counts gso_segs)
vantage_ue_tx_drops_total       # downlink drops: killswitch, or EDT horizon > 2 s (segments)
vantage_ue_policy_rx_bps        # configured RX cap (0 = uncapped)
vantage_ue_policy_tx_bps        # configured TX cap (0 = killswitch)
```

Example scrape:

```
vantage_ue_policy_rx_bps{ue_ip="10.45.1.23"} 10000000
vantage_ue_policy_tx_bps{ue_ip="10.45.1.23"} 20000000
vantage_ue_rx_bytes_total{ue_ip="10.45.1.23"} 294
vantage_ue_rx_drops_total{ue_ip="10.45.1.23"} 0
vantage_ue_rx_packets_total{ue_ip="10.45.1.23"} 3
vantage_ue_tx_bytes_total{ue_ip="10.45.1.23"} 294
vantage_ue_tx_drops_total{ue_ip="10.45.1.23"} 0
vantage_ue_tx_packets_total{ue_ip="10.45.1.23"} 3
```

- RX bytes and packets count only **admitted** frames; dropped frames are counted only in `rx_drops`, so the RX drop ratio is `rx_drops / (rx_packets + rx_drops)`.
- RX and TX packet counts are not directly comparable: TX counts wire segments, RX counts the frames the XDP hook admits, which in generic mode is after GRO.
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

Multi-queue NICs need nothing extra: the tc egress BPF program runs before the TX queue is picked, the `fq` on each TX queue honours the `skb->tstamp` it set, and each UE has one EDT slot shared by all queues, so a UE's flows spread over several queues together stay within its cap.

Assumption: two UEs registered through UERANSIM (UE-A, UE-B), Vantage loaded and attached on the service node (§5), the network prerequisites of §3.2 in place, and the service reachable at `SVC` (the service node's N6 address). The examples use `10.45.1.23` / `10.45.1.24`; **use the addresses your SMF actually assigned** (§8.1).

### 8.1 Find the UE addresses (UE host)

UERANSIM's `nr-ue` creates one TUN interface per PDU session, `uesimtun0`, `uesimtun1`, … whose address is the UE IP the core assigned.

```bash
ip -br -4 addr show | grep uesimtun          # e.g. "uesimtun0  UNKNOWN  10.45.0.2/32"
ip -4 addr show uesimtun0
```

Traffic only takes the 5G path if it is sent **from** that address. A plain `iperf3 -c $SVC` on the UE host uses the host's normal interface and bypasses the core entirely (Vantage then sees the UE host's LAN address, not the UE). Check that the UE address routes into the tunnel:

```bash
ip route get 192.168.100.20 from 10.45.0.2   # must print "... dev uesimtun0 ..."
```

### 8.2 Service node — policies and servers

```bash
UE_A=10.45.1.23; UE_B=10.45.1.24              # from 8.1

sudo ./target/release/vantage-5G set --ue-ip $UE_A --rx-mbps 10 --tx-mbps 20
sudo ./target/release/vantage-5G set --ue-ip $UE_B --rx-mbps  3 --tx-mbps  5
sudo ./target/release/vantage-5G list

# One iperf3 server per direction per UE (-D = daemon).
iperf3 -s -p 5201 -D   # UE-A uplink
iperf3 -s -p 5202 -D   # UE-B uplink
iperf3 -s -p 5203 -D   # UE-A downlink (client uses -R)
iperf3 -s -p 5204 -D   # UE-B downlink (client uses -R)
```

### 8.3 UE host — four concurrent clients bound to the UE interfaces

Bind each client to its UE address with `-B` (iperf3 then sends from that address, and both the uplink data and the `-R` downlink data use the 5G path checked in 8.1). `-J` writes JSON for the verdict in 8.5.

```bash
SVC=192.168.100.20; UE_A=10.45.1.23; UE_B=10.45.1.24
mkdir -p ~/vt-iperf && cd ~/vt-iperf
iperf3 -c $SVC -B $UE_A -p 5201 -t 30    -J > a_ul.json &   # UL — expect ~10 Mbps
iperf3 -c $SVC -B $UE_A -p 5203 -t 30 -R -J > a_dl.json &   # DL — expect ~20 Mbps
iperf3 -c $SVC -B $UE_B -p 5202 -t 30    -J > b_ul.json &   # UL — expect ~3 Mbps
iperf3 -c $SVC -B $UE_B -p 5204 -t 30 -R -J > b_dl.json &   # DL — expect ~5 Mbps
wait
```

If `ip route get … from <UE_IP>` in 8.1 did not print `dev uesimtunN`, use UERANSIM's `nr-binder` helper (in UERANSIM's `build/` directory), which runs a program with its sockets bound to the given UE address:

```bash
cd ~/UERANSIM/build
./nr-binder 10.45.1.23 iperf3 -c 192.168.100.20 -p 5201 -t 30 -J > ~/vt-iperf/a_ul.json
```

The two UEs may be on the same UERANSIM host (different `uesimtunN`) or on different hosts; what matters is that the four sessions start **at the same time**.

### 8.4 Service node — counter snapshots during the run

Take two `stats` snapshots inside the 30 s window (after slow start), each preceded by a `t=<epoch>` line; `counter_verdict.py` (8.5) reads exactly this format. Start this right after the clients:

```bash
mkdir -p ~/vt-iperf
( sleep 5;  { echo "t=$(date +%s.%N)"; sudo ./target/release/vantage-5G stats; } > ~/vt-iperf/stats_t1.txt
  sleep 20; { echo "t=$(date +%s.%N)"; sudo ./target/release/vantage-5G stats; } > ~/vt-iperf/stats_t2.txt ) &
```

You can also watch the counters live:

```bash
sudo watch -n1 './target/release/vantage-5G stats'
```

### 8.5 Judge the result

Pass criterion: each session settles within ±10% of its configured cap, and UE-A's traffic does not visibly disturb UE-B's rate (or vice versa).

What the cap counts: **all L2 bytes the UE sends (RX) or receives (TX), Ethernet/IP/TCP headers and the TCP ACKs of the opposite-direction session included.** iperf3 reports payload goodput, so it reads a few percent below the cap even when enforcement is exact (about 4.4% header overhead at 1500 MTU, plus ACKs: an uplink session also carries the ACKs of the same UE's downlink session, and vice versa). The exact check is the counter rate: two `stats` snapshots taken during the run, `(rx_bytes₂ − rx_bytes₁) × 8 / Δt` for uplink and the same with `tx_bytes` for downlink, should be within about 1% of the cap.

Two scripts in this repository do both checks. Put the four JSON files, the two `stats_t*.txt` files and a `spec.csv` in one directory (copy the JSON files from the UE host), e.g. `~/vt-iperf/`:

```
label,ue_ip,direction,cap_mbps,json_path
A-UL,10.45.1.23,UL,10,a_ul.json
B-UL,10.45.1.24,UL,3,b_ul.json
A-DL,10.45.1.23,DL,20,a_dl.json
B-DL,10.45.1.24,DL,5,b_dl.json
```

`json_path` is relative to the directory of `spec.csv`; `cap_mbps` is the `--rx-mbps` value for `UL` rows and the `--tx-mbps` value for `DL` rows; `ue_ip` must match the `stats` rows. Then, from the repository directory (Python 3.8+, no extra packages):

```bash
python3 .claude/skills/vantage-testbed/scripts/iperf_verdict.py   ~/vt-iperf/spec.csv
python3 .claude/skills/vantage-testbed/scripts/counter_verdict.py ~/vt-iperf/spec.csv \
        ~/vt-iperf/stats_t1.txt ~/vt-iperf/stats_t2.txt
```

Example (Ubuntu 22.04 VM, local testbed):

```
label        ue_ip           dir      cap    steady   end_avg    err%     CV  verdict
A-UL         10.45.1.23      UL      10.0      9.59      9.76    -4.1   0.33  PASS — unstable CV>0.15
B-UL         10.45.1.24      UL       3.0      2.92      2.88    -2.7   0.35  PASS — unstable CV>0.15
A-DL         10.45.1.23      DL      20.0     19.81     19.84    -0.9   0.00  PASS
B-DL         10.45.1.24      DL       5.0      4.88      4.89    -2.3   0.00  PASS

sessions=4 fail=0  (tol=±10%, skip=5.0s)

window 14.01 s (counter deltas between the two snapshots)
label        ue_ip           dir      cap    counter    err%  verdict
A-UL         10.45.1.23      UL      10.0     10.009    +0.1  PASS (rx_bytes)
B-UL         10.45.1.24      UL       3.0      3.004    +0.1  PASS (rx_bytes)
A-DL         10.45.1.23      DL      20.0     19.983    -0.1  PASS (tx_bytes)
B-DL         10.45.1.24      DL       5.0      5.002    +0.0  PASS (tx_bytes)

fail=0  (tol=±10%, L2 bytes incl. ACKs)
```

How to read it:

- `iperf_verdict.py`: `steady` = mean of the per-second intervals after `--skip` seconds (default 5; drops TCP slow start and the policer's initial burst), `err%` = (steady − cap) / cap, PASS within `--tol` (default 0.10). `CV` = stdev/mean of those intervals; above `--cv-warn` (default 0.15) the row is flagged `unstable` but not failed (uplink TCP against a policer saw-tooths). A `cap_mbps` of `0` row is a killswitch check: PASS if ≤ `--kill-max` Mbps (default 0.1) or if iperf3 could not connect at all. Exit code 1 if any row fails.
- `counter_verdict.py`: rate of `rx_bytes` (UL rows) or `tx_bytes` (DL rows) between the two snapshots; this is the number the cap governs, so expect ±1%. Rows with cap 0 are reported as `INFO`. Exit code 1 if any capped row is outside `--tol` (default 0.10).
- **Over cap** (positive error beyond tolerance) means shaping is not applied to that traffic: check that `stats` shows the UE address at all (NAT, §3.2), that the iperf3 client was bound to the UE address (8.1), that `<IF>` has root `fq`, or root `mq` with `fq` on every TX queue (`tc qdisc show dev <IF>`) and that `ip route get <UE_IP>` on the service node leaves through `<IF>`.
- **Under cap** with the counters also under cap means the bottleneck is elsewhere (radio / UERANSIM / UPF CPU); compare with a run after `reset` of both UEs (no shaping) to see the path's own capacity.

## 9. Detach & unload

```bash
sudo ./detach.sh enp1s0                        # remove tc filter, XDP, clsact, root qdisc
sudo ./target/release/vantage-5G unload         # remove pinned programs & maps
```

- Order matters: `unload` refuses (exit 1, pins untouched) while a Vantage program is still attached to any interface in the current network namespace, and prints `run: sudo ./detach.sh <iface>`. It does not see attachments in other network namespaces.
- `detach.sh` removes every egress filter on the interface (not only Vantage's), XDP in both the generic and the native slot, `clsact` and the root qdisc (`fq`, or `mq 1:` with its per-queue `fq`). The kernel then re-creates its default root: on a multi-queue NIC an `mq` (handle `0:`) with one `net.core.default_qdisc` child per TX queue, on a single-queue NIC the `net.core.default_qdisc`, on veth and other no-queue devices `noqueue`. A custom root qdisc that existed before `setup.sh` is **not** restored. It then checks the interface: exit 0 nothing left, exit 1 no such interface, **exit 4** an XDP program, egress filter, `clsact` or `setup.sh`'s root `mq 1:` is still there (listed; e.g. run without root/sudo). Do not `unload` after exit 4.

## 10. Troubleshooting

**`skb->tstamp` seems to be ignored (TX pacing has no effect)** — the packets do not go through an `fq`. `setup.sh` sets it up, but if you attach manually make sure `tc qdisc show dev <iface>` prints `qdisc fq … root` on a single-queue NIC, or `qdisc mq … root` plus one `qdisc fq … parent <mq handle>:<class>` for **every** mq class on a multi-queue NIC (a queue with `fq_codel` or `pfifo_fast` sends unpaced). Re-running `setup.sh` fixes the classes that are not `fq`.

**`setup.sh --xdp-mode native` exits 3 with `XDP attach in native mode failed`** — the driver (named in the message; `virtual device` for interfaces without one) does not accept native XDP, or a driver limit (MTU, queue count) prevents it. Nothing was changed (a generic attach that was there is restored). Use the default `--xdp-mode generic`.

**`open pinned ue_policy_map (run `vantage-5G load` first; needs root)`** — the CLI can't open the pinned map: either nothing is loaded (run `sudo ./target/release/vantage-5G load`, once per boot) or the command was run without `sudo`.

**`load` fails with `Error: BPF object files not found`** — none of the searched directories holds both `.o` files; the lines above the error list every directory tried, in search order (`<exe dir>/../..`, the executable's directory, the current directory), and which file is missing in each. Usually `make build` was not run (or only `make rust`), or the binary was copied out of `<repo>/target/release/` without the `.o` files. Run `make build`, or pass the directory explicitly: `sudo vantage-5G load --obj-dir /path/to/objs` (§5).

**`setup.sh` exits 2 with `bpftool is not usable`** — install `linux-tools-$(uname -r)` (§3); `bpftool version` must work.

**`ip link set … xdpgeneric` succeeds but nothing hits XDP** — the interface may be a virtual link of the wrong kind. Try attaching to the physical N6 NIC directly (not a bridge or VF representor).

**`stats` stays empty for a UE although traffic flows** — the N6 interface may not see the UE's IP at all: a core that NATs UE traffic (e.g. the Open5GS quickstart's `MASQUERADE` rule) makes every UE appear as the UPF's address. Check with `sudo tcpdump -ni <iface> host <UE_IP> -c 5`; if only the UPF address shows up, exclude the service subnet from the core's NAT (§3.2 (1)). Also check that the client on the UE host was bound to the UE address (§8.1); otherwise the traffic never entered the 5G path.

**UE traffic arrives (`stats` rx_bytes rises) but the UE gets no replies / iperf3 cannot connect** — XDP counts packets before the kernel routes them, so rising rx counters only prove the request arrived. The replies are not getting back: check `ip route get <UE_IP>` on the service node (§3.2 (3)), and the UPF host's forwarding (§3.2 (2)).

**Downlink is not shaped although uplink is** — the replies leave through a different NIC than the one passed to `setup.sh` (e.g. via the default gateway). `ip route get <UE_IP>` must print `dev <iface>`; add the return route (§3.2 (3)).

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

**`set` fails with `update ue_policy_map for … Argument list too long (os error 7)`** — the policy map is full (1024 UEs, §3.1). `reset` UEs that no longer need a policy; updating a UE that already has one still works.

**`monitor` fails with `can not start http server: Address already in use`** — another process (often a second `monitor`) holds the port on that address; pick another with `--port`. A `--bind` address that is not configured on the host fails the same way with `Cannot assign requested address`.

**`ue_policy_map`, `ue_stats_map`, `rx_state_map` or `tx_tstamp_map` directly under `/sys/fs/bpf`** — left by a build older than the `/sys/fs/bpf/vantage/` layout; `unload` only cleans `/sys/fs/bpf/vantage/`. After `detach.sh` + `unload`, remove them with `sudo rm -f /sys/fs/bpf/{ue_policy_map,ue_stats_map,rx_state_map,tx_tstamp_map}`.

## 11. Files

| Path | Role |
|---|---|
| `vantage_rx_policer.c` | XDP program: per-UE token-bucket RX policer. |
| `vantage_tx_pacer.c`   | tc-bpf egress program: per-UE EDT TX pacer + killswitch. |
| `src/main.rs`          | Rust CLI: `load`, `unload`, `set`, `reset`, `list`, `stats`, `monitor`. |
| `Cargo.toml`           | Rust deps: `libbpf-rs`, `libbpf-sys`, `prometheus`, `prometheus_exporter`, `lazy_static`, `clap`, `anyhow`. |
| `Makefile`             | `make check / build / bpf / rust / clean`. |
| `setup.sh`             | Attach pinned programs to a NIC (`--xdp-mode generic\|native`), set root `fq` or root `mq` + per-queue `fq`. |
| `detach.sh`            | Undo `setup.sh`. |
| `docs/install-runbook.md` | Step-by-step install and measurement runbook for a physical Ubuntu server (Korean): command / expected result / on failure for each step. |
| `testbed/`             | Local test harness (Docker and VirtualBox VM); see [`testbed/README.md`](testbed/README.md) and §13. |
| `.claude/`             | Development-agent configuration (agents and skills). Also holds the result-judging scripts used in §8.5: `.claude/skills/vantage-testbed/scripts/iperf_verdict.py`, `counter_verdict.py`. Not needed to build or run Vantage. |
| `CLAUDE.md`            | Notes for the development agents (Korean). Not needed to build or run Vantage. |

Legacy / not built — kept for reference only; `make build` does not compile them and nothing in the current CLI or scripts uses them:

| Path | What it is |
|---|---|
| `README_old.md` | README of an earlier design (tc telemetry sniffer, `fentry` TCP retransmit counter, Tokio, `kube-rs`/Cilium EDT). **It does not describe the current design**: none of those programs, maps or commands exist in this build. Use this README. |
| `history.md` | Historical design log. Not required for build or operation. |
| `install_k8s_singlenode.md` | Optional single-node K8s setup notes (only if you run the service in K8s); not part of the Vantage install. |
| `iperf3-deployment.yaml` | K8s iperf3 workload from the earlier design (used only when the service happens to run inside K8s). |
| `vantage_datapath.c`, `vantage_datapath.bpf.c`, `vantage_dynamic_edt.c`, `vantage_ringbuf_edt.c` | Earlier datapath experiments (Cilium ipcache lookups, ring-buffer telemetry, per-tenant EDT). Not built. |
| `ready.sh` | Earlier K8s script that attached the old telemetry sniffer to an iperf3 pod's `lxc` interface. References programs that no longer exist; use `setup.sh`. |

## 12. CLI reference

`target/release/vantage-5G` (version `0.2.0`, `vantage-5G --version`). All subcommands need root (§3.1).

```
$ ./target/release/vantage-5G --help
Vantage-5G per-UE RX/TX bandwidth control

Usage: vantage-5G <COMMAND>

Commands:
  load     Load & pin the RX/TX BPF objects (idempotent). Programs remain in the kernel after this command exits; use setup.sh to attach them to an iface
  unload   Remove all Vantage pins. Refuses while a Vantage program is still attached to an interface in this network namespace (run detach.sh first)
  set      Set per-UE RX/TX bandwidth limits (in Mbps, 0..=400000). rx_mbps=0 means "RX uncapped", tx_mbps=0 means "block DL"
  reset    Clear the policy for a UE (drop from map; traffic bypasses shaping)
  list     Print every UE currently in the policy map
  stats    Print RX/TX counters for one UE (or all UEs when --ue-ip is omitted)
  monitor  Run the Prometheus exporter (foreground). Scrapes pinned stats maps
  help     Print this message or the help of the given subcommand(s)

Options:
  -h, --help     Print help
  -V, --version  Print version
```

### 12.1 Exit codes (all subcommands)

| Code | Meaning | Output |
|---|---|---|
| `0` | Success (also `--help`, `--version`). | stdout |
| `1` | Runtime error: pins missing, not root, map full, load refused, unload refused, port in use, … | `Error: <what>` and `Caused by:` lines on stderr |
| `2` | Argument error (unknown option or subcommand, missing required option, value out of range, malformed IP address). | `error: …` on stderr, e.g. `error: invalid value '…' for '--…'` or `error: the following required arguments were not provided:`, always followed by `For more information, try '--help'.` |

### 12.2 Options

| Subcommand | Option | Type / range | Default | Required |
|---|---|---|---|---|
| `set` | `--ue-ip <UE_IP>` | IPv4 address, dotted quad (`10.45.1.23`) | — | yes |
| `set` | `--rx-mbps <RX_MBPS>` | integer `0..=400000`; `0` = uplink uncapped | — | yes |
| `set` | `--tx-mbps <TX_MBPS>` | integer `0..=400000`; `0` = downlink killswitch | — | yes |
| `reset` | `--ue-ip <UE_IP>` | IPv4 address | — | yes |
| `stats` | `--ue-ip <UE_IP>` | IPv4 address | all UEs | no |
| `load` | `--obj-dir <DIR>` | directory holding both `vantage_rx_policer.o` and `vantage_tx_pacer.o`; only this directory is used (no search) | search: `<exe dir>/../..` → exe dir → current dir (§12.3) | no |
| `monitor` | `--bind <BIND>` | one IPv4 or IPv6 address (`127.0.0.1`, `::1`, `::`); no hostname, no CIDR, no IPv6 zone id (`fe80::1%eth0` is rejected; use a global/ULA address or `::`) | `0.0.0.0` | no |
| `monitor` | `--port <PORT>` | integer `1..=65535` | `9090` | no |
| `monitor` | `--scrape-ms <SCRAPE_MS>` | milliseconds between map reads, `100..=60000` | `1000` | no |

`unload` and `list` take no options. Out-of-range or malformed values exit 2, e.g. `error: invalid value '0' for '--port <PORT>': 0 is not in 1..=65535`, `error: invalid value '50' for '--scrape-ms <SCRAPE_MS>': 50 is not in 100..=60000`, `error: invalid value '10.0.0.0/8' for '--bind <BIND>': invalid IP address syntax`.

### 12.3 `load`

```
$ ./target/release/vantage-5G load --help
Load & pin the RX/TX BPF objects (idempotent). Programs remain in the kernel after this command exits; use setup.sh to attach them to an iface.

Without --obj-dir the .o files are searched in: the repository root of the executable (<exe dir>/../..), the executable's directory, the current directory (last).

Usage: vantage-5G load [OPTIONS]

Options:
      --obj-dir <DIR>
          Directory holding vantage_rx_policer.o and vantage_tx_pacer.o (no search)

  -h, --help
          Print help (see a summary with '-h')
```

Opens `vantage_rx_policer.o` and `vantage_tx_pacer.o` from `--obj-dir`, or else from the first directory that holds both of them, searched in this order: `<exe dir>/../..` (the repository root when the binary is `<repo>/target/release/vantage-5G`; the executable path is resolved through symlinks, so `/usr/local/bin/vantage-5G -> <repo>/target/release/vantage-5G` finds `<repo>`), the executable's directory, and last the current directory (listed once if it is one of the first two). The current directory comes last so that running `load` as root from an untrusted directory or an older checkout cannot load other `.o` files than the binary's own; use `--obj-dir .` to load the current directory's objects on purpose. It then loads them and pins programs and maps under `/sys/fs/bpf/vantage/` (`vantage_rx_policer`, `vantage_tx_pacer`, `ue_policy_map`, `ue_stats_map`, `rx_state_map`, `tx_tstamp_map`). Idempotent: an already pinned program is skipped. Before that, every map already pinned is compared with the object's definition; a difference refuses the load (exit 1, nothing changed).

```
$ sudo ./target/release/vantage-5G load
[i] BPF objects from /home/ops/vantage-5g
[+] loaded vantage_rx_policer and pinned to /sys/fs/bpf/vantage/vantage_rx_policer
[+] loaded vantage_tx_pacer and pinned to /sys/fs/bpf/vantage/vantage_tx_pacer
[+] Vantage-5G loaded. Pins under /sys/fs/bpf/vantage
    Attach with: sudo ./setup.sh <iface>

$ sudo ./target/release/vantage-5G load          # second time
[i] BPF objects from /home/ops/vantage-5g
[i] vantage_rx_policer already pinned, skipping load.
[i] vantage_tx_pacer already pinned, skipping load.
[+] Vantage-5G loaded. Pins under /sys/fs/bpf/vantage
    Attach with: sudo ./setup.sh <iface>
```

Objects not found (exit 1, nothing pinned, `/sys/fs/bpf/vantage` not created):

```
$ cd /tmp && sudo /opt/vantage/vantage-5G load    # binary copied without the .o files
[-] vantage_rx_policer.o and vantage_tx_pacer.o not found together in:
      /  (missing: vantage_rx_policer.o, vantage_tx_pacer.o)
      /opt/vantage  (missing: vantage_rx_policer.o, vantage_tx_pacer.o)
      /tmp  (missing: vantage_rx_policer.o, vantage_tx_pacer.o)
    build them with `make build`, or pass --obj-dir <DIR>
Error: BPF object files not found
```

Refused upgrade (pins from an older build, exit 1): `[-] vantage_rx_policer.o: pinned maps under /sys/fs/bpf/vantage do not match the object:`, one line per map such as `rx_state_map (pinned -> .o): max_entries 1024 -> 16384`, and the upgrade procedure (§10).

### 12.4 `unload`

Removes every pin under `/sys/fs/bpf/vantage/` and the directory. Before that it looks for Vantage programs attached in the current network namespace (XDP in any mode, tc egress at pref 1 handle 1 and at the old auto pref 49152 handle 1) and refuses if it finds one.

```
$ sudo ./target/release/vantage-5G unload
[+] Vantage-5G pins removed.

$ sudo ./target/release/vantage-5G unload        # nothing loaded: exit 0
[i] Nothing to remove (/sys/fs/bpf/vantage does not exist)

$ sudo ./target/release/vantage-5G unload        # still attached: exit 1, pins untouched
[-] Vantage programs are still attached:
      vt-n6: xdpgeneric prog id 18 (vantage_rx_poli)
      vt-n6: tc egress pref 1 handle 1 prog id 20 (vantage_tx_pace)
    run: sudo ./detach.sh vt-n6
Error: refusing to unload while attached (pins left untouched)
```

### 12.5 `set`

Writes `{rx_bps, tx_bps}` = Mbps × 1 000 000 for the UE into `ue_policy_map`. If either value differs from the stored policy (or there was none), the UE's RX bucket and TX EDT slot are cleared; if both are equal, the state is kept (§6). At most 1024 UEs can have a policy.

```
$ sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20
[+] policy set: UE 10.45.1.23 rx=10 Mbps tx=20 Mbps
$ sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20
[+] policy set: UE 10.45.1.23 rx=10 Mbps tx=20 Mbps  (unchanged; rx/tx state kept)
$ sudo ./target/release/vantage-5G set --ue-ip 10.45.1.24 --rx-mbps 3 --tx-mbps 0
[+] policy set: UE 10.45.1.24 rx=3 Mbps tx=0 Mbps  (killswitch: DL blocked)
$ sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 400001 --tx-mbps 1
error: invalid value '400001' for '--rx-mbps <RX_MBPS>': 400001 is not in 0..=400000
```

Errors (exit 1): `open pinned ue_policy_map (run `vantage-5G load` first; needs root)`; `update ue_policy_map for <ip>` / `Argument list too long (os error 7)` when 1024 UEs already have a policy.

### 12.6 `reset`

Deletes the UE's policy and its RX/TX state. Counters in `ue_stats_map` are kept (but no longer updated).

```
$ sudo ./target/release/vantage-5G reset --ue-ip 10.45.1.24
[+] policy cleared for UE 10.45.1.24
$ sudo ./target/release/vantage-5G reset --ue-ip 10.45.1.24     # exit 0
[i] no policy for UE 10.45.1.24 (nothing to clear)
```

### 12.7 `list` and `stats`

`list` prints the policy map (rates in whole Mbps); `stats` prints the cumulative counters of `ue_stats_map` (since `load`; L2 bytes, see §7 for what each column counts). Row order is the map's iteration order, not sorted.

```
$ sudo ./target/release/vantage-5G list
UE_IP                  RX_Mbps       TX_Mbps
10.45.1.23                  10            20
10.45.1.24                   3             0  (killswitch)

$ sudo ./target/release/vantage-5G stats
UE_IP                   RX_BYTES     RX_PKTS    RX_DROPS        TX_BYTES     TX_PKTS    TX_DROPS
10.45.1.23                   294           3           0             294           3           0
```

Empty maps print `(no policies configured)` and `(no stats yet — is traffic flowing and the interface attached?)` after the header (exit 0). `stats --ue-ip X` prints the header and only X's row (or the "no stats" line).

### 12.8 `monitor`

```
$ ./target/release/vantage-5G monitor --help
Run the Prometheus exporter (foreground). Scrapes pinned stats maps

Usage: vantage-5G monitor [OPTIONS]

Options:
      --bind <BIND>            Address to listen on (IPv4 or IPv6, e.g. 127.0.0.1, ::1, ::) [default: 0.0.0.0]
      --port <PORT>            [default: 9090]
      --scrape-ms <SCRAPE_MS>  Milliseconds between BPF map reads [default: 1000]
  -h, --help                   Print help
```

Foreground Prometheus exporter on `<bind>:<port>/metrics` (default `0.0.0.0:9090`; metrics: §7). The banner prints the address actually bound (an IPv6 address in brackets, e.g. `http://[::1]:9090/metrics`). It never exits on scrape errors (e.g. started before `load`); it logs each distinct error once and retries every `--scrape-ms`.

```
$ sudo ./target/release/vantage-5G monitor
[+] Prometheus exporter listening on http://0.0.0.0:9090/metrics
    scraping BPF maps every 1000 ms (pins re-opened each scrape).  Ctrl-C to stop.
[!] scrape failed (will retry every 1000 ms): open pinned ue_policy_map (run `vantage-5G load` first; needs root): No such file or directory (os error 2)
[+] scraping recovered
```

The last two lines appear only when `monitor` was started before `load` (or across an `unload`/`load`).

It exits (code 1) only when the HTTP server cannot start: `Error: start Prometheus exporter on <bind>:<port>` / `can not start http server: Address already in use (os error 98)` (port taken) or `… Cannot assign requested address (os error 99)` (`--bind` address not configured on this host). Stop it with Ctrl-C.

### 12.9 `setup.sh` and `detach.sh`

`sudo ./setup.sh <iface> [--xdp-mode generic|native]` / `sudo ./detach.sh <iface>` (or without `sudo` as a user with sudo rights; they call `sudo` for each command when not root).

`setup.sh`:

| Exit | Meaning | Message (start) | State changed? |
|---|---|---|---|
| `0` | Attached and verified | `[+] Vantage-5G attached to <iface>.` | yes |
| `1` | No interface, more than one interface, unknown option, `--xdp-mode` without a value or with a value other than `generic`/`native`, or interface not found. The interface is checked **after** the pins, so with nothing loaded a wrong name gives exit 2 first | `usage: sudo ./setup.sh <iface> [--xdp-mode generic\|native] …` (after `[-] unknown option: …` / `[-] --xdp-mode must be 'generic' or 'native' (got '…')` / …) / `[-] interface <iface> not found` | no |
| `2` | Programs not pinned (run `load`), or `bpftool` not usable | `[-] pinned programs not found under /sys/fs/bpf/vantage` / `[-] bpftool is not usable: …` | no |
| `3` | Refused: someone else's XDP program (generic or native), XDP in offload/multi mode, a non-Vantage egress filter at pref 1, an `ingress` qdisc, a qdisc using handle `1:` when root `mq 1:` must be created (multi-queue NIC), a missing kernel module (`sch_fq`, `cls_bpf`, `sch_ingress`), or the driver rejected the XDP attach (e.g. no native XDP). Exception: when moving a Vantage program to the other XDP mode fails, the previous mode is restored with the **pinned** program (its prog id may differ from the one attached before; RX policing was off for a moment; some physical NICs reset the link) | `[-] <iface> already has an XDP program in '…' mode (id …) that is not Vantage's.` / `[-] <iface> has XDP attached in '…' mode …` / `… egress pref 1 holds a non-Vantage filter` / `… has an 'ingress' qdisc` / `[-] <iface> has a qdisc using handle 1: (…); setup.sh needs that handle` / `[-] kernel module(s) not available: …` / `[-] XDP attach in <mode> mode failed: …` | no (see exception) |
| `4` | Post-attach verification failed, or a failed mode switch could not restore the previous attach | `[-] verify: …` lines, then `[-] Vantage-5G attach on <iface> is NOT in the expected state` and the current `ip`/`tc` state / `[-] restore failed: <iface> has NO XDP RX policer now.` | partly |
| `5` | A change step (1–4) failed after something was already changed. Run `sudo ./detach.sh <iface>`, fix the cause, re-run | `[-] step failed (status N, setup.sh line L) after <iface> was already changed.` … `may be partially attached` | partly |

`detach.sh` (every removal step tolerates "already gone"):

| Exit | Meaning | Message (start) |
|---|---|---|
| `0` | No XDP program (either slot), egress filter, `clsact` or root `mq 1:` left on the interface | `[+] <iface> detached. Pinned programs and maps are still in /sys/fs/bpf/vantage.` |
| `1` | No argument, or interface not found | `usage: sudo ./detach.sh <iface>` / `[-] interface <iface> not found` |
| `4` | Something is still attached (listed, including `setup.sh's root qdisc (mq 1:, per-queue fq) still present`) — typically run without root/sudo | `[-] <iface> is NOT fully detached (see above). …` |

`detach.sh` removes **all** egress filters and the root qdisc on the interface, not only Vantage's; the kernel then re-creates its default root qdisc (§9).

## 13. Local development & testing

The repository carries a local test harness so that changes can be checked before they reach a physical server. Details, every environment variable, the emulated topology and how to read results: [`testbed/README.md`](testbed/README.md).

| Level | Where | Command | What it covers |
|---|---|---|---|
| L0 | any host with Python 3 | `python3 .claude/skills/vantage-boundary-check/scripts/contract_check.py .` | Static consistency: BPF C structs ↔ Rust, map/program names, pin paths, metrics ↔ this README |
| L1 | Docker (privileged Ubuntu 24.04 container) | `./testbed/l1-docker.sh` | Build, verifier, `load`/`unload`, attach, uplink policing, killswitch, `reset`, upgrade paths. No `sch_fq` in Docker Desktop: `setup.sh` and downlink pacing are skipped |
| L2 | VirtualBox Ubuntu VM (24.04 or 22.04) | `./testbed/l2-vbox.sh`, `VT_RELEASE=jammy ./testbed/l2-vbox.sh` | Everything in L1 plus `setup.sh` (also `--xdp-mode native` and a multi-queue N6 with `VT_N6_TXQ`) and §8's four concurrent sessions on an emulated N6 |
| L3 | Open5GS + UERANSIM VMs | not built yet | Real UE addresses through a 5G core |
| L4 | physical server | [`docs/install-runbook.md`](docs/install-runbook.md) | Real NIC, driver and core |

One-off commands in the dev container: `./testbed/dev.sh 'make build'`.

## 14. Roadmap

- Phase 2: replace `ue_policy_map` with an `LPM_TRIE` keyed on `(ue_ip, svc_ip, port, proto)` for micro-segmentation, longest-match semantics.
- Grafana dashboard JSON under `dashboards/`.
- Optional systemd unit for `load` at boot.
