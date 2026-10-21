#!/usr/bin/env bash
# runbook-rehearsal.sh -- paste rehearsal of docs/install-runbook.md, unchanged blocks, two setups.
#
#   VT_REH=lan ./testbed/runbook-rehearsal.sh     # (가) no core: L2 VM (VT_RELEASE=jammy default)
#   VT_REH=l3  ./testbed/runbook-rehearsal.sh     # (나) 5G core: vantage-core + vantage-svc (L3)
#   FROM=<id> / UNTIL=<id>                        # resume at / stop after a block id (no setup
#                                                 # reset, no teardown unless the end is reached)
#   KEEP_VM=1                                     # do not power the VM(s) off at the end
#
# Every ```bash block of the runbook with a <!-- rh: id=… host=… --> comment is extracted
# verbatim (testbed/vbox/runbook_blocks.py) and fed as stdin to an interactive `bash -i` (a new
# shell per block): the conditions of pasting into a terminal without bracketed paste.
# The two setups differ only in the variable values filled in for the runbook's edit steps.
#
#   host   lan (one VM, testbed/vbox/rehearsal-vm.sh lan-up)     l3 (vantage-core + vantage-svc)
#   svc    ssh ubuntu@L2-VM 'bash -i'                            ssh ubuntu@vantage-svc 'bash -i'
#   a, b   netns nb-a / nb-b, users lapa / lapb                  vantage-core netns ran, user ueuser
#   upf    (no UPF host: UE_GW empty, appendix A not run)        ssh ubuntu@vantage-core 'bash -i'
#
# mode=edit: `nano` is not run; `rehearsal-vm.sh fill` writes the values (the runbook's only
# manual edit). mode=manual: not run (appendix B needs an older version's pins). mode=reboot:
# reboots the service VM for real, waits for a new boot id, re-creates the wrapper state
# (lan: client netns; l3: management route). mode=measure: timer-health of the VM(s) first.
# l3 order: document order, except that at block 2.4 the wrapper first runs 2.4 as a negative
# control against the quickstart MASQUERADE (must FAIL), then all [UPF 호스트] blocks
# (appendix A), then 2.4 for real. Before client/measure blocks the RAN is checked and, if a
# UE was lost, re-established once (logged as a wrapper intervention).
# A block FAILs when its log has a "FAIL " line (the runbook's vt_ck checks) or a shell error.
# Full run (no FROM/UNTIL): starts from a fresh service node (pre-clean + home-reset: no clone,
# no ~/.cargo) and, for l3, the core in the quickstart NAT state; ends with the runbook's own
# uninstall, fetches the service node's ~/vt-l4, tears the wrapper state down, runs the
# residue check and powers the VM(s) off (sync + ACPI).
# Results: _workspace/rh-<lan-release|l3>-<ts>/ (summary.txt, NN_<id>.log, blocks/, svc-vt-l4/,
# timer-health-*.txt, setup-*.log, residue*.txt, commit.txt, vars-*.txt).

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. testbed/vbox/vm-lib.sh
REH=${VT_REH:-lan}
REL=${VT_RELEASE:-jammy}
case "${REH}" in
    lan) case "${REL}" in
             noble) SVC_VM=vantage-svc;       SVC_PORT=2522; SVC_REL=noble ;;
             jammy) SVC_VM=vantage-svc-jammy; SVC_PORT=2523; SVC_REL=jammy ;;
             *) echo "VT_RELEASE must be noble or jammy"; exit 1 ;;
         esac; TAG=lan-${REL} ;;
    l3)  SVC_VM=vantage-svc; SVC_PORT=2522; SVC_REL=noble; TAG=l3 ;;
    *) echo "VT_REH must be lan or l3"; exit 1 ;;
esac
svcvm()  { vm_config "${SVC_VM}" "${SVC_REL}" "${SVC_PORT}"; }
corevm() { vm_config vantage-core jammy 2524 4 6144 20480 testbed/vbox/core-user-data.tmpl; }
sv() { svcvm; vssh "$@"; }
cv() { corevm; vssh "$@"; }
VMH=/home/ubuntu/work/testbed/vbox/rehearsal-vm.sh

