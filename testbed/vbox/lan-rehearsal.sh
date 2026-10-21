#!/usr/bin/env bash
# lan-rehearsal.sh -- VM side of testbed/l2-lan-rehearsal.sh (run as root in an L2 VM).
#
# Emulates the topology of docs/install-runbook-lan.md inside one VM:
#
#   netns nb-a  eth0 192.168.77.21/24 ──┐                       (laptop A, user lapa, sshd)
#               wlan0 172.31.1.2 -> NAT │  bridge vtbr0
#   netns nb-b  eth0 192.168.77.22/24 ──┤  (L2 switch, no IP)
#               wlan0 172.31.2.2 -> NAT │
#   root ns     vtlan0 192.168.77.10/24 ┘ = the service node's $IF (Vantage attaches here)
#
# vtlan0 <-> vtlan0p (bridge port) and vtbr0 are systemd-networkd devices, so they exist at
# every boot like a real NIC (the runbook's reboot step 8.5 needs that). The laptops are
# network namespaces with a wired eth0 on the bridge and a "Wi-Fi" wlan0 that carries the
# default route to the internet (MASQUERADE through the VM's NAT NIC): apt works in them and
# the runbook's route checks run with a second NIC present. Each laptop runs its own sshd
# (password login allowed) so the runbook's SSH-driven measurement takes a real SSH path.
# Netns do not survive a reboot; `topo-up` re-creates them (the laptops "stay on").
#
#   topo-up              create / complete the topology (idempotent; run again after reboot)
#   topo-down            remove the topology AND the runbook's artefacts in ~ubuntu
#                        (~/vantage-5G, ~/vt-l4*, ~/.ssh/vt_l4*, ~/.cargo, ~/.rustup) so the
#                        next rehearsal starts like a fresh server
#   pre-clean            remove leftover Vantage state of an aborted rehearsal (uninstall,
#                        detach vtlan0, unload) -- prints what it removed
#   run a|b              run stdin as laptop a|b: `bash -i` as lapa|lapb inside nb-a|nb-b
#   fill-vars svc|a|b <commit>   the runbook's only manual edit (0.2), done with sed
#   residue              print RESIDUE-OK / RESIDUE-FAIL lines (Vantage + rehearsal state)
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

