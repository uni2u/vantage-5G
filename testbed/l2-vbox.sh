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
# Provisioning (testbed/vbox/vm-lib.sh): Ubuntu cloud image (vmdk -> vdi) + cloud-init
# NoCloud seed ISO. Access: NAT port-forward 127.0.0.1:${VT_SSH_PORT} -> 22 with a dedicated key.
# vantage-svc may carry a second NIC (internal network vantage-n6) added by
# testbed/l3-vbox.sh; L2 does not use it.
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
# shellcheck source=vbox/vm-lib.sh
. testbed/vbox/vm-lib.sh
vm_config "${VM:-${DEF_VM}}" "${REL}" "${VT_SSH_PORT:-${DEF_PORT}}" || exit 1

case "${1:-test}" in
    delete)
        vm_delete; exit 0 ;;
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
# Timer-health preflight (X10): record host contention; throughput verdicts are only meaningful
# when this says OK. Informational, never fails the run.
vm_timer_health > "${OUT}/timer-health.txt" 2>&1
th=$(tail -1 "${OUT}/timer-health.txt")
case "${th}" in
    *DEGRADED*) echo "[!] ${th} -- throughput rows will under-deliver (environment, X10); see ${OUT}/timer-health.txt" ;;
    *) echo "[i] ${th}" ;;
esac
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
