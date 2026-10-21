#!/usr/bin/env bash
# l2-lan-rehearsal.sh -- paste rehearsal of docs/install-runbook-lan.md on an L2 VM.
#
#   ./testbed/l2-lan-rehearsal.sh                 # jammy VM (vantage-svc-jammy), all blocks
#   VT_RELEASE=noble ./testbed/l2-lan-rehearsal.sh
#   FROM=5.2 ./testbed/l2-lan-rehearsal.sh        # resume at block id 5.2 (VM state kept)
#   UNTIL=4.1 ./testbed/l2-lan-rehearsal.sh       # stop after block 4.1 (no teardown)
#   KEEP_VM=1 ...                                 # do not power the VM off at the end
#
# Every ```bash block of the runbook that carries a <!-- rh: id=… host=… --> comment is
# extracted verbatim (testbed/vbox/runbook_blocks.py) and fed as stdin to an interactive
# `bash -i` -- the same conditions as pasting into a terminal without bracketed paste
# (history expansion is on; a command that reads stdin would eat the following lines):
#   host=svc  ssh ubuntu@VM 'bash -i'   (a real SSH login of the service-node user)
#   host=a|b  sudo lan-rehearsal.sh run a|b  -> netns nb-a|nb-b, user lapa|lapb, bash -i
# Substitutions (the only ones): mode=edit blocks (`nano ~/vt-l4/vars.sh`) are replaced by
# `lan-rehearsal.sh fill-vars`; the svc shell gets SSH_ASKPASS so ssh-copy-id (2.4) gets the
# laptop password without a terminal. mode=reboot reboots the VM for real, waits for a new
# boot id, then re-creates the laptop netns (topo-up). mode=measure records timer-health
# first (throughput is judged only when it says OK; testbed/README §10).
# A block FAILs when its log has a "FAIL " line (the runbook's own vt_ck checks) or a shell
# error (syntax error, command not found, unbound variable, event not found).
# A full run (no FROM/UNTIL) starts with pre-clean + topo-down (fresh server: no clone, no
# ~/.cargo) and ends with the runbook's own uninstall, then fetches the service node's
# ~/vt-l4, runs topo-down and the residue check, and powers the VM off (sync + ACPI).
# Results: _workspace/lanrh-<release>-<ts>/ (summary.txt, NN_<id>.log, blocks/, svc-vt-l4/,
# timer-health-*.txt, topo-*.log, residue.txt, commit.txt).

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
REL=${VT_RELEASE:-jammy}
case "${REL}" in
    noble) DEF_VM=vantage-svc;       DEF_PORT=2522 ;;
    jammy) DEF_VM=vantage-svc-jammy; DEF_PORT=2523 ;;
    *) echo "VT_RELEASE must be noble or jammy (got '${REL}')"; exit 1 ;;
esac
# shellcheck source=vbox/vm-lib.sh
. testbed/vbox/vm-lib.sh
vm_config "${VM:-${DEF_VM}}" "${REL}" "${VT_SSH_PORT:-${DEF_PORT}}" || exit 1
vm_exists || { echo "[-] VM ${VM} does not exist; create it with: VT_RELEASE=${REL} ./testbed/l2-vbox.sh"; exit 1; }

COMMIT=${VT_LAN_COMMIT:-$(git rev-parse --short HEAD)}
FROM=${FROM:-}; UNTIL=${UNTIL:-}
FULL=0; [[ -z "${FROM}" && -z "${UNTIL}" ]] && FULL=1
TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/lanrh-${REL}-${TS}
mkdir -p "${OUT}"
python3 testbed/vbox/runbook_blocks.py docs/install-runbook-lan.md "${OUT}/blocks" || exit 1
{ git describe --always --dirty; echo "runbook commit under test (COMMIT in vars.sh): ${COMMIT}";
  echo "release=${REL} vm=${VM} from=${FROM:-start} until=${UNTIL:-end}"; } > "${OUT}/commit.txt"
SUM=${OUT}/summary.txt

vm_start || exit 1
wait_ready
rsync -a --delete -e "ssh ${SSH_OPTS[*]}" --exclude target --exclude '_workspace*' --exclude .git \
    "${ROOT}/" ubuntu@127.0.0.1:work/ || exit 1
VMH=/home/ubuntu/work/testbed/vbox/lan-rehearsal.sh
vm_timer_health > "${OUT}/timer-health-start.txt" 2>&1
echo "timer-health start: $(tail -1 "${OUT}/timer-health-start.txt")" | tee -a "${SUM}"

if [[ ${FULL} -eq 1 ]]; then
    vssh "sudo bash ${VMH} pre-clean; sudo bash ${VMH} topo-down" > "${OUT}/topo-reset.log" 2>&1
fi
vssh "sudo bash ${VMH} topo-up" > "${OUT}/topo-up.log" 2>&1
grep -E '^\[[-+]\]' "${OUT}/topo-up.log"
grep -q '^\[+\] topology up' "${OUT}/topo-up.log" || { echo "[-] topology failed (environment)"; exit 1; }