topo_up() {
    mkdir -p "${STATE}" "${RUN}"
    if [[ ! -f ${NETD}/60-vtlan.netdev ]]; then
        cat > ${NETD}/60-vtbr.netdev <<'EOF'
[NetDev]
Name=vtbr0
Kind=bridge
EOF
        cat > ${NETD}/60-vtbr.network <<'EOF'
[Match]
Name=vtbr0
[Link]
RequiredForOnline=no
[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes
EOF
        cat > ${NETD}/60-vtlan.netdev <<'EOF'
[NetDev]
Name=vtlan0
Kind=veth
[Peer]
Name=vtlan0p
EOF
        cat > ${NETD}/60-vtlan.network <<EOF
[Match]
Name=vtlan0
[Link]
RequiredForOnline=no
[Network]
Address=${SVC_IP}/24
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
        cat > ${NETD}/60-vtlanp.network <<'EOF'
[Match]
Name=vtlan0p
[Link]
RequiredForOnline=no
[Network]
Bridge=vtbr0
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
        networkctl reload
    fi
    for _ in $(seq 1 30); do ip -4 -o addr show dev vtlan0 2>/dev/null | grep -q " ${SVC_IP}/" && break; sleep 1; done
    ip -4 -o addr show dev vtlan0 | grep -q " ${SVC_IP}/" || { echo "[-] vtlan0 has no ${SVC_IP}"; return 1; }

    [[ -f ${STATE}/ip_forward.orig ]] || sysctl -n net.ipv4.ip_forward > ${STATE}/ip_forward.orig
    sysctl -qw net.ipv4.ip_forward=1
    local wan; wan=$(wan_if)
    iptables -t nat -C POSTROUTING -s 172.31.0.0/16 -o "${wan}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 172.31.0.0/16 -o "${wan}" -j MASQUERADE
    local dns; dns=$(awk '/^nameserver/ {print $2; exit}' /run/systemd/resolve/resolv.conf 2>/dev/null)

    # askpass for ssh-copy-id (runbook 2.4). Not under /run: it is mounted noexec.
    printf '#!/bin/sh\necho %s\n' "${PW}" > ${STATE}/askpass; chmod 755 ${STATE} ${STATE}/askpass
    echo 'lapa ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-vt-lan-rehearsal
    echo 'lapb ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/90-vt-lan-rehearsal
    chmod 440 /etc/sudoers.d/90-vt-lan-rehearsal
    local r ns ip n
    for r in a b; do
        ns=nb-${r}; ip=$(ip_of ${r}); n=$(n_of ${r})
        id lap${r} >/dev/null 2>&1 || useradd -m -s /bin/bash lap${r}
        echo "lap${r}:${PW}" | chpasswd
        ip netns list | grep -qw "${ns}" || ip netns add ${ns}
        mkdir -p /etc/netns/${ns}; echo "nameserver ${dns:-10.0.2.3}" > /etc/netns/${ns}/resolv.conf
        ip -n ${ns} link set lo up
        if ! ip -n ${ns} link show eth0 >/dev/null 2>&1; then
            ip link add vtnb-${r} type veth peer name vtnb-${r}-in
            ip link set vtnb-${r}-in netns ${ns}
            ip -n ${ns} link set vtnb-${r}-in name eth0
            ip link set vtnb-${r} master vtbr0 up
            ip -n ${ns} addr add ${ip}/24 dev eth0
            ip -n ${ns} link set eth0 up
        fi
        if ! ip -n ${ns} link show wlan0 >/dev/null 2>&1; then
            ip link add vtwl-${r} type veth peer name vtwl-${r}-in
            ip link set vtwl-${r}-in netns ${ns}
            ip -n ${ns} link set vtwl-${r}-in name wlan0
            ip addr add 172.31.${n}.1/24 dev vtwl-${r}; ip link set vtwl-${r} up
            ip -n ${ns} addr add 172.31.${n}.2/24 dev wlan0
            ip -n ${ns} link set wlan0 up
            ip -n ${ns} route add default via 172.31.${n}.1 dev wlan0
        fi
        local pid=${RUN}/sshd-${r}.pid
        if ! { [[ -f ${pid} ]] && kill -0 "$(cat ${pid})" 2>/dev/null; }; then
            ip netns exec ${ns} /usr/sbin/sshd -o ListenAddress=${ip} -o PidFile=${pid} \
                -o PasswordAuthentication=yes -o KbdInteractiveAuthentication=no
        fi
    done
    sleep 1
    for r in a b; do
        ip netns exec nb-${r} ping -c1 -W2 ${SVC_IP} >/dev/null && echo "[+] nb-${r} -> ${SVC_IP} ok" || echo "[-] nb-${r} cannot reach ${SVC_IP}"
        ip netns exec nb-${r} getent hosts archive.ubuntu.com >/dev/null && echo "[+] nb-${r} DNS/internet ok" || echo "[-] nb-${r} no DNS"
    done
    ip -br link show master vtbr0
    echo "[+] topology up: svc vtlan0 ${SVC_IP}, laptop A nb-a/lapa ${A_IP}, laptop B nb-b/lapb ${B_IP}"
}

topo_down() {
    local r
    for r in a b; do
        [[ -f ${RUN}/sshd-${r}.pid ]] && kill "$(cat ${RUN}/sshd-${r}.pid)" 2>/dev/null
        ip netns del nb-${r} 2>/dev/null
        ip link del vtnb-${r} 2>/dev/null; ip link del vtwl-${r} 2>/dev/null
        pkill -u lap${r} 2>/dev/null; sleep 0.5
        id lap${r} >/dev/null 2>&1 && userdel -r lap${r} 2>/dev/null
        rm -rf /etc/netns/nb-${r}
    done
    rm -f /etc/sudoers.d/90-vt-lan-rehearsal ${NETD}/60-vtbr.netdev ${NETD}/60-vtbr.network \
          ${NETD}/60-vtlan.netdev ${NETD}/60-vtlan.network ${NETD}/60-vtlanp.network
    networkctl reload
    ip link del vtlan0 2>/dev/null; ip link del vtbr0 2>/dev/null
    local wan; wan=$(wan_if)
    while iptables -t nat -D POSTROUTING -s 172.31.0.0/16 -o "${wan}" -j MASQUERADE 2>/dev/null; do :; done
    [[ -f ${STATE}/ip_forward.orig ]] && sysctl -qw net.ipv4.ip_forward="$(cat ${STATE}/ip_forward.orig)"
    rm -rf "${STATE}" "${RUN}"
    # The runbook's artefacts on the "service node" (a fresh server has none of them).
    rm -rf ${U}/vantage-5G ${U}/vt-l4 ${U}/vt-l4-*.tgz ${U}/.ssh/vt_l4 ${U}/.ssh/vt_l4.pub ${U}/.cargo ${U}/.rustup
    [[ -f ${U}/.ssh/known_hosts ]] && sed -i "/^${NET//./\\.}\./d" ${U}/.ssh/known_hosts
    for f in ${U}/.profile ${U}/.bashrc; do [[ -f $f ]] && sed -i '/\.cargo\/env/d' "$f"; done
    echo "[+] topology and runbook artefacts removed"
}

pre_clean() {
    if [[ -e /usr/local/lib/vantage-5g || -e /etc/vantage-5g ]]; then
        echo "[i] leftover service install: uninstall --purge"
        if [[ -x ${U}/vantage-5G/install.sh ]]; then ${U}/vantage-5G/install.sh uninstall --purge --force
        else systemctl disable --now vantage-5g vantage-5g-monitor 2>/dev/null
             rm -rf /usr/local/lib/vantage-5g /usr/local/bin/vantage-5G /etc/vantage-5g \
                    /etc/systemd/system/vantage-5g.service /etc/systemd/system/vantage-5g-monitor.service
             systemctl daemon-reload; fi
    fi
    if ip link show vtlan0 >/dev/null 2>&1 && { ip -d link show dev vtlan0 | grep -q prog/xdp || tc qdisc show dev vtlan0 | grep -q clsact; }; then
        echo "[i] leftover attach on vtlan0: detach"
        ip link set dev vtlan0 xdpgeneric off 2>/dev/null; ip link set dev vtlan0 xdpdrv off 2>/dev/null
        tc qdisc del dev vtlan0 clsact 2>/dev/null; tc qdisc del dev vtlan0 root 2>/dev/null
    fi
    [[ -e /sys/fs/bpf/vantage ]] && { echo "[i] leftover pins: removed"; rm -rf /sys/fs/bpf/vantage; }
    pkill -x iperf3 2>/dev/null
    true
}

residue() {
    local bad=0
    chk() { if eval "$2"; then echo "RESIDUE-OK   $1"; else echo "RESIDUE-FAIL $1"; bad=1; fi; }
    chk "no /sys/fs/bpf/vantage"                 '[[ ! -e /sys/fs/bpf/vantage ]]'
    chk "no vantage files in /usr/local, /etc"   '[[ ! -e /usr/local/lib/vantage-5g && ! -e /usr/local/bin/vantage-5G && ! -e /etc/vantage-5g ]]'
    chk "no vantage unit files"                  '[[ -z "$(ls /etc/systemd/system/vantage-5g* 2>/dev/null)" ]]'
    chk "no XDP program on any interface"        '! ip -d link show | grep -q "prog/xdp"'
    chk "no clsact qdisc on any interface"       '! tc qdisc show | grep -q clsact'
    chk "no iperf3 process"                      '! pgrep -x iperf3 >/dev/null'
    chk "no rehearsal netns"                     '[[ -z "$(ip netns list)" ]]'
    chk "no vtlan0/vtbr0/vtnb/vtwl links"        '! ip -br link | grep -qE "^vt(lan|br|nb|wl)"'
    chk "no lapa/lapb users"                     '! id lapa >/dev/null 2>&1 && ! id lapb >/dev/null 2>&1'
    chk "no rehearsal networkd/sudoers files"    '[[ -z "$(ls ${NETD}/60-vt* /etc/sudoers.d/90-vt-lan-rehearsal 2>/dev/null)" ]]'
    chk "no MASQUERADE rule for 172.31/16"       '! iptables -t nat -S POSTROUTING | grep -q 172.31.0.0/16'
    # /run/vantage-5g.lock is the CLI writer lock (flock file, tmpfs): it stays by design.
    chk "no /run/vantage-5g* state (lock file aside)" '[[ -z "$(ls -d /run/vantage-5g* 2>/dev/null | grep -vx /run/vantage-5g.lock)" ]]'
    echo "INFO /run/vantage-5g*: $(ls -d /run/vantage-5g* 2>/dev/null | paste -sd' ' -)" 
    chk "runbook artefacts gone from ~ubuntu"    '[[ ! -e ${U}/vantage-5G && ! -e ${U}/vt-l4 && ! -e ${U}/.cargo && ! -e ${U}/.ssh/vt_l4 ]]'
    echo "net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward) net.core.default_qdisc=$(sysctl -n net.core.default_qdisc)"
    [[ ${bad} -eq 0 ]] && echo "RESIDUE-RESULT clean" || echo "RESIDUE-RESULT dirty"
}

fill_vars() {
    local host=$1 commit=$2 f
    case "${host}" in
        svc) f=${U}/vt-l4/vars.sh ;;
        a|b) f=/home/lap${host}/vt-l4/vars.sh ;;
        *) echo "fill-vars svc|a|b <commit>"; return 1 ;;
    esac
    [[ -f ${f} ]] || { echo "[-] ${f} missing"; return 1; }
    local ifn=eth0; [[ ${host} == svc ]] && ifn=vtlan0
    sed -i -E -e "s|^IF=CHANGE_ME|IF=${ifn}|" -e "s|^SVC=CHANGE_ME|SVC=${SVC_IP}|" \
        -e "s|^UE_A=CHANGE_ME|UE_A=${A_IP}|" -e "s|^UE_B=CHANGE_ME|UE_B=${B_IP}|" "${f}"
    if [[ ${host} == svc ]]; then
        sed -i -E -e "s|^UE_A_USER=CHANGE_ME|UE_A_USER=lapa|" -e "s|^UE_B_USER=CHANGE_ME|UE_B_USER=lapb|" \
            -e "s|^COMMIT=CHANGE_ME|COMMIT=${commit}|" "${f}"
    fi
    echo "[edit] ${f}:"; grep -nE '^(ROLE|IF|SVC|UE_A|UE_B|UE_A_USER|UE_B_USER|COMMIT)=' "${f}"
}

case "${1:-}" in
    topo-up)   topo_up ;;
    topo-down) topo_down ;;
    pre-clean) pre_clean ;;
    residue)   residue ;;
    fill-vars) fill_vars "${2:-}" "${3:-}" ;;
    run)
        r=${2:-}; [[ ${r} == a || ${r} == b ]] || { echo "run a|b"; exit 1; }
        cd /home/lap${r} && exec ip netns exec nb-${r} sudo -u lap${r} -H bash -i ;;
    *) sed -n '2,30p' "$0"; exit 1 ;;
esac