COMMIT=${VT_LAN_COMMIT:-$(git rev-parse --short HEAD)}
FROM=${FROM:-}; UNTIL=${UNTIL:-}
FULL=0; [[ -z "${FROM}" ]] && FULL=1      # start from a fresh state unless resuming
TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/rh-${TAG}-${TS}
mkdir -p "${OUT}"
SUM=${OUT}/summary.txt
python3 testbed/vbox/runbook_blocks.py docs/install-runbook.md "${OUT}/blocks" || exit 1
{ git describe --always --dirty; echo "COMMIT installed by the runbook (vars.sh): ${COMMIT}"
  echo "setup=${REH} svc-vm=${SVC_VM} from=${FROM:-start} until=${UNTIL:-end}"; } > "${OUT}/commit.txt"

th() {   # th <tag>: timer-health of the VM(s)
    local f=${OUT}/timer-health-$1.txt
    { echo "## ${SVC_VM}"; svcvm; vm_timer_health; if [[ ${REH} == l3 ]]; then echo "## vantage-core"; corevm; vm_timer_health; fi; } > "${f}" 2>&1
    echo "timer-health $1: $(grep '^timer-health' "${f}" | cut -d' ' -f2-8 | paste -sd'|' -)" | tee -a "${SUM}"
}
sync_tree() { rsync -a --delete -e "ssh ${SSH_OPTS[*]}" --exclude target --exclude '_workspace*' --exclude .git "${ROOT}/" ubuntu@127.0.0.1:work/; }

# ---- bring the VM(s) up and the wrapper state in place ----
svcvm; vm_exists || { echo "[-] ${SVC_VM} missing"; exit 1; }
if [[ ${REH} == l3 ]]; then
    corevm; vm_exists || { echo "[-] vantage-core missing: ./testbed/l3-vbox.sh up"; exit 1; }
    vm_start || exit 1; wait_ready > /dev/null; sync_tree || exit 1
fi
svcvm; vm_start || exit 1; wait_ready > /dev/null; sync_tree || exit 1

if [[ ${REH} == lan ]]; then
    IFN=vtlan0
    [[ ${FULL} -eq 1 ]] && sv "sudo bash ${VMH} pre-clean vtlan0; sudo bash ${VMH} lan-down" > "${OUT}/setup-reset.log" 2>&1
    sv "sudo bash ${VMH} lan-up" > "${OUT}/setup-up.log" 2>&1
    grep -q '^\[+\] topology up' "${OUT}/setup-up.log" || { cat "${OUT}/setup-up.log"; echo "[-] topology failed (environment)"; exit 1; }
    SVC_A=192.168.77.10; UEA=192.168.77.21; UEB=192.168.77.22
    VARS_SVC=(SVC=${SVC_A} UE_A=${UEA} UE_B=${UEB} IF=${IFN} CLIENT_A_HOST=${UEA} CLIENT_A_USER=lapa
              CLIENT_B_HOST=${UEB} CLIENT_B_USER=lapb COMMIT=${COMMIT})
    VARS_CLI=(SVC=${SVC_A} UE_A=${UEA} UE_B=${UEB})
    VARS_UPF=()
