#!/usr/bin/env bash
# l3-vbox.sh — L3 testbed: Open5GS reference install + UERANSIM on one VM, Vantage on another,
# joined by an N6 link (VirtualBox internal network). Mirrors the target deployment:
# the UPF host and the service node are separate machines; UEs come from UERANSIM.
#
#   ./testbed/l3-vbox.sh up        create/provision both VMs (first run: ~30 min), start RAN
#   ./testbed/l3-vbox.sh test      scenarios (a) reference NAT and (b) README §3.2 + §8
#   ./testbed/l3-vbox.sh ssh-core  shell on vantage-core
#   ./testbed/l3-vbox.sh ssh-svc   shell on vantage-svc
#   ./testbed/l3-vbox.sh down      stop the RAN, power both VMs off
#   ./testbed/l3-vbox.sh delete    remove vantage-core (vantage-svc is the L2 VM: only its
#                                  second NIC is removed; use l2-vbox.sh delete for the VM)
#
#   vantage-core  Ubuntu 22.04, 4 vCPU / 6 GB, ssh 127.0.0.1:2524
#                 NIC1 NAT (internet, ssh), NIC2 intnet "vantage-n6" 10.200.0.1/24 (UPF N6)
#                 Open5GS (ppa:open5gs/latest) + MongoDB 8.0 + UERANSIM (testbed/vbox/core-provision.sh)
#                 gNB + 2 UEs in netns "ran" (testbed/vbox/core-ran.sh)
#   vantage-svc   the L2 VM (Ubuntu 24.04, ssh 127.0.0.1:2522) plus NIC2 intnet "vantage-n6"
#                 10.200.0.2/24 (= <IF> in README §3.2). NIC2 is added with the VM powered off
#                 and is not used by L2 (run-tests.sh uses its own veth vt-n6).
#
# Results: _workspace/l3-<ts>/ (summary.txt, per-step .log, iperf3 JSON, spec.csv,
# verdict*.txt, stats_*.txt, tcpdump captures).
# Env: T (iperf3 seconds, default 30), UERANSIM_REF / UERANSIM_COMMIT / DBCTL_SHA256
#      (passed to core-provision.sh by `up`), VT_L3_CAPS
#      ("A_rx A_tx B_rx B_tx" Mbps; default chosen from the measured path capacity).

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. testbed/vbox/vm-lib.sh

N6_NET=vantage-n6
CORE_MAC=080027A06E01; SVC_MAC=080027A06E02
CORE_N6=10.200.0.1;    SVC=10.200.0.2;    SVC_NET=10.200.0.0/24
UE_NET=10.45.0.0/16
macfmt() { echo "$1" | sed 's/../&:/g; s/:$//' | tr 'A-F' 'a-f'; }

core() { vm_config vantage-core jammy 2524 4 6144 20480 testbed/vbox/core-user-data.tmpl; }
svc()  { vm_config vantage-svc noble 2522; }
csh()  { core; vssh "$@"; }
ssh_s() { svc; vssh "$@"; }
# Root shell on a VM: argv joined into one bash -c string (quote accordingly).
croot() { csh "sudo bash -c $(printf %q "$*")"; }
sroot() { ssh_s "sudo bash -c $(printf %q "$*")"; }

svc_n6_if() { ssh_s "ip -o link | awk -F': ' '/$(macfmt ${SVC_MAC})/ {print \$2}'" | tr -d '\r'; }

