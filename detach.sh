#!/usr/bin/env bash
# detach.sh <iface>
# Undo everything setup.sh did on <iface>.
# Safe to re-run; every step tolerates "already gone" and the script keeps
# going when a step fails. At the end it checks what is left on <iface>:
#   exit 0  nothing left (XDP in any mode, egress filters, clsact)
#   exit 1  usage / no such interface
#   exit 4  something is still attached (listed; e.g. not run as root)

set -u

IFACE="${1:-}"
if [[ -z "${IFACE}" ]]; then
    echo "usage: sudo $0 <iface>"
    exit 1
fi

# Commands go through sudo unless already root.
SUDO=""
[[ "$(id -u)" -eq 0 ]] || SUDO="sudo"

PIN_DIR="/sys/fs/bpf/vantage"

# Reads below need no privilege (and must not depend on sudo working).
if ! ip link show dev "${IFACE}" >/dev/null 2>&1; then
    echo "[-] interface ${IFACE} not found"
    exit 1
fi

echo "=== 1. remove tc egress filter ==="
# Removes every egress filter, including setup.sh's Vantage pacer (pref 1 handle 1).
${SUDO} tc filter del dev "${IFACE}" egress 2>/dev/null || true

echo "=== 2. detach XDP ==="
# setup.sh attaches in generic (SKB) mode. XDP modes have separate slots and a
# mode-less "xdp off" targets the native/driver slot on NICs with ndo_bpf
# (veth, virtio_net, ixgbe, mlx5, ...), leaving the xdpgeneric program behind.
# Detach the generic slot explicitly, then clear any native-mode leftover.
${SUDO} ip link set dev "${IFACE}" xdpgeneric off 2>/dev/null || true
${SUDO} ip link set dev "${IFACE}" xdp off 2>/dev/null || true

echo "=== 3. remove clsact qdisc ==="
${SUDO} tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true

echo "=== 4. remove root fq qdisc (kernel re-creates its default root qdisc; a previous custom qdisc is NOT restored) ==="
${SUDO} tc qdisc del dev "${IFACE}" root 2>/dev/null || true

echo "=== 5. check what is left ==="
# Root qdisc is not checked: the kernel default may itself be fq
# (net.core.default_qdisc=fq), and it carries no Vantage program.
LEFT=0
XDP_LINE="$(ip -d link show dev "${IFACE}" 2>/dev/null | grep -E 'prog/xdp' || true)"
if [[ -n "${XDP_LINE}" ]]; then
    echo "[-] XDP program still attached:"; echo "${XDP_LINE}" | sed 's/^ */      /'; LEFT=1
fi
EG="$(tc filter show dev "${IFACE}" egress 2>/dev/null || true)"
if [[ -n "${EG}" ]]; then
    echo "[-] egress filters still present:"; echo "${EG}" | sed 's/^/      /'; LEFT=1
fi
if tc qdisc show dev "${IFACE}" 2>/dev/null | grep -q '^qdisc clsact '; then
    echo "[-] clsact qdisc still present"; LEFT=1
fi
if [[ "${LEFT}" -ne 0 ]]; then
    echo
    echo "[-] ${IFACE} is NOT fully detached (see above). Run as root / with sudo and re-run;"
    echo "    do not 'unload' while a Vantage program is still attached."
    exit 4
fi

echo "[+] ${IFACE} detached. Pinned programs and maps are still in ${PIN_DIR}."
echo "    Run 'sudo ./target/release/vantage-5G unload' to fully remove them."
