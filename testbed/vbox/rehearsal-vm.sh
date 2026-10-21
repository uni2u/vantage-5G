#!/usr/bin/env bash
# rehearsal-vm.sh -- VM side of testbed/runbook-rehearsal.sh (run as root in a testbed VM).
#
# (a) LAN topology (VT_REH=lan, on the L2 service VM) -- docs/install-runbook.md case (가):
#
#   netns nb-a  eth0 192.168.77.21/24 ──┐                       (client A, user lapa, sshd)
#               wlan0 172.31.1.2 -> NAT │  bridge vtbr0
#   netns nb-b  eth0 192.168.77.22/24 ──┤  (L2 switch, no IP)
#               wlan0 172.31.2.2 -> NAT │
#   root ns     vtlan0 192.168.77.10/24 ┘ = the service node's IF (Vantage attaches here)
#
#   vtlan0 <-> vtlan0p (bridge port) and vtbr0 are systemd-networkd devices, so they exist at
#   every boot like a real NIC (the runbook's reboot step needs that). The clients are netns
#   with a wired eth0 on the bridge and a "Wi-Fi" wlan0 that carries the default route to the
#   internet (MASQUERADE through the VM's NAT NIC). Each runs its own sshd (password login).
#   Netns do not survive a reboot; `lan-up` re-creates them.
#
# (b) L3 client side (VT_REH=l3, on vantage-core) -- case (나): the UERANSIM UEs live in netns
#   "ran" (testbed/vbox/core-ran.sh). `l3-client-up` makes that netns the runbook's client
#   host: user ueuser, an sshd on the gNB-side address 10.100.0.2 (the "management address"
#   CLIENT_x_HOST), a default route via 10.100.0.1 + MASQUERADE for apt, DNS. The UE traffic
#   itself keeps using UERANSIM's source routing (uesimtunN). The service VM reaches
#   10.100.0.0/24 via the core's N6 address (`svc-mgmt-up`, a wrapper route).
#
# Commands:
#   lan-up | lan-down        LAN topology (lan-down also removes the runbook artefacts in ~ubuntu)
#   l3-client-up | l3-client-down        on vantage-core
#   ran-check                on vantage-core: both PDU sessions alive (ping the UPF gateway via
#                            each uesimtun); re-establish once (core-ran.sh down/up) + client-up
#   core-reset               on vantage-core: undo appendix A (exception rules, FORWARD accepts,
#                            iptables-persistent + /etc/iptables), back to the quickstart NAT state
#   svc-mgmt-up | svc-mgmt-down          on vantage-svc: route 10.100.0.0/24 via 10.200.0.1
#   pre-clean <iface>        leftover Vantage state of an aborted run (uninstall, detach, unload)
#   home-reset               the runbook's artefacts in ~ubuntu (clone, ~/vt-l4*, vt_l4 key,
#                            ~/.cargo, ~/.rustup) and runbook network leftovers (UE route drop-in)
#   run <netns> <user>       run stdin as that user: `bash -i` inside the netns
#   fill <file> KEY=VAL...   the runbook's only manual edit (0.2 / A.0-2), done with sed
#   residue <iface>          RESIDUE-OK / RESIDUE-FAIL lines (Vantage + rehearsal state)
set -u
NET=192.168.77
SVC_IP=${NET}.10; A_IP=${NET}.21; B_IP=${NET}.22
PW=vt-rehearsal-pw
NETD=/etc/systemd/network
STATE=/var/lib/vt-lan-rehearsal
RUN=/run/vt-lan
U=/home/ubuntu

ip_of() { case "$1" in a) echo "${A_IP}" ;; b) echo "${B_IP}" ;; esac; }
n_of()  { case "$1" in a) echo 1 ;; b) echo 2 ;; esac; }
wan_if() { ip -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }
upstream_dns() { awk '/^nameserver/ {print $2; exit}' /run/systemd/resolve/resolv.conf 2>/dev/null; }
del_nat() {   # del_nat <src cidr>: delete every nat POSTROUTING rule for that source (whatever -o)
    local r
    iptables -t nat -S POSTROUTING | grep -F -- "-s $1 " | sed 's/^-A /-D /' | while read -r r; do
        # shellcheck disable=SC2086
        iptables -t nat ${r}
    done
}
askpass() {   # askpass for ssh-copy-id (runbook 2.3). Not under /run: it is mounted noexec.
    mkdir -p "${STATE}"; printf '#!/bin/sh\necho %s\n' "${PW}" > ${STATE}/askpass; chmod 755 ${STATE} ${STATE}/askpass
}
mkuser() {    # mkuser <name>: password login, NOPASSWD sudo (a real client prompts; see runbook rules)
    id "$1" >/dev/null 2>&1 || useradd -m -s /bin/bash "$1"
    echo "$1:${PW}" | chpasswd
    echo "$1 ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-vt-rehearsal-"$1"; chmod 440 /etc/sudoers.d/90-vt-rehearsal-"$1"
}
nssshd() {    # nssshd <netns> <listen ip> <tag>
    local pid=${RUN}/sshd-$3.pid
    mkdir -p "${RUN}"
    if ! { [[ -f ${pid} ]] && kill -0 "$(cat ${pid})" 2>/dev/null; }; then
        ip netns exec "$1" /usr/sbin/sshd -o ListenAddress="$2" -o PidFile="${pid}" \
            -o PasswordAuthentication=yes -o KbdInteractiveAuthentication=no
    fi
}

