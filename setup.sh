#!/usr/bin/env bash
# setup.sh <iface>
#
# Attach Vantage-5G RX policer (XDP) and TX pacer (tc-bpf + EDT) to the
# given N6-facing interface on the service node.
#
# Prerequisites (in this order):
#   1. `make build`                         # produces the .o objects
#   2. `sudo ./target/release/vantage-5G load`  # loads & pins the programs
#   3. `sudo ./setup.sh <iface>`            # this script

set -eu

IFACE="${1:-}"
if [[ -z "${IFACE}" ]]; then
    echo "usage: sudo $0 <iface>   (e.g. eth0, ens3f0, enp0s3)"
    exit 1
fi

PIN_DIR="/sys/fs/bpf/vantage"
PROG_XDP="${PIN_DIR}/vantage_rx_policer"
PROG_TC="${PIN_DIR}/vantage_tx_pacer"

if [[ ! -e "${PROG_XDP}" || ! -e "${PROG_TC}" ]]; then
    echo "[-] pinned programs not found under ${PIN_DIR}"
    echo "    run 'sudo ./target/release/vantage-5G load' first."
    exit 2
fi

echo "=== 1. root qdisc -> fq  (required for EDT / skb->tstamp pacing) ==="
sudo tc qdisc replace dev "${IFACE}" root fq

echo "=== 2. clsact qdisc for tc-bpf hook (idempotent) ==="
sudo tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true
sudo tc qdisc add dev "${IFACE}" clsact

echo "=== 3. attach XDP RX policer (generic mode: broadest compatibility) ==="
sudo ip link set dev "${IFACE}" xdpgeneric pinned "${PROG_XDP}"

echo "=== 4. attach tc-bpf TX pacer on egress ==="
sudo tc filter add dev "${IFACE}" egress bpf da pinned "${PROG_TC}"

echo
echo "[+] Vantage-5G attached to ${IFACE}."
echo "    - RX policer (XDP): ${PROG_XDP}"
echo "    - TX pacer  (tc):   ${PROG_TC}"
echo
echo "Next:"
echo "    ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20"
echo "    sudo ./target/release/vantage-5G monitor"
echo
echo "To detach:  sudo ./detach.sh ${IFACE}"
