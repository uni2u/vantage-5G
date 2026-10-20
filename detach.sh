#!/usr/bin/env bash
# detach.sh <iface>
# Undo everything setup.sh did on <iface>.
# Safe to re-run; every step tolerates "already gone" and the script keeps
# going when a step fails. At the end it checks what is left on <iface>:
#   exit 0  nothing left (XDP in any mode, egress filters, clsact, setup.sh's
#           root mq 1:)
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

# Paths for operator hints: where this script and the CLI actually are
# (repository checkout, or /usr/local/lib/vantage-5g when installed).
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [[ -x "${SELF_DIR}/vantage-5G" ]]; then CLI="${SELF_DIR}/vantage-5G"
elif [[ -x "${SELF_DIR}/target/release/vantage-5G" ]]; then CLI="${SELF_DIR}/target/release/vantage-5G"
else CLI="vantage-5G"; fi

# Reads below need no privilege (and must not depend on sudo working).
if ! ip link show dev "${IFACE}" >/dev/null 2>&1; then
    echo "[-] interface ${IFACE} not found"
    exit 1
fi

echo "=== 1. remove tc egress filter ==="
# Removes every egress filter, including setup.sh's Vantage pacer (pref 1 handle 1).
${SUDO} tc filter del dev "${IFACE}" egress 2>/dev/null || true

echo "=== 2. detach XDP (generic and native) ==="
# setup.sh attaches in generic (SKB) or native (driver) mode (--xdp-mode).
# XDP modes have separate slots; clear both explicitly. (A mode-less "xdp off"
# targets only the native slot on NICs with ndo_bpf and would leave an
# xdpgeneric program behind.) Clearing an empty slot succeeds.
${SUDO} ip link set dev "${IFACE}" xdpgeneric off 2>/dev/null || true
${SUDO} ip link set dev "${IFACE}" xdpdrv off 2>/dev/null || true

echo "=== 3. remove clsact qdisc ==="
${SUDO} tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true

echo "=== 4. remove root qdisc (fq, or mq 1: with its per-queue fq children) ==="
# The kernel then re-creates its default root: mq with one
# net.core.default_qdisc child per TX queue on a multi-queue NIC, that
# default qdisc on a single-queue NIC, noqueue on veth and other no-queue
# devices. A custom root qdisc that existed before setup.sh is NOT restored.
${SUDO} tc qdisc del dev "${IFACE}" root 2>/dev/null || true

echo "=== 5. check what is left ==="
# A root fq is not reported: the kernel default may itself be fq
# (net.core.default_qdisc=fq, also as mq children), and it carries no Vantage
# program. setup.sh's root mq has the fixed handle 1: (the kernel's default mq
# is 0:), so a root "mq 1:" means step 4 did not take effect.
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
ROOTQ="$(tc qdisc show dev "${IFACE}" 2>/dev/null | awk '$4 == "root" { print $2 " " $3; exit }')"
if [[ "${ROOTQ}" == "mq 1:" ]]; then
    echo "[-] setup.sh's root qdisc (mq 1:, per-queue fq) still present"; LEFT=1
fi
if [[ "${LEFT}" -ne 0 ]]; then
    echo
    echo "[-] ${IFACE} is NOT fully detached (see above). Run as root / with sudo and re-run;"
    echo "    do not 'unload' while a Vantage program is still attached."
    exit 4
fi

echo "[+] ${IFACE} detached. Pinned programs and maps are still in ${PIN_DIR}."
echo "    Run 'sudo ${CLI} unload' to fully remove them."