up_core() {
    core
    if ! vm_exists; then
        create_vm
        VBoxManage modifyvm "${VM}" --nic2 intnet --intnet2 "${N6_NET}" --nictype2 virtio \
            --macaddress2 "${CORE_MAC}" --nicpromisc2 allow-all
    fi
    vm_start || exit 1
    wait_ready
    rsync -a -e "ssh ${SSH_OPTS[*]}" testbed/vbox/core-provision.sh testbed/vbox/core-ran.sh ubuntu@127.0.0.1: || exit 1
    echo "[*] vantage-core: provisioning (Open5GS, MongoDB, UERANSIM build; log /var/log/vantage-core-provision.log)"
    local penv="N6_MAC=$(macfmt ${CORE_MAC}) N6_ADDR=${CORE_N6}/24" v
    for v in UERANSIM_REF UERANSIM_COMMIT DBCTL_SHA256; do [[ -n "${!v:-}" ]] && penv+=" ${v}=$(printf %q "${!v}")"; done
    vssh "sudo env ${penv} bash ./core-provision.sh" \
        > "${ROOT}/_workspace/l3-core-provision.log" 2>&1 \
        || { tail -30 "${ROOT}/_workspace/l3-core-provision.log"; echo "[-] core provisioning failed"; exit 1; }
    tail -3 "${ROOT}/_workspace/l3-core-provision.log"
    vssh "sudo bash ./core-ran.sh nat-reference >/dev/null && sudo bash ./core-ran.sh up" || exit 1
}

up_svc() {
    svc
    vm_exists || { echo "[-] vantage-svc missing: create it with ./testbed/l2-vbox.sh first"; exit 1; }
    if ! VBoxManage showvminfo "${VM}" --machinereadable | grep -q "^intnet2=\"${N6_NET}\""; then
        echo "[*] vantage-svc: adding NIC2 (intnet ${N6_NET}); powering the VM off first"
        vm_poweroff
        VBoxManage modifyvm "${VM}" --nic2 intnet --intnet2 "${N6_NET}" --nictype2 virtio \
            --macaddress2 "${SVC_MAC}" --nicpromisc2 allow-all || exit 1
    fi
    vm_start || exit 1
    wait_ready
    sroot "printf '%s\n' network: '  version: 2' '  ethernets:' '    n6:' '      match:' \
        '        macaddress: \"$(macfmt ${SVC_MAC})\"' '      addresses: [${SVC}/24]' > /etc/netplan/60-vantage-n6.yaml
        chmod 600 /etc/netplan/60-vantage-n6.yaml; netplan apply" || exit 1
    rsync -a --delete -e "ssh ${SSH_OPTS[*]}" --exclude target --exclude '_workspace*' --exclude .git \
        "${ROOT}/" ubuntu@127.0.0.1:work/ || exit 1
    echo "[*] vantage-svc: make build"
    vssh "sudo -i bash -c 'cd /home/ubuntu/work && make build'" > "${ROOT}/_workspace/l3-svc-build.log" 2>&1 \
        || { tail -20 "${ROOT}/_workspace/l3-svc-build.log"; exit 1; }
    echo "[+] vantage-svc N6 = $(svc_n6_if) ${SVC}/24"
}

case "${1:-}" in
    up)
        mkdir -p "${ROOT}/_workspace"
        up_core; up_svc
        ssh_s "ping -c2 -W2 ${CORE_N6}" >/dev/null && echo "[+] N6 link ${SVC} <-> ${CORE_N6} up" \
            || { echo "[-] N6 link down (intnet ${N6_NET})"; exit 1; }
        exit 0 ;;
    ssh-core) core; vm_start; wait_ready >/dev/null; exec ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 ;;
    ssh-svc)  svc;  vm_start; wait_ready >/dev/null; exec ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 ;;
    down)
        core; vm_running && vssh "sudo bash ./core-ran.sh down"; vm_poweroff
        svc; vm_poweroff; exit 0 ;;
    delete)
        core; vm_delete
        svc; if vm_exists; then vm_poweroff; VBoxManage modifyvm "${VM}" --nic2 none; fi
        exit 0 ;;
    test)
        # Bring both VMs up (e.g. after `down`); the RAN is restarted by l3-test.sh if needed.
        mkdir -p "${ROOT}/_workspace"
        core; vm_exists || { echo "[-] vantage-core missing: run ./testbed/l3-vbox.sh up"; exit 1; }
        vm_start || exit 1; wait_ready >/dev/null
        svc;  vm_exists || { echo "[-] vantage-svc missing: run ./testbed/l3-vbox.sh up"; exit 1; }
        vm_start || exit 1; wait_ready >/dev/null ;;
    *) echo "usage: $0 up|test|ssh-core|ssh-svc|down|delete"; exit 1 ;;
esac

# ---------------------------------------------------------------- test
. testbed/vbox/l3-test.sh