else
    IFN=$(sv "ip -o link | awk -F': ' '/08:00:27:a0:6e:02/ {print \$2}'" | tr -d '\r')
    [[ -n "${IFN}" ]] || { echo "[-] vantage-svc has no N6 NIC (./testbed/l3-vbox.sh up)"; exit 1; }
    if [[ ${FULL} -eq 1 ]]; then
        sv "sudo bash ${VMH} pre-clean ${IFN}; sudo bash ${VMH} home-reset; sudo bash ${VMH} svc-mgmt-down" > "${OUT}/setup-reset.log" 2>&1
        cv "sudo pkill -x iperf3; sudo bash ${VMH} l3-client-down; sudo bash ${VMH} core-reset" >> "${OUT}/setup-reset.log" 2>&1
    fi
    { cv "sudo bash ${VMH} l3-client-up"; sv "sudo bash ${VMH} askpass; sudo bash ${VMH} svc-mgmt-up"
      sv "ping -c1 -W2 10.100.0.2" && echo "[+] svc -> 10.100.0.2 (client mgmt) ok"; } > "${OUT}/setup-up.log" 2>&1
    grep -q '^\[+\] l3 client host' "${OUT}/setup-up.log" && grep -q 'svc -> 10.100.0.2' "${OUT}/setup-up.log" \
        || { cat "${OUT}/setup-up.log"; echo "[-] l3 wrapper setup failed (environment)"; exit 1; }
    read -r _ UEA <<<"$(cv "sudo bash /home/ubuntu/core-ran.sh ues" | sed -n 1p)"
    read -r _ UEB <<<"$(cv "sudo bash /home/ubuntu/core-ran.sh ues" | sed -n 2p)"
    [[ -n "${UEA}" && -n "${UEB}" ]] || { echo "[-] could not read the UE addresses (core-ran.sh ues)"; exit 1; }
    SVC_A=10.200.0.2
    VARS_SVC=(SVC=${SVC_A} UE_A=${UEA} UE_B=${UEB} UE_NET=10.45.0.0/16 UE_GW=10.200.0.1 IF=${IFN}
              CLIENT_A_HOST=10.100.0.2 CLIENT_A_USER=ueuser CLIENT_B_HOST=10.100.0.2 CLIENT_B_USER=ueuser
              COMMIT=${COMMIT} A_RX=4 A_TX=6 B_RX=2 B_TX=3)
    VARS_CLI=(SVC=${SVC_A} UE_A=${UEA} UE_B=${UEB} UE_NET=10.45.0.0/16 UE_GW=10.200.0.1)
    VARS_UPF=(SVC=${SVC_A} UE_NET=10.45.0.0/16)
fi
cat "${OUT}/setup-up.log" | grep -E '^\[[-+!i]\]'
printf '%s\n' "svc: ${VARS_SVC[*]}" "client: ${VARS_CLI[*]}" "upf: ${VARS_UPF[*]:-(none)}" | tee "${OUT}/vars-filled.txt"
th start

run_block() {   # run_block <host> <file> <log>
    local host=$1 f=$2 log=$3
    case "${REH}:${host}" in
        *:svc)  sv "SSH_ASKPASS=/var/lib/vt-lan-rehearsal/askpass SSH_ASKPASS_REQUIRE=force bash -i" < "${f}" > "${log}" 2>&1 ;;
        lan:a)  sv "sudo bash ${VMH} run nb-a lapa" < "${f}" > "${log}" 2>&1 ;;
        lan:b)  sv "sudo bash ${VMH} run nb-b lapb" < "${f}" > "${log}" 2>&1 ;;
        l3:a|l3:b) cv "sudo bash ${VMH} run ran ueuser" < "${f}" > "${log}" 2>&1 ;;
        l3:upf) cv "bash -i" < "${f}" > "${log}" 2>&1 ;;
    esac
}
fill_vars() {   # fill_vars <host> <log>
    case "${REH}:$1" in
        *:svc) sv "sudo bash ${VMH} fill /home/ubuntu/vt-l4/vars.sh ${VARS_SVC[*]}" ;;
        lan:a) sv "sudo bash ${VMH} fill /home/lapa/vt-l4/vars.sh ${VARS_CLI[*]}" ;;
        lan:b) sv "sudo bash ${VMH} fill /home/lapb/vt-l4/vars.sh ${VARS_CLI[*]}" ;;
        l3:a|l3:b) cv "sudo bash ${VMH} fill /home/ueuser/vt-l4/vars.sh ${VARS_CLI[*]}" ;;
        l3:upf) cv "sudo bash ${VMH} fill /home/ubuntu/vt-l4/vars.sh ${VARS_UPF[*]}" ;;
    esac > "$2" 2>&1
}
ran_check() { [[ ${REH} == l3 ]] || return 0; cv "sudo bash ${VMH} ran-check" 2>&1 | tee -a "${OUT}/ran-check.log" | grep -E '^\[!\]|^\[-\]|re-established' | sed 's/^/    WRAPPER /' | tee -a "${SUM}"; }