lan_up() {
    mkdir -p "${STATE}" "${RUN}"
    if [[ ! -f ${NETD}/60-vtlan.netdev ]]; then
        printf '[NetDev]\nName=vtbr0\nKind=bridge\n' > ${NETD}/60-vtbr.netdev
        printf '[Match]\nName=vtbr0\n[Link]\nRequiredForOnline=no\n[Network]\nLinkLocalAddressing=no\nIPv6AcceptRA=no\nConfigureWithoutCarrier=yes\n' > ${NETD}/60-vtbr.network
        printf '[NetDev]\nName=vtlan0\nKind=veth\n[Peer]\nName=vtlan0p\n' > ${NETD}/60-vtlan.netdev
        printf '[Match]\nName=vtlan0\n[Link]\nRequiredForOnline=no\n[Network]\nAddress=%s/24\nLinkLocalAddressing=no\nIPv6AcceptRA=no\n' "${SVC_IP}" > ${NETD}/60-vtlan.network
        printf '[Match]\nName=vtlan0p\n[Link]\nRequiredForOnline=no\n[Network]\nBridge=vtbr0\nLinkLocalAddressing=no\nIPv6AcceptRA=no\n' > ${NETD}/60-vtlanp.network
        networkctl reload
    fi
    for _ in $(seq 1 30); do ip -4 -o addr show dev vtlan0 2>/dev/null | grep -q " ${SVC_IP}/" && break; sleep 1; done
    ip -4 -o addr show dev vtlan0 | grep -q " ${SVC_IP}/" || { echo "[-] vtlan0 has no ${SVC_IP}"; return 1; }
    [[ -f ${STATE}/ip_forward.orig ]] || sysctl -n net.ipv4.ip_forward > ${STATE}/ip_forward.orig
    sysctl -qw net.ipv4.ip_forward=1
    local wan; wan=$(wan_if)
    iptables -t nat -C POSTROUTING -s 172.31.0.0/16 -o "${wan}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 172.31.0.0/16 -o "${wan}" -j MASQUERADE
    askpass
    local r ns ip n dns; dns=$(upstream_dns)
    for r in a b; do
        ns=nb-${r}; ip=$(ip_of ${r}); n=$(n_of ${r})
        mkuser lap${r}
        ip netns list | grep -qw "${ns}" || ip netns add ${ns}
        mkdir -p /etc/netns/${ns}; echo "nameserver ${dns:-10.0.2.3}" > /etc/netns/${ns}/resolv.conf
        ip -n ${ns} link set lo up
        if ! ip -n ${ns} link show eth0 >/dev/null 2>&1; then
            ip link add vtnb-${r} type veth peer name vtnb-${r}-in
            ip link set vtnb-${r}-in netns ${ns}; ip -n ${ns} link set vtnb-${r}-in name eth0
            ip link set vtnb-${r} master vtbr0 up
            ip -n ${ns} addr add ${ip}/24 dev eth0; ip -n ${ns} link set eth0 up
        fi
        if ! ip -n ${ns} link show wlan0 >/dev/null 2>&1; then
            ip link add vtwl-${r} type veth peer name vtwl-${r}-in
            ip link set vtwl-${r}-in netns ${ns}; ip -n ${ns} link set vtwl-${r}-in name wlan0
            ip addr add 172.31.${n}.1/24 dev vtwl-${r}; ip link set vtwl-${r} up
            ip -n ${ns} addr add 172.31.${n}.2/24 dev wlan0; ip -n ${ns} link set wlan0 up
            ip -n ${ns} route add default via 172.31.${n}.1 dev wlan0
        fi
        nssshd ${ns} ${ip} ${r}
    done
    sleep 1
    for r in a b; do
        ip netns exec nb-${r} ping -c1 -W2 ${SVC_IP} >/dev/null && echo "[+] nb-${r} -> ${SVC_IP} ok" || echo "[-] nb-${r} cannot reach ${SVC_IP}"
        ip netns exec nb-${r} getent hosts archive.ubuntu.com >/dev/null && echo "[+] nb-${r} DNS/internet ok" || echo "[-] nb-${r} no DNS"
    done
    echo "[+] topology up: svc vtlan0 ${SVC_IP}, client A nb-a/lapa ${A_IP}, client B nb-b/lapb ${B_IP}"
}