run_block() {   # run_block <host> <file> <log>
    local host=$1 f=$2 log=$3
    case "${host}" in
        svc) vssh "SSH_ASKPASS=/var/lib/vt-lan-rehearsal/askpass SSH_ASKPASS_REQUIRE=force bash -i" < "${f}" > "${log}" 2>&1 ;;
        a|b) vssh "sudo bash ${VMH} run ${host}" < "${f}" > "${log}" 2>&1 ;;
    esac
}

started=0; [[ -z "${FROM}" ]] && started=1
fails=0; reached_end=1
# The loop reads the index on fd 3; every command inside gets stdin from /dev/null or a block
# file (ssh would otherwise swallow the index).
while IFS=$'\t' read -r n id host mode fn <&3; do
    if [[ ${started} -eq 0 ]]; then [[ "${id}" == "${FROM}" ]] && started=1 || continue; fi
    log=${OUT}/${fn%.sh}.log
    t0=$(date +%s)
    case "${mode}" in
        edit)
            vssh "sudo bash ${VMH} fill-vars ${host} ${COMMIT}" > "${log}" 2>&1 ;;
        reboot)
            boot1=$(vssh 'cat /proc/sys/kernel/random/boot_id')
            run_block "${host}" "${OUT}/blocks/${fn}" "${log}"
            for _ in $(seq 1 60); do vssh true 2>/dev/null || break; sleep 2; done
            wait_ready >> "${log}" 2>&1
            boot2=$(vssh 'cat /proc/sys/kernel/random/boot_id')
            echo "boot id ${boot1} -> ${boot2}" >> "${log}"
            [[ -n "${boot2}" && "${boot1}" != "${boot2}" ]] || echo "FAIL reboot did not happen" >> "${log}"
            vssh "sudo bash ${VMH} topo-up" > "${OUT}/topo-up-after-reboot.log" 2>&1
            grep -q '^\[+\] topology up' "${OUT}/topo-up-after-reboot.log" \
                || echo "FAIL (environment) laptop netns not re-created after reboot" >> "${log}" ;;
        measure)
            vm_timer_health > "${OUT}/timer-health-${id}.txt" 2>&1
            echo "timer-health before ${id}: $(tail -1 "${OUT}/timer-health-${id}.txt")" | tee -a "${SUM}"
            run_block "${host}" "${OUT}/blocks/${fn}" "${log}" ;;
        *)
            run_block "${host}" "${OUT}/blocks/${fn}" "${log}" ;;
    esac < /dev/null
    dt=$(( $(date +%s) - t0 ))
    nok=$(grep -c '^OK ' "${log}"); nfail=$(grep -c '^FAIL ' "${log}")
    nerr=$(grep -cE 'syntax error|command not found|unbound variable|event not found' "${log}")
    if [[ ${nfail} -eq 0 && ${nerr} -eq 0 ]]; then v=PASS; else v=FAIL; fails=$((fails + 1)); fi
    printf 'BLOCK %-3s %-9s %-4s %-8s %s  ok=%s fail=%s shell-errors=%s  %ss\n' \
        "${n}" "${id}" "${host}" "${mode}" "${v}" "${nok}" "${nfail}" "${nerr}" "${dt}" | tee -a "${SUM}"
    [[ ${v} == FAIL ]] && grep -E '^FAIL |syntax error|command not found|unbound variable|event not found' "${log}" | sed 's/^/    /' | tee -a "${SUM}"
    if [[ -n "${UNTIL}" && "${id}" == "${UNTIL}" ]]; then reached_end=0; break; fi
done 3< "${OUT}/blocks/index.tsv"
[[ ${started} -eq 0 ]] && { echo "[-] FROM=${FROM}: no such block id" | tee -a "${SUM}"; exit 1; }

vm_timer_health > "${OUT}/timer-health-end.txt" 2>&1
echo "timer-health end: $(tail -1 "${OUT}/timer-health-end.txt")" | tee -a "${SUM}"
if [[ ${reached_end} -eq 1 ]]; then
    rsync -a -e "ssh ${SSH_OPTS[*]}" ubuntu@127.0.0.1:vt-l4/ "${OUT}/svc-vt-l4/" 2>/dev/null
    vssh "sudo bash ${VMH} topo-down" > "${OUT}/topo-down.log" 2>&1
    vssh "sudo bash ${VMH} residue; sync" > "${OUT}/residue.txt" 2>&1
    cat "${OUT}/residue.txt" | tee -a "${SUM}"
    grep -q 'RESIDUE-RESULT clean' "${OUT}/residue.txt" || fails=$((fails + 1))
    [[ "${KEEP_VM:-0}" == 1 ]] || { vm_poweroff; echo "VM ${VM} powered off (sync + ACPI)" | tee -a "${SUM}"; }
fi
echo "RESULT blocks-failed+residue=${fails}" | tee -a "${SUM}"
echo "LAN rehearsal results: ${OUT}"
[[ ${fails} -eq 0 ]]
