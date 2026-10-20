# vm-lib.sh — VirtualBox helpers shared by testbed/l2-vbox.sh and testbed/l3-vbox.sh.
# Source it, then call vm_config, which sets the globals the other functions use:
#   VM REL REL_NAME PORT CACHE VMDIR KEY SSH_OPTS
#   VM_CPUS VM_MEM VM_DISK_MB USER_DATA (cloud-init template with @SSH_PUBKEY@/@HOSTNAME@)
# The sizes and template come only from vm_config's arguments (never from the caller's
# environment), so l2-vbox.sh behaves the same whatever the user's shell exports.
#
# Provisioning: Ubuntu cloud image (vmdk -> vdi) + cloud-init NoCloud seed ISO.
# Access: NAT port-forward 127.0.0.1:${PORT} -> 22 with a dedicated key.
# Serial console (boot log): ${VMDIR}/console.log.

# vm_config <vm> <release noble|jammy> <ssh port> [cpus mem_mb disk_mb user-data-template]
#   defaults: 4 4096 20480 testbed/vbox/user-data.tmpl (the L2 service VM)
vm_config() {
    VM=$1; REL=$2; PORT=$3
    VM_CPUS=${4:-4}; VM_MEM=${5:-4096}; VM_DISK_MB=${6:-20480}; USER_DATA=${7:-testbed/vbox/user-data.tmpl}
    case "${REL}" in
        noble) REL_NAME="Ubuntu 24.04" ;;
        jammy) REL_NAME="Ubuntu 22.04" ;;
        *) echo "release must be noble or jammy (got '${REL}')"; return 1 ;;
    esac
    CACHE=${VT_CACHE:-${HOME}/.cache/vantage-5g}
    VMDIR=${CACHE}/vm/${VM}
    KEY=${CACHE}/ssh/id_ed25519
    SSH_OPTS=(-i "${KEY}" -p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15)
}

command -v VBoxManage >/dev/null || { echo "VirtualBox (VBoxManage) not found"; exit 1; }
vm_exists()  { VBoxManage showvminfo "${VM}" >/dev/null 2>&1; }
vm_running() { VBoxManage showvminfo "${VM}" --machinereadable 2>/dev/null | grep -q '^VMState="running"'; }
vm_start()   { vm_running || VBoxManage startvm "${VM}" --type headless >/dev/null; }
vssh()       { ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 "$@"; }

# vm_timer_health — print host state and the guest's timer wake-up latency (300 x 10 ms sleeps).
# VirtualBox on macOS runs these guests in NEM "turtle" mode (driverless; see VBox.log). When the
# host is contended (several VMs running, multipassd, builds) the VM's VBoxHeadless burns >100% CPU
# even with an idle guest and timer wake-ups arrive tens of ms late; every shaper in the guest
# (Vantage EDT/XDP, kernel fq maxrate, tc police) then under-delivers (X10). Healthy: p99 about
# 11-15 ms, VBoxHeadless idle under ~15%. Last line: "timer-health OK|DEGRADED p50 … p99 … max …".
# Informational only: it does not change or skip any test.
vm_timer_health() {
    echo "host: $(uptime)"
    echo "running VMs:"; VBoxManage list runningvms 2>/dev/null | sed 's/^/  /'
    echo "VBoxHeadless CPU (ps, decayed average):"
    ps -Ao pcpu=,args= | awk '/VBoxHeadless --comment/ && !/awk/ {print "  " $1 "%  " $4}'
    vssh "python3 -" <<'PY'
import time
g = []
last = time.monotonic()
for _ in range(300):
    time.sleep(0.01)
    n = time.monotonic(); g.append((n - last) * 1000); last = n
g.sort()
p50, p99, mx = g[150], g[296], g[-1]
print("timer-health %s p50 %.1f ms p99 %.1f ms max %.1f ms (sleep 10 ms x300)"
      % ("OK" if p99 <= 25 else "DEGRADED", p50, p99, mx))
PY
}

