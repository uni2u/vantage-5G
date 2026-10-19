#!/usr/bin/env bash
# netns-topo.sh up|down
#
# Emulated N6 topology for local tests (L1 Docker, L2 VM). The current netns
# plays the service node; Vantage attaches to its N6 interface.
#
#   [vt-ue-a 10.45.1.23]──┐
#                         ├─[vt-core: UPF-like router]──vt-n6c ═══ vt-n6 [service node 10.99.0.1]
#   [vt-ue-b 10.45.1.24]──┘                                         ▲ Vantage XDP/tc here
#
# Env:
#   VT_NAT=1           MASQUERADE UE traffic on the core's N6 side, as the
#                      Open5GS quickstart does for UE internet access. With it
#                      the service node only sees 10.99.0.2 and per-UE policy
#                      cannot match — use it to demonstrate that failure mode.
#   VT_NETEM="..."     netem args applied on the core's UE-facing links to mimic
#                      the radio leg (e.g. "delay 10ms rate 200mbit").

set -eu

N6_IF=vt-n6
SVC_IP=10.99.0.1
CORE_IP=10.99.0.2
UES="a:10.45.1.23 b:10.45.1.24"

down() {
    ip link del "${N6_IF}" 2>/dev/null || true
    for ns in vt-core vt-ue-a vt-ue-b; do ip netns del "${ns}" 2>/dev/null || true; done
    ip route del 10.45.0.0/16 2>/dev/null || true
}

up() {
    down
    ip netns add vt-core
    ip netns exec vt-core sysctl -qw net.ipv4.ip_forward=1
    ip -n vt-core link set lo up

    # N6 link: service node <-> core
    ip link add "${N6_IF}" type veth peer name vt-n6c
    ip link set vt-n6c netns vt-core
    ip addr add "${SVC_IP}/24" dev "${N6_IF}"
    ip link set "${N6_IF}" up
    ip -n vt-core addr add "${CORE_IP}/24" dev vt-n6c
    ip -n vt-core link set vt-n6c up
    ip route replace 10.45.0.0/16 via "${CORE_IP}" dev "${N6_IF}"

    for ue in ${UES}; do
        name=${ue%%:*}; ip=${ue#*:}
        ns=vt-ue-${name}
        ip netns add "${ns}"
        ip -n "${ns}" link set lo up
        ip link add "vt-u${name}" type veth peer name "vt-c${name}"
        ip link set "vt-u${name}" netns "${ns}"
        ip link set "vt-c${name}" netns vt-core
        ip -n "${ns}" addr add "${ip}/32" dev "vt-u${name}"
        ip -n "${ns}" link set "vt-u${name}" up
        ip -n "${ns}" route add default dev "vt-u${name}"
        ip -n vt-core link set "vt-c${name}" up
        ip netns exec vt-core sysctl -qw "net.ipv4.conf.vt-c${name}.proxy_arp=1"
        ip -n vt-core route add "${ip}/32" dev "vt-c${name}"
        if [[ -n "${VT_NETEM:-}" ]]; then
            # shellcheck disable=SC2086
            ip netns exec vt-core tc qdisc replace dev "vt-c${name}" root netem ${VT_NETEM}
        fi
    done
    ip -n vt-core route add default via "${SVC_IP}" dev vt-n6c

    if [[ "${VT_NAT:-0}" == 1 ]]; then
        ip netns exec vt-core iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o vt-n6c -j MASQUERADE
        echo "[i] NAT enabled: service node will see ${CORE_IP} instead of UE IPs"
    fi

    for ue in ${UES}; do
        name=${ue%%:*}
        ip netns exec "vt-ue-${name}" ping -c1 -W2 "${SVC_IP}" >/dev/null \
            || { echo "[-] UE-${name} cannot reach ${SVC_IP}"; exit 1; }
    done
    echo "[+] topology up: N6 iface=${N6_IF} svc=${SVC_IP} UEs: ${UES}"
}

case "${1:-}" in
    up)   up ;;
    down) down; echo "[+] topology down" ;;
    *)    echo "usage: $0 up|down"; exit 1 ;;
esac