lan_down() {
    local r
    for r in a b; do
        [[ -f ${RUN}/sshd-${r}.pid ]] && kill "$(cat ${RUN}/sshd-${r}.pid)" 2>/dev/null
        ip netns del nb-${r} 2>/dev/null
        ip link del vtnb-${r} 2>/dev/null; ip link del vtwl-${r} 2>/dev/null
        pkill -u lap${r} 2>/dev/null; sleep 0.5
        id lap${r} >/dev/null 2>&1 && userdel -r lap${r} 2>/dev/null
        rm -rf /etc/netns/nb-${r}; rm -f /etc/sudoers.d/90-vt-rehearsal-lap${r}
    done
    rm -f ${NETD}/60-vtbr.netdev ${NETD}/60-vtbr.network ${NETD}/60-vtlan.netdev ${NETD}/60-vtlan.network ${NETD}/60-vtlanp.network
    networkctl reload
    ip link del vtlan0 2>/dev/null; ip link del vtbr0 2>/dev/null
    del_nat 172.31.0.0/16
    [[ -f ${STATE}/ip_forward.orig ]] && sysctl -qw net.ipv4.ip_forward="$(cat ${STATE}/ip_forward.orig)"
    rm -rf "${STATE}" "${RUN}"
    home_reset
    echo "[+] LAN topology and runbook artefacts removed"
}

# ---- L3 client side (vantage-core) ----
ran_ues() { bash ${U}/core-ran.sh ues; }
l3_client_up() {
    mkdir -p "${RUN}"
    # After a fresh boot AMF/UPF may have hit systemd's start limit (their addresses on ran0 did
    # not exist yet); clear it so core-ran.sh can restart them.
    if [[ $(ran_ues | wc -l) -lt 2 ]]; then
        systemctl reset-failed open5gs-amfd open5gs-upfd open5gs-smfd 2>/dev/null
        bash ${U}/core-ran.sh down; bash ${U}/core-ran.sh up >/dev/null || { echo "[-] RAN not up"; return 1; }
    fi
    mkuser ueuser
    ip -n ran route show default | grep -q . || ip -n ran route add default via 10.100.0.1 dev ran1
    local wan; wan=$(wan_if)
    iptables -t nat -C POSTROUTING -s 10.100.0.0/24 -o "${wan}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o "${wan}" -j MASQUERADE
    mkdir -p /etc/netns/ran; echo "nameserver $(upstream_dns)" > /etc/netns/ran/resolv.conf
    nssshd ran 10.100.0.2 ran
    sleep 1
    ran_ues
    ip netns exec ran getent hosts archive.ubuntu.com >/dev/null && echo "[+] ran DNS/internet ok" || echo "[-] ran no DNS"
    echo "[+] l3 client host: netns ran, user ueuser, sshd 10.100.0.2"
}
l3_client_down() {
    [[ -f ${RUN}/sshd-ran.pid ]] && kill "$(cat ${RUN}/sshd-ran.pid)" 2>/dev/null
    pkill -u ueuser 2>/dev/null; sleep 0.5
    id ueuser >/dev/null 2>&1 && userdel -r ueuser 2>/dev/null
    rm -f /etc/sudoers.d/90-vt-rehearsal-ueuser; rm -rf /etc/netns/ran "${RUN}" "${STATE}"
    ip -n ran route del default via 10.100.0.1 2>/dev/null
    del_nat 10.100.0.0/24
    rm -rf ${U}/vt-l4
    echo "[+] l3 client host removed"
}
ran_alive() {
    local t ip
    [[ $(ran_ues | wc -l) -ge 2 ]] || return 1
    while read -r t ip; do ip netns exec ran ping -I "${t}" -c 2 -W 2 10.45.0.1 >/dev/null || return 1; done < <(ran_ues)
}
ran_check() {
    if ran_alive; then echo "[i] RAN alive: $(ran_ues | paste -sd' ')"; return 0; fi
    echo "[!] RAN lost ($(ran_ues | paste -sd' ')); re-establishing (core-ran.sh down/up) -- wrapper intervention"
    systemctl reset-failed open5gs-amfd open5gs-upfd open5gs-smfd 2>/dev/null
    bash ${U}/core-ran.sh down; bash ${U}/core-ran.sh up >/dev/null; l3_client_up >/dev/null
    ran_alive && { echo "[i] RAN re-established: $(ran_ues | paste -sd' ')"; return 0; }
    echo "[-] RAN still not usable"; return 1
}
core_reset() {
    local r
    while iptables -t nat -D POSTROUTING -s 10.45.0.0/16 -d 10.200.0.2/32 -j ACCEPT 2>/dev/null; do :; done
    for r in "-s 10.45.0.0/16 -d 10.200.0.2/32" "-s 10.200.0.2/32 -d 10.45.0.0/16"; do
        # shellcheck disable=SC2086
        while iptables -D FORWARD ${r} -j ACCEPT 2>/dev/null; do :; done
    done
    if dpkg -s iptables-persistent >/dev/null 2>&1 || dpkg -s netfilter-persistent >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -q iptables-persistent netfilter-persistent >/dev/null 2>&1
        echo "[i] purged iptables-persistent netfilter-persistent"
    fi
    rm -rf /etc/iptables
    bash ${U}/core-ran.sh nat-reference >/dev/null      # quickstart MASQUERADE, no sysctl.d file
    rm -rf ${U}/vt-l4
    iptables -t nat -S POSTROUTING
}