create_vm() {
    mkdir -p "${CACHE}/ssh" "${VMDIR}/seed"
    [[ -f "${KEY}" ]] || ssh-keygen -q -t ed25519 -N '' -C vantage-testbed -f "${KEY}"

    local base=${CACHE}/${REL}-server-cloudimg-amd64.vmdk
    local url=https://cloud-images.ubuntu.com/${REL}/current/${REL}-server-cloudimg-amd64.vmdk
    if [[ ! -f "${base}" ]]; then
        echo "[*] downloading ${REL_NAME} cloud image"
        curl -fL --progress-bar -o "${base}.part" "${url}" && mv "${base}.part" "${base}" || exit 1
    fi
    local disk=${VMDIR}/${VM}.vdi
    # clonemedium registers the source image in the global media registry; a later clone
    # from the same file then fails with a UUID mismatch. Release it before and after.
    VBoxManage closemedium disk "${base}" >/dev/null 2>&1
    VBoxManage clonemedium disk "${base}" "${disk}" --format VDI >/dev/null || exit 1
    VBoxManage closemedium disk "${base}" >/dev/null 2>&1
    VBoxManage modifymedium disk "${disk}" --resize "${VM_DISK_MB}" >/dev/null || exit 1

    sed -e "s|@SSH_PUBKEY@|$(cat "${KEY}.pub")|" -e "s|@HOSTNAME@|${VM}|" "${USER_DATA}" > "${VMDIR}/seed/user-data"
    printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "${VM}" "$(date +%s)" "${VM}" > "${VMDIR}/seed/meta-data"
    rm -f "${VMDIR}/seed.iso"
    hdiutil makehybrid -quiet -o "${VMDIR}/seed.iso" "${VMDIR}/seed" -iso -joliet -default-volume-name cidata || exit 1

    VBoxManage createvm --name "${VM}" --ostype Ubuntu_64 --basefolder "${CACHE}/vm" --register >/dev/null || exit 1
    VBoxManage modifyvm "${VM}" --cpus "${VM_CPUS}" --memory "${VM_MEM}" --nic1 nat --nictype1 virtio \
        --natpf1 "ssh,tcp,127.0.0.1,${PORT},,22" --graphicscontroller vmsvga --vram 16 \
        --audio-enabled off --usb off \
        --uart1 0x3F8 4 --uartmode1 file "${VMDIR}/console.log"
    VBoxManage storagectl "${VM}" --name SATA --add sata --controller IntelAhci --portcount 2
    VBoxManage storageattach "${VM}" --storagectl SATA --port 0 --device 0 --type hdd --medium "${disk}"
    VBoxManage storageattach "${VM}" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "${VMDIR}/seed.iso"
    echo "[+] VM ${VM} (${REL_NAME}) created (ssh 127.0.0.1:${PORT})"
}

wait_ready() {
    echo -n "[*] ${VM}: waiting for ssh"
    for _ in $(seq 1 120); do vssh true 2>/dev/null && break; echo -n .; sleep 5; done; echo
    vssh true || { echo "[-] ssh not reachable; boot log: ${VMDIR}/console.log"; exit 1; }
    echo "[*] ${VM}: waiting for cloud-init (first boot installs toolchain, several minutes)"
    vssh 'cloud-init status --wait >/dev/null; cloud-init status --long | head -3'
}

# vm_poweroff: ACPI shutdown, then hard power-off after 90 s.
vm_poweroff() {
    vm_running || return 0
    VBoxManage controlvm "${VM}" acpipowerbutton >/dev/null 2>&1
    for _ in $(seq 1 45); do vm_running || return 0; sleep 2; done
    VBoxManage controlvm "${VM}" poweroff >/dev/null 2>&1; sleep 2
}

vm_delete() {
    vm_running && VBoxManage controlvm "${VM}" poweroff >/dev/null
    vm_exists && VBoxManage unregistervm "${VM}" --delete
    rm -rf "${VMDIR}"
}