fails=0
# exec_block <n> <id> <host> <mode> <fn> [negctl]
exec_block() {
    local n=$1 id=$2 host=$3 mode=$4 fn=$5 neg=${6:-}
    local log=${OUT}/${fn%.sh}${neg:+-negctl}.log t0 v
    t0=$(date +%s)
    case "${mode}" in
        manual) echo "[skipped: mode=manual, appendix B needs an older version's pins]" > "${log}" ;;
        edit)   fill_vars "${host}" "${log}" ;;
        reboot)
            local b1 b2
            b1=$(sv 'cat /proc/sys/kernel/random/boot_id')
            run_block "${host}" "${OUT}/blocks/${fn}" "${log}"
            svcvm; for _ in $(seq 1 60); do vssh true 2>/dev/null || break; sleep 2; done
            wait_ready >> "${log}" 2>&1
            b2=$(sv 'cat /proc/sys/kernel/random/boot_id')
            echo "boot id ${b1} -> ${b2}" >> "${log}"
            [[ -n "${b2}" && "${b1}" != "${b2}" ]] || echo "FAIL reboot did not happen" >> "${log}"
            if [[ ${REH} == lan ]]; then sv "sudo bash ${VMH} lan-up" > "${OUT}/setup-after-reboot.log" 2>&1
            else sv "sudo bash ${VMH} askpass; sudo bash ${VMH} svc-mgmt-up" > "${OUT}/setup-after-reboot.log" 2>&1; fi
            echo "    WRAPPER after reboot: $( [[ ${REH} == lan ]] && echo 'client netns re-created' || echo 'mgmt route 10.100.0.0/24 re-added')" | tee -a "${SUM}" ;;
        measure) ran_check; th "${id}"; run_block "${host}" "${OUT}/blocks/${fn}" "${log}" ;;
        *)      [[ ${host} == a || ${host} == b ]] && ran_check
                run_block "${host}" "${OUT}/blocks/${fn}" "${log}" ;;
    esac < /dev/null
    local nok nfail nerr dt=$(( $(date +%s) - t0 ))
    # vt_ck lines may follow the interactive prompt on the same line (stderr/stdout interleave).
    nok=$(grep -cE '(^|[$#] )OK   ' "${log}"); nfail=$(grep -cE '(^|[$#] )FAIL ' "${log}")
    nerr=$(grep -cE 'syntax error|command not found|unbound variable|event not found' "${log}")
    if [[ ${mode} == manual ]]; then v=SKIP
    elif [[ -n ${neg} ]]; then [[ ${nfail} -gt 0 && ${nerr} -eq 0 ]] && v=NEGCTL-PASS || { v=NEGCTL-FAIL; fails=$((fails + 1)); }
    elif [[ ${nfail} -eq 0 && ${nerr} -eq 0 ]]; then v=PASS
    else v=FAIL; fails=$((fails + 1)); fi
    printf 'BLOCK %-3s %-9s %-4s %-8s %-11s ok=%s fail=%s shell-errors=%s  %ss\n' \
        "${n}" "${id}" "${host}" "${mode}" "${v}" "${nok}" "${nfail}" "${nerr}" "${dt}" | tee -a "${SUM}"
    [[ ${v} == FAIL || ${v} == NEGCTL-* ]] && grep -E '(^|[$#] )FAIL |syntax error|command not found|unbound variable|event not found' "${log}" | sed 's/^/    /' | tee -a "${SUM}"
}