svc_mgmt_up()   { ip route replace 10.100.0.0/24 via 10.200.0.1; ip route show 10.100.0.0/24; }
svc_mgmt_down() { ip route del 10.100.0.0/24 2>/dev/null; true; }

pre_clean() {
    local ifn=${1:-}
    if [[ -e /usr/local/lib/vantage-5g || -e /etc/vantage-5g ]]; then
        echo "[i] leftover service install: uninstall --purge"
        if [[ -x ${U}/vantage-5G/install.sh ]]; then ${U}/vantage-5G/install.sh uninstall --purge --force
        else systemctl disable --now vantage-5g vantage-5g-monitor 2>/dev/null
             rm -rf /usr/local/lib/vantage-5g /usr/local/bin/vantage-5G /etc/vantage-5g \
                    /etc/systemd/system/vantage-5g.service /etc/systemd/system/vantage-5g-monitor.service
             systemctl daemon-reload; fi
    fi
    local i
    for i in $(ip -o link | awk -F': ' '{sub("@.*","",$2); print $2}'); do
        if ip -d link show dev "$i" | grep -q prog/xdp || tc qdisc show dev "$i" | grep -q clsact; then
            echo "[i] leftover attach on $i: detach"
            ip link set dev "$i" xdpgeneric off 2>/dev/null; ip link set dev "$i" xdpdrv off 2>/dev/null
            tc qdisc del dev "$i" clsact 2>/dev/null; tc qdisc del dev "$i" root 2>/dev/null
        fi
    done
    [[ -e /sys/fs/bpf/vantage ]] && { echo "[i] leftover pins: removed"; rm -rf /sys/fs/bpf/vantage; }
    pkill -x iperf3 2>/dev/null
    [[ -n "${ifn}" ]] && ip route del 10.45.0.0/16 2>/dev/null && echo "[i] leftover UE route removed"
    true
}

home_reset() {
    rm -rf ${U}/vantage-5G ${U}/vt-l4 ${U}/vt-l4-*.tgz ${U}/.ssh/vt_l4 ${U}/.ssh/vt_l4.pub ${U}/.cargo ${U}/.rustup
    [[ -f ${U}/.ssh/known_hosts ]] && sed -i -E '/^(192\.168\.77|10\.100\.0)\./d' ${U}/.ssh/known_hosts
    local f; for f in ${U}/.profile ${U}/.bashrc; do [[ -f $f ]] && sed -i '/\.cargo\/env/d' "$f"; done
    if [[ -e /etc/netplan/90-vantage-ue-route.yaml ]]; then rm -f /etc/netplan/90-vantage-ue-route.yaml; netplan generate; echo "[i] leftover netplan UE route drop-in removed"; fi
    true
}

