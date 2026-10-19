#!/usr/bin/env bash
# core-ran.sh — runtime side of the L3 core VM (run as root on vantage-core).
#
#   core-ran.sh up              RAN netns + gNB + 2 UEs, restart AMF/UPF on the RAN link
#   core-ran.sh down            stop UEs/gNB, remove the netns
#   core-ran.sh ues             print "<uesimtunN> <UE IP>" per PDU session (netns ran)
#   core-ran.sh nat-reference   Open5GS quickstart NAT state: ip_forward=1 (sysctl -w),
#                               exactly one "-s 10.45.0.0/16 ! -o ogstun -j MASQUERADE",
#                               and none of the README §3.2 changes (exception rules,
#                               /etc/sysctl.d/90-ue-forward.conf, FORWARD accepts)
#   core-ran.sh status
#
# Topology inside the VM (the RAN plays a separate UE host, as in the user's setup):
#
#   netns ran: nr-ue x2 (uesimtun0/1, 10.45.0.x) -- nr-gnb 10.100.0.2/24 [ran1]
#        |  veth (N2 SCTP + N3 GTP-U)
#   root ns:  [ran0] 10.100.0.1/24, AMF NGAP 10.100.0.5, UPF GTP-U 10.100.0.7
#             UPF -> ogstun 10.45.0.1/16 -> kernel routing -> N6 NIC 10.200.0.1/24
#
# UE addresses stay non-local to the UPF host, so downlink to 10.45.0.x really
# goes ogstun -> UPF -> GTP-U -> gNB -> UE (it would be delivered locally if the
# UEs lived in the root namespace).

set -u
UER=/opt/UERANSIM/build
QS_RULE=(-s 10.45.0.0/16 '!' -o ogstun -j MASQUERADE)

ues() {
    ip netns exec ran ip -br -4 addr show 2>/dev/null | awk '$1 ~ /^uesimtun/ {sub("/.*","",$3); print $1, $3}'
}

up() {
    if ! ip netns list | grep -qw ran; then
        ip netns add ran
        ip link add ran0 type veth peer name ran1
        ip link set ran1 netns ran
        ip addr add 10.100.0.1/24 dev ran0
        ip addr add 10.100.0.5/24 dev ran0
        ip addr add 10.100.0.7/24 dev ran0
        ip link set ran0 up
        ip -n ran addr add 10.100.0.2/24 dev ran1
        ip -n ran link set ran1 up
        ip -n ran link set lo up
    fi
    # AMF NGAP / UPF GTP-U bind to addresses that exist only once ran0 is up.
    systemctl restart open5gs-amfd open5gs-upfd
    systemctl restart open5gs-smfd
    sleep 3
    systemctl stop vt-ue vt-gnb 2>/dev/null; systemctl reset-failed vt-ue vt-gnb 2>/dev/null
    systemd-run --unit vt-gnb --collect ip netns exec ran "${UER}/nr-gnb" -c /etc/ueransim/gnb.yaml >/dev/null
    sleep 3
    systemd-run --unit vt-ue --collect ip netns exec ran "${UER}/nr-ue" -c /etc/ueransim/ue.yaml -n 2 >/dev/null
    for _ in $(seq 1 30); do [[ $(ues | wc -l) -ge 2 ]] && break; sleep 2; done
    ues
    [[ $(ues | wc -l) -ge 2 ]] || { echo "[-] UEs did not get 2 PDU sessions"; journalctl -u vt-gnb -u vt-ue --no-pager | tail -40; return 1; }
}

down() {
    systemctl stop vt-ue vt-gnb 2>/dev/null
    systemctl reset-failed vt-ue vt-gnb 2>/dev/null
    ip link del ran0 2>/dev/null
    ip netns del ran 2>/dev/null
    return 0
}

nat_reference() {
    # Undo README §3.2 (1)/(2) changes made by l3-vbox.sh scenario (b).
    while iptables -t nat -C POSTROUTING -s 10.45.0.0/16 -d 10.200.0.0/24 -j ACCEPT 2>/dev/null; do
        iptables -t nat -D POSTROUTING -s 10.45.0.0/16 -d 10.200.0.0/24 -j ACCEPT; done
    while iptables -t nat -C POSTROUTING -s 10.45.0.0/16 '!' -d 10.200.0.0/24 '!' -o ogstun -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -s 10.45.0.0/16 '!' -d 10.200.0.0/24 '!' -o ogstun -j MASQUERADE; done
    while iptables -C FORWARD -s 10.45.0.0/16 -d 10.200.0.0/24 -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -s 10.45.0.0/16 -d 10.200.0.0/24 -j ACCEPT; done
    while iptables -C FORWARD -s 10.200.0.0/24 -d 10.45.0.0/16 -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -s 10.200.0.0/24 -d 10.45.0.0/16 -j ACCEPT; done
    rm -f /etc/sysctl.d/90-ue-forward.conf
    # Quickstart "Adding a route for the UE to have WAN connectivity", verbatim (IPv4/IPv6 forwarding + NAT).
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    iptables -t nat -C POSTROUTING "${QS_RULE[@]}" 2>/dev/null || iptables -t nat -A POSTROUTING "${QS_RULE[@]}"
    ip6tables -t nat -C POSTROUTING -s 2001:db8:cafe::/48 '!' -o ogstun -j MASQUERADE 2>/dev/null \
        || ip6tables -t nat -A POSTROUTING -s 2001:db8:cafe::/48 '!' -o ogstun -j MASQUERADE
    command -v conntrack >/dev/null && conntrack -D -s 10.45.0.0/16 >/dev/null 2>&1
    iptables -t nat -S POSTROUTING
}

status() {
    echo "--- open5gs"; systemctl is-active open5gs-amfd open5gs-smfd open5gs-upfd mongod | paste -sd' '
    echo "--- ran";     systemctl is-active vt-gnb vt-ue 2>/dev/null | paste -sd' '; ues
    echo "--- nat";     iptables -t nat -S POSTROUTING; sysctl net.ipv4.ip_forward
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    ues) ues ;;
    nat-reference) nat_reference ;;
    status) status ;;
    *) echo "usage: $0 up|down|ues|nat-reference|status"; exit 1 ;;
esac