started=0; [[ -z "${FROM}" ]] && started=1
reached_end=1; upf_done=0
while IFS=$'\t' read -r n id host mode fn <&3; do
    if [[ ${started} -eq 0 ]]; then [[ "${id}" == "${FROM}" ]] && started=1 || continue; fi
    if [[ ${host} == upf ]]; then
        [[ ${REH} == lan ]] && printf 'BLOCK %-3s %-9s %-4s %-8s %-11s (no UPF host: UE_GW empty)\n' "${n}" "${id}" upf "${mode}" NOT-APPL | tee -a "${SUM}"
        continue    # l3: run at 2.4 (below)
    fi
    if [[ ${REH} == l3 && ${id} == 2.4 && ${upf_done} -eq 0 ]]; then
        echo "--- l3: 2.4 negative control (quickstart MASQUERADE in place), then appendix A on the UPF host" | tee -a "${SUM}"
        exec_block "${n}" "${id}" "${host}" "${mode}" "${fn}" negctl
        while IFS=$'\t' read -r n2 id2 host2 mode2 fn2 <&4; do
            [[ ${host2} == upf ]] && exec_block "${n2}" "${id2}" "${host2}" "${mode2}" "${fn2}"
        done 4< "${OUT}/blocks/index.tsv"
        upf_done=1
        echo "--- l3: body continues" | tee -a "${SUM}"
    fi
    exec_block "${n}" "${id}" "${host}" "${mode}" "${fn}"
    if [[ -n "${UNTIL}" && "${id}" == "${UNTIL}" ]]; then reached_end=0; break; fi
done 3< "${OUT}/blocks/index.tsv"
[[ ${started} -eq 0 ]] && { echo "[-] FROM=${FROM}: no such block id" | tee -a "${SUM}"; exit 1; }

th end
if [[ ${reached_end} -eq 1 ]]; then
    svcvm; rsync -a -e "ssh ${SSH_OPTS[*]}" ubuntu@127.0.0.1:vt-l4/ "${OUT}/svc-vt-l4/" 2>/dev/null
    if [[ ${REH} == lan ]]; then
        sv "sudo bash ${VMH} lan-down" > "${OUT}/teardown.log" 2>&1
        sv "sudo bash ${VMH} residue vtlan0; sync" > "${OUT}/residue.txt" 2>&1
    else
        corevm; rsync -a -e "ssh ${SSH_OPTS[*]}" ubuntu@127.0.0.1:vt-l4/ "${OUT}/upf-vt-l4/" 2>/dev/null
        { sv "sudo bash ${VMH} svc-mgmt-down; sudo bash ${VMH} home-reset"
          cv "sudo pkill -x iperf3; sudo bash ${VMH} l3-client-down; sudo bash ${VMH} core-reset"; } > "${OUT}/teardown.log" 2>&1
        { echo "## ${SVC_VM}"; sv "sudo bash ${VMH} residue ${IFN}; sync"
          echo "## vantage-core (rehearsal state only; Open5GS/RAN are the testbed's)"
          cv "sudo iptables -t nat -S POSTROUTING; ls /etc/iptables /etc/sysctl.d/90-ue-forward.conf 2>&1; id ueuser 2>&1; sudo ip -n ran route show default; sync"; } > "${OUT}/residue.txt" 2>&1
    fi
    cat "${OUT}/residue.txt" | tee -a "${SUM}"
    grep -q 'RESIDUE-RESULT clean' "${OUT}/residue.txt" || fails=$((fails + 1))
    if [[ "${KEEP_VM:-0}" != 1 ]]; then
        if [[ ${REH} == l3 ]]; then cv "sudo bash /home/ubuntu/core-ran.sh down" > /dev/null 2>&1; corevm; vm_poweroff; fi
        svcvm; vm_poweroff
        echo "VMs powered off (sync + ACPI); running: $(VBoxManage list runningvms | wc -l | tr -d ' ')" | tee -a "${SUM}"
    fi
fi
echo "RESULT failed=${fails}" | tee -a "${SUM}"
echo "rehearsal results: ${OUT}"
[[ ${fails} -eq 0 ]]
