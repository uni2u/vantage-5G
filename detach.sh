#!/usr/bin/env bash
# detach.sh <iface>
# Undo everything setup.sh did on <iface>.
# Safe to re-run; every step tolerates "already gone".

set -u

IFACE="${1:-}"
if [[ -z "${IFACE}" ]]; then
    echo "usage: sudo $0 <iface>"
    exit 1
fi

echo "=== 1. remove tc egress filter ==="
# Removes every egress filter, including setup.sh's Vantage pacer (pref 1 handle 1).
sudo tc filter del dev "${IFACE}" egress 2>/dev/null || true

echo "=== 2. detach XDP ==="
# setup.sh attaches in generic (SKB) mode. XDP modes have separate slots and a
# mode-less "xdp off" targets the native/driver slot on NICs with ndo_bpf
# (veth, virtio_net, ixgbe, mlx5, ...), leaving the xdpgeneric program behind.
# Detach the generic slot explicitly, then clear any native-mode leftover.
sudo ip link set dev "${IFACE}" xdpgeneric off 2>/dev/null || true
sudo ip link set dev "${IFACE}" xdp off 2>/dev/null || true

echo "=== 3. remove clsact qdisc ==="
sudo tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true

echo "=== 4. remove root fq qdisc (kernel re-creates its default root qdisc; a previous custom qdisc is NOT restored) ==="
sudo tc qdisc del dev "${IFACE}" root 2>/dev/null || true

echo "[+] ${IFACE} detached. Pinned programs and maps are still in ${PIN_DIR:-/sys/fs/bpf/vantage}."
echo "    Run 'sudo ./target/release/vantage-5G unload' to fully remove them."
