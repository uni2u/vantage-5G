#!/usr/bin/env bash
# l2-systemd.sh — systemd service test (install.sh, systemd/ units, apply/export) on an
# L2 VirtualBox VM, including a reboot.
#
#   ./testbed/l2-systemd.sh                  # noble VM (vantage-svc)
#   VT_RELEASE=jammy ./testbed/l2-systemd.sh # jammy VM (vantage-svc-jammy)
#   ./testbed/l2-systemd.sh cleanup          # only the cleanup step (after an aborted run)
#
# Steps (body: testbed/vbox/systemd-test.sh, run as root in the VM from ~ubuntu/work):
#   pre -> reboot the VM (boot id must change) -> post -> cleanup (always, also after a FAIL)
# Results: _workspace/l2sd-<release>-<ts>/{pre,post,cleanup}.log, timer-health.txt,
# commit.txt, summary.txt. Exit 0 only if every step printed its RESULT line with fail=0.
#
# The VM must exist (create it with ./testbed/l2-vbox.sh). The test installs into the VM's
# /usr/local, /etc/systemd and /etc/vantage-5g and creates a systemd-networkd veth vn6 /
# netns ue / 10.99.1.0/24; cleanup removes all of it. Do not run it while l2-vbox.sh or
# l3-vbox.sh uses the same VM, and run one VM at a time (testbed/README §10, X10).
# Throughput lines in post.log are informational (functional test); a DEGRADED
# timer-health makes them low.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
REL=${VT_RELEASE:-noble}
case "${REL}" in
    noble) DEF_VM=vantage-svc;       DEF_PORT=2522 ;;
    jammy) DEF_VM=vantage-svc-jammy; DEF_PORT=2523 ;;
    *) echo "VT_RELEASE must be noble or jammy (got '${REL}')"; exit 1 ;;
esac
# shellcheck source=vbox/vm-lib.sh
. testbed/vbox/vm-lib.sh
vm_config "${VM:-${DEF_VM}}" "${REL}" "${VT_SSH_PORT:-${DEF_PORT}}" || exit 1

MODE=${1:-test}
case "${MODE}" in
    test|cleanup) ;;
    *) echo "usage: $0 [test|cleanup]"; exit 1 ;;
esac
vm_exists || { echo "[-] VM ${VM} does not exist; create it with: VT_RELEASE=${REL} ./testbed/l2-vbox.sh"; exit 1; }
vm_start || exit 1
wait_ready

TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/l2sd-${REL}-${TS}
mkdir -p "${OUT}"
BODY=/home/ubuntu/work/testbed/vbox/systemd-test.sh

# step <name>: run one step as root, log to OUT/<name>.log, record its RESULT line.
step() {
    echo "=== ${1}"
    vssh "sudo -i bash ${BODY} ${1}" 2>&1 | tee "${OUT}/${1}.log" | grep -E '^(PASS|FAIL) |^RESULT-'
    local r
    r=$(grep -E "^RESULT-${1} " "${OUT}/${1}.log" | tail -1)
    echo "${1}: ${r:-no RESULT line (aborted)}" >> "${OUT}/summary.txt"
}

if [[ "${MODE}" == test ]]; then
    rsync -a --delete -e "ssh ${SSH_OPTS[*]}" --exclude target --exclude '_workspace*' --exclude .git \
        "${ROOT}/" ubuntu@127.0.0.1:work/ || exit 1
    git -C "${ROOT}" describe --always --dirty > "${OUT}/commit.txt" 2>/dev/null || echo no-git > "${OUT}/commit.txt"
    echo "release=${REL} vm=${VM}" >> "${OUT}/commit.txt"
    vm_timer_health > "${OUT}/timer-health.txt" 2>&1
    echo "[i] $(tail -1 "${OUT}/timer-health.txt")"

    step pre
    if grep -q '^RESULT-pre ' "${OUT}/pre.log"; then
        boot1=$(vssh 'cat /proc/sys/kernel/random/boot_id')
        echo "=== reboot"
        vssh 'sudo systemctl reboot' >/dev/null 2>&1
        for _ in $(seq 1 60); do vssh true 2>/dev/null || break; sleep 2; done
        wait_ready >/dev/null
        boot2=$(vssh 'cat /proc/sys/kernel/random/boot_id')
        if [[ -n "${boot2}" && "${boot1}" != "${boot2}" ]]; then
            echo "reboot: boot id ${boot1} -> ${boot2}" >> "${OUT}/summary.txt"
            step post
        else
            echo "reboot: FAIL (boot id unchanged or VM unreachable; post not run)" >> "${OUT}/summary.txt"
        fi
    else
        echo "post: not run (pre aborted)" >> "${OUT}/summary.txt"
    fi
fi
step cleanup

echo; cat "${OUT}/summary.txt"; echo "L2 systemd results: ${OUT}"
want=3; [[ "${MODE}" == cleanup ]] && want=1
ok=$(grep -cE '^(pre|post|cleanup): RESULT-[a-z]+ pass=[0-9]+ fail=0$' "${OUT}/summary.txt")
[[ "${ok}" -eq "${want}" ]] && ! grep -q '^reboot: FAIL' "${OUT}/summary.txt"