residue() {
    local ifn=${1:-} bad=0
    chk() { if eval "$2"; then echo "RESIDUE-OK   $1"; else echo "RESIDUE-FAIL $1"; bad=1; fi; }
    chk "no /sys/fs/bpf/vantage"                 '[[ ! -e /sys/fs/bpf/vantage ]]'
    chk "no vantage files in /usr/local, /etc"   '[[ ! -e /usr/local/lib/vantage-5g && ! -e /usr/local/bin/vantage-5G && ! -e /etc/vantage-5g ]]'
    chk "no vantage unit files"                  '[[ -z "$(ls /etc/systemd/system/vantage-5g* 2>/dev/null)" ]]'
    chk "no XDP program on any interface"        '! ip -d link show | grep -q "prog/xdp"'
    chk "no clsact qdisc on any interface"       '! tc qdisc show | grep -q clsact'
    chk "no iperf3 process"                      '! pgrep -x iperf3 >/dev/null'
    chk "no rehearsal netns nb-a/nb-b"           '! ip netns list | grep -qE "^nb-"'
    chk "no vtlan0/vtbr0/vtnb/vtwl links"        '! ip -br link | grep -qE "^vt(lan|br|nb|wl)"'
    chk "no rehearsal users"                     '! id lapa >/dev/null 2>&1 && ! id lapb >/dev/null 2>&1 && ! id ueuser >/dev/null 2>&1'
    chk "no rehearsal networkd/sudoers files"    '[[ -z "$(ls ${NETD}/60-vt* /etc/sudoers.d/90-vt-rehearsal-* 2>/dev/null)" ]]'
    chk "no rehearsal MASQUERADE rules"          '! iptables -t nat -S POSTROUTING | grep -qE "172\.31\.0\.0/16|10\.100\.0\.0/24"'
    iptables -t nat -S POSTROUTING | grep -E "172\.31\.0\.0/16|10\.100\.0\.0/24" | sed 's/^/INFO leftover nat rule: /'
    chk "no UE route drop-in, no 10.45.0.0/16 route, no mgmt route" '[[ ! -e /etc/netplan/90-vantage-ue-route.yaml ]] && ! ip route show | grep -qE "^(10\.45\.0\.0/16|10\.100\.0\.0/24) .*via 10\.200"'
    # /run/vantage-5g.lock is the CLI writer lock (flock file, tmpfs): it stays by design.
    chk "no /run/vantage-5g* state (lock file aside)" '[[ -z "$(ls -d /run/vantage-5g* 2>/dev/null | grep -vx /run/vantage-5g.lock)" ]]'
    echo "INFO /run/vantage-5g*: $(ls -d /run/vantage-5g* 2>/dev/null | paste -sd' ' -)"
    chk "runbook artefacts gone from ~ubuntu"    '[[ ! -e ${U}/vantage-5G && ! -e ${U}/vt-l4 && ! -e ${U}/.cargo && ! -e ${U}/.ssh/vt_l4 ]]'
    echo "net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward) net.core.default_qdisc=$(sysctl -n net.core.default_qdisc)"
    [[ ${bad} -eq 0 ]] && echo "RESIDUE-RESULT clean" || echo "RESIDUE-RESULT dirty"
}

fill() {   # fill <file> KEY=VAL ...: replace the value token of each KEY= line (CHANGE_ME or empty)
    local f=$1; shift
    [[ -f ${f} ]] || { echo "[-] ${f} missing"; return 1; }
    local kv k v
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        grep -qE "^${k}=" "${f}" || continue
        sed -i -E "s|^${k}=[^ #]*|${k}=${v}|" "${f}"
    done
    echo "[edit] ${f}:"; grep -nE '^[A-Z_]+=' "${f}" | grep -v '^.*:SSHO='
}

case "${1:-}" in
    lan-up)         lan_up ;;
    lan-down)       lan_down ;;
    l3-client-up)   l3_client_up ;;
    l3-client-down) l3_client_down ;;
    ran-check)      ran_check ;;
    core-reset)     core_reset ;;
    svc-mgmt-up)    svc_mgmt_up ;;
    svc-mgmt-down)  svc_mgmt_down ;;
    askpass)        askpass ;;
    pre-clean)      pre_clean "${2:-}" ;;
    home-reset)     home_reset ;;
    residue)        residue "${2:-}" ;;
    fill)           shift; fill "$@" ;;
    run)
        ns=${2:-}; usr=${3:-}; [[ -n ${ns} && -n ${usr} ]] || { echo "run <netns> <user>"; exit 1; }
        cd /home/${usr} && exec ip netns exec "${ns}" sudo -u "${usr}" -H bash -i ;;
    *) sed -n '2,45p' "$0"; exit 1 ;;
esac
