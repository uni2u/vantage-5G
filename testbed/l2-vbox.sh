#!/usr/bin/env bash
# l2-vbox.sh — run testbed/run-tests.sh on a VirtualBox Ubuntu VM (24.04 or 22.04).
#
# Unlike L1 (Docker Desktop), the VM runs a stock Ubuntu kernel, so sch_fq is
# available: setup.sh, DL EDT pacing and the full 4-session iperf3 check run.
#
#   ./testbed/l2-vbox.sh            # create VM on first use, then test
#   T=30 ./testbed/l2-vbox.sh
#   ./testbed/l2-vbox.sh ssh        # shell into the VM
#   ./testbed/l2-vbox.sh stop       # power off
#   ./testbed/l2-vbox.sh delete     # remove VM and its disk
#
# Release (README §3 supports both):
#   VT_RELEASE=noble  (default) VM vantage-svc,       ssh 127.0.0.1:2522
#   VT_RELEASE=jammy            VM vantage-svc-jammy, ssh 127.0.0.1:2523
# Passed through to run-tests.sh: VT_SETUP_AS, VT_NONROOT_USER, VT_NO_BPFTOOL, VT_NAT, VT_NETEM,
# VT_XDP_MODE, VT_N6_TXQ, VT_N6_TXQ_MAX.
#
# Provisioning: Ubuntu cloud image (vmdk -> vdi) + cloud-init NoCloud seed ISO.
# Access: NAT port-forward 127.0.0.1:${VT_SSH_PORT} -> 22 with a dedicated key.
# The repo is rsync'ed to the VM (no shared folders => no Guest Additions);
# results are copied back to _workspace/l2-<ts>/.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
REL=${VT_RELEASE:-noble}
case "${REL}" in
    noble) DEF_VM=vantage-svc;       DEF_PORT=2522; REL_NAME="Ubuntu 24.04" ;;
    jammy) DEF_VM=vantage-svc-jammy; DEF_PORT=2523; REL_NAME="Ubuntu 22.04" ;;
    *) echo "VT_RELEASE must be noble or jammy (got '${REL}')"; exit 1 ;;
esac
VM=${VM:-${DEF_VM}}
PORT=${VT_SSH_PORT:-${DEF_PORT}}
CACHE=${VT_CACHE:-${HOME}/.cache/vantage-5g}
IMG_URL=https://cloud-images.ubuntu.com/${REL}/current/${REL}-server-cloudimg-amd64.vmdk
VMDIR=${CACHE}/vm/${VM}
KEY=${CACHE}/ssh/id_ed25519
SSH_OPTS=(-i "${KEY}" -p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5)

command -v VBoxManage >/dev/null || { echo "VirtualBox (VBoxManage) not found"; exit 1; }
vm_exists()  { VBoxManage showvminfo "${VM}" >/dev/null 2>&1; }
vm_running() { VBoxManage showvminfo "${VM}" --machinereadable 2>/dev/null | grep -q '^VMState="running"'; }
vssh()       { ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 "$@"; }

create_vm() {
    mkdir -p "${CACHE}/ssh" "${VMDIR}/seed"
    [[ -f "${KEY}" ]] || ssh-keygen -q -t ed25519 -N '' -C vantage-testbed -f "${KEY}"

    local base=${CACHE}/${REL}-server-cloudimg-amd64.vmdk
    if [[ ! -f "${base}" ]]; then
        echo "[*] downloading ${REL_NAME} cloud image"
        curl -fL --progress-bar -o "${base}.part" "${IMG_URL}" && mv "${base}.part" "${base}" || exit 1
    fi
    local disk=${VMDIR}/${VM}.vdi
    VBoxManage clonemedium disk "${base}" "${disk}" --format VDI >/dev/null || exit 1
    VBoxManage modifymedium disk "${disk}" --resize 20480 >/dev/null || exit 1

    sed -e "s|@SSH_PUBKEY@|$(cat "${KEY}.pub")|" -e "s|@HOSTNAME@|${VM}|" testbed/vbox/user-data.tmpl > "${VMDIR}/seed/user-data"
    printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "${VM}" "$(date +%s)" "${VM}" > "${VMDIR}/seed/meta-data"
    rm -f "${VMDIR}/seed.iso"
    hdiutil makehybrid -quiet -o "${VMDIR}/seed.iso" "${VMDIR}/seed" -iso -joliet -default-volume-name cidata || exit 1

    VBoxManage createvm --name "${VM}" --ostype Ubuntu_64 --basefolder "${CACHE}/vm" --register >/dev/null || exit 1
    VBoxManage modifyvm "${VM}" --cpus 4 --memory 4096 --nic1 nat --nictype1 virtio \
        --natpf1 "ssh,tcp,127.0.0.1,${PORT},,22" --graphicscontroller vmsvga --vram 16 \
        --audio-enabled off --usb off \
        --uart1 0x3F8 4 --uartmode1 file "${VMDIR}/console.log"
    VBoxManage storagectl "${VM}" --name SATA --add sata --controller IntelAhci --portcount 2
    VBoxManage storageattach "${VM}" --storagectl SATA --port 0 --device 0 --type hdd --medium "${disk}"
    VBoxManage storageattach "${VM}" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "${VMDIR}/seed.iso"
    echo "[+] VM ${VM} (${REL_NAME}) created (ssh 127.0.0.1:${PORT})"
}

wait_ready() {
    echo -n "[*] waiting for ssh"
    for _ in $(seq 1 120); do vssh true 2>/dev/null && break; echo -n .; sleep 5; done; echo
    vssh true || { echo "[-] ssh not reachable; boot log: ${VMDIR}/console.log"; exit 1; }
    echo "[*] waiting for cloud-init (first boot installs toolchain, several minutes)"
    vssh 'cloud-init status --wait >/dev/null; cloud-init status --long | head -3'
}

case "${1:-test}" in
    delete)
        vm_running && VBoxManage controlvm "${VM}" poweroff >/dev/null
        vm_exists && VBoxManage unregistervm "${VM}" --delete
        rm -rf "${VMDIR}"; exit 0 ;;
    stop)
        vm_running && VBoxManage controlvm "${VM}" acpipowerbutton; exit 0 ;;
    ssh)
        vm_running || VBoxManage startvm "${VM}" --type headless >/dev/null
        wait_ready >/dev/null; exec ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 ;;
    test) ;;
    *) echo "usage: $0 [test|ssh|stop|delete]"; exit 1 ;;
esac

vm_exists || create_vm
vm_running || VBoxManage startvm "${VM}" --type headless >/dev/null || exit 1
wait_ready

TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/l2-${REL}-${TS}
mkdir -p "${OUT}"
rsync -a --delete -e "ssh ${SSH_OPTS[*]}" --exclude target --exclude '_workspace*' --exclude .git \
    "${ROOT}/" ubuntu@127.0.0.1:work/ || exit 1
# Tested tree: HEAD plus "-dirty" when tracked files have uncommitted changes.
git -C "${ROOT}" describe --always --dirty > "${OUT}/commit.txt" 2>/dev/null || echo no-git > "${OUT}/commit.txt"
echo "release=${REL} vm=${VM}" >> "${OUT}/commit.txt"
PASS_ENV=""
for v in VT_SETUP_AS VT_NONROOT_USER VT_NO_BPFTOOL VT_NAT VT_NETEM VT_XDP_MODE VT_N6_TXQ VT_N6_TXQ_MAX; do
    [[ -n "${!v:-}" ]] && PASS_ENV+=" ${v}=$(printf %q "${!v}")"
done

# sudo -i re-quotes its command line, so keep it a plain argv and collect results separately.
vssh "sudo -i env OUT=/home/ubuntu/results-${TS} T=${T:-30}${PASS_ENV} bash /home/ubuntu/work/testbed/run-tests.sh"
rc=$?
vssh "sudo chown -R ubuntu /home/ubuntu/results-${TS}"
rsync -a -e "ssh ${SSH_OPTS[*]}" "ubuntu@127.0.0.1:results-${TS}/" "${OUT}/"
echo "L2 results: ${OUT}"
exit ${rc}
