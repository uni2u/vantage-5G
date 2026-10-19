#!/usr/bin/env bash
# run-tests.sh — Vantage-5G functional test on an emulated N6 (netns-topo.sh).
#
# Runs as root on any Linux: inside the L1 Docker container (testbed/l1-docker.sh)
# or directly on the L2 Ubuntu VM. Must be run from the repo root.
#
# Exercises the real operator path: make build -> vantage-5G load -> setup.sh
# -> set -> iperf3 -> killswitch -> detach.sh -> unload.
# When the kernel has no sch_fq (Docker Desktop), setup.sh cannot run, so the
# script attaches the same pinned programs without fq and SKIPs TX pacing.
#
# Env: OUT=<dir for results> (default ./_workspace/test-<ts>), T=<iperf secs> (default 15)
#      VT_SETUP_AS=<user>   run setup.sh/detach.sh as this NOPASSWD-sudo user
#                           (operator path "./setup.sh" without sudo; D21)
#      VT_NONROOT_USER=<u>  user for the fixed non-root setup.sh/detach.sh step
#                           (default ubuntu; SKIP if absent or no NOPASSWD sudo)
#      VT_NO_BPFTOOL=1      hide bpftool from setup.sh (Ubuntu 22.04 without
#                           linux-tools-$(uname -r)) => exercises its probe path.
#                           The test itself keeps using the real binary.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=${OUT:-${ROOT}/_workspace/test-$(date +%Y%m%d_%H%M%S)}
T=${T:-15}
CLI=${ROOT}/target/release/vantage-5G
IF=vt-n6
SVC=10.99.0.1
VERDICT=${ROOT}/.claude/skills/vantage-testbed/scripts/iperf_verdict.py
SETUP_AS=${VT_SETUP_AS:-}
NONROOT_USER=${VT_NONROOT_USER:-ubuntu}
# Real bpftool binary for the test's own checks (/usr/local/lib/vantage-testbed/bpftool:
# a private copy kept when linux-tools-$(uname -r) is removed to mimic a bare 22.04) (Ubuntu's /usr/sbin/bpftool is a
# wrapper that needs linux-tools-$(uname -r); prefer the matching real binary).
BPFTOOL=""
for b in "/usr/lib/linux-tools/$(uname -r)/bpftool" /usr/local/lib/vantage-testbed/bpftool /usr/lib/linux-tools/*/bpftool /usr/lib/linux-tools-*/bpftool "$(command -v bpftool)"; do
    [[ -n "${b}" && -x "${b}" ]] && "${b}" version >/dev/null 2>&1 && { BPFTOOL=${b}; break; }
done
HIDDEN_BPFTOOL=()
mkdir -p "${OUT}"
SUMMARY=${OUT}/summary.txt
: > "${SUMMARY}"

# setup.sh/detach.sh as the operator would run them (root, or VT_SETUP_AS user).
op() { if [[ -n "${SETUP_AS}" ]]; then sudo -n -u "${SETUP_AS}" -H -- "$@"; else "$@"; fi; }
as_user() { local u=$1; shift; sudo -n -u "${u}" -H -- "$@"; }
hide_bpftool() {
    local f
    for f in /usr/sbin/bpftool /usr/local/sbin/bpftool /usr/bin/bpftool /usr/local/bin/bpftool; do
        [[ -e "${f}" || -L "${f}" ]] || continue
        mv "${f}" "${f}.vt-hidden" && HIDDEN_BPFTOOL+=("${f}")
    done
    ! command -v bpftool >/dev/null 2>&1 && ! sudo -n sh -c 'command -v bpftool' >/dev/null 2>&1
}
restore_bpftool() {
    local f
    for f in ${HIDDEN_BPFTOOL[@]+"${HIDDEN_BPFTOOL[@]}"}; do mv "${f}.vt-hidden" "${f}" 2>/dev/null || true; done
    HIDDEN_BPFTOOL=()
}
rec() { printf '[%-4s] %-28s %s\n' "$1" "$2" "${3:-}" | tee -a "${SUMMARY}"; }
run() { local name=$1; shift; if "$@" >"${OUT}/${name}.log" 2>&1; then rec PASS "${name}"; return 0; else rec FAIL "${name}" "see ${name}.log"; return 1; fi; }

cleanup() {
    op "${ROOT}/detach.sh" "${IF}" >/dev/null 2>&1 || true
    ip link set dev "${IF}" xdpgeneric off 2>/dev/null || true
    "${CLI}" unload >/dev/null 2>&1 || true
    pkill -x iperf3 2>/dev/null || true
    "${ROOT}/testbed/netns-topo.sh" down >/dev/null 2>&1 || true
    restore_bpftool
}
trap cleanup EXIT

{ uname -r; git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo "no-git"
  . /etc/os-release 2>/dev/null && echo "os=${PRETTY_NAME:-?}"
  echo "iproute2=$(ip -V 2>&1)"; echo "bpftool=${BPFTOOL:-none}"
  echo "setup_as=${SETUP_AS:-root} no_bpftool=${VT_NO_BPFTOOL:-0}"; } > "${OUT}/env.txt"
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf

# Expected attach state after setup.sh (see setup.sh step 5): generic XDP running
# the pinned policer, root fq, clsact, exactly one Vantage egress filter at
# pref 1 handle 0x1 direct-action running the pinned pacer.
pin_id() { "${BPFTOOL:-bpftool}" prog show pinned "$1" 2>/dev/null | sed -n '1s/^\([0-9]*\):.*/\1/p'; }
attach_snapshot() {
    ip -d link show dev "${IF}"; tc qdisc show dev "${IF}"; tc filter show dev "${IF}" egress
}
attached_ok() {
    local err=0 xid tid link filt ours n
    xid=$(pin_id /sys/fs/bpf/vantage/vantage_rx_policer); tid=$(pin_id /sys/fs/bpf/vantage/vantage_tx_pacer)
    link=$(ip -d link show dev "${IF}"); filt=$(tc filter show dev "${IF}" egress)
    echo "${link}" | head -1 | grep -q ' xdpgeneric' || { echo "XDP not in generic mode"; err=1; }
    # id-based: iproute2 5.15 (Ubuntu 22.04) prints no prog names.
    echo "${link}" | grep -qE "prog/xdp id ${xid:-X}( |\$)" || { echo "XDP prog != pinned policer id ${xid}"; err=1; }
    tc qdisc show dev "${IF}" | grep -q '^qdisc fq [0-9a-f]*: root' || { echo "root qdisc is not fq"; err=1; }
    tc qdisc show dev "${IF}" | grep -q '^qdisc clsact ' || { echo "clsact missing"; err=1; }
    ours=$(echo "${filt}" | grep -E "( id ${tid:-X}( |\$)|name vantage_tx_pace |vantage_tx_pacer:\[)" || true)
    n=$(echo -n "${ours}" | grep -c . || true)
    [[ "${n}" == 1 ]] || { echo "expected exactly 1 Vantage egress filter, found ${n}"; err=1; }
    echo "${ours}" | grep -qE "pref 1 .*handle 0x1 .*direct-action.* id ${tid:-X}( |\$)" \
        || { echo "Vantage filter not pref 1 handle 0x1 da with pinned pacer id ${tid}"; err=1; }
    [[ $(echo "${filt}" | grep -c 'handle') == 1 ]] || { echo "unexpected extra egress filters"; err=1; }
    [[ ${err} == 0 ]] || attach_snapshot
    return ${err}
}

HAS_FQ=0
ip link add vt-fqprobe type dummy 2>/dev/null && \
    tc qdisc add dev vt-fqprobe root fq 2>/dev/null && HAS_FQ=1
ip link del vt-fqprobe 2>/dev/null || true
echo "has_fq=${HAS_FQ}" >> "${OUT}/env.txt"

# ---- 1. build + verifier ----
run build make build || { rec SKIP "rest" "build failed"; exit 1; }
# Map pins left in the bpffs root by an older (pre pin_root_path) build. Recorded,
# never deleted by the test: an operator host would have them too (see unload).
ROOT_MAPS="ue_policy_map ue_stats_map rx_state_map tx_tstamp_map"
PRE_ROOT_PINS=$(cd /sys/fs/bpf && ls -d ${ROOT_MAPS} 2>/dev/null | tr '\n' ' ')
echo "root_pins_before=${PRE_ROOT_PINS}" >> "${OUT}/env.txt"
verifier() {
    # bpffs rejects names containing '.', and bpftool mounts a fresh bpffs on any
    # non-bpffs pin dir (e.g. "/rx" when mktemp fails) -> no dot, hard check.
    local d; d=$(mktemp -d /sys/fs/bpf/vt-verify-XXXXXX) || return 1
    [[ -n "${d}" && "${d}" == /sys/fs/bpf/vt-verify-* ]] || { echo "bad tmp dir '${d}'"; return 1; }
    # bpftool <= 5.15 (Ubuntu 22.04, libbpf 0.5) does not know "type tc"
    # ("failed to guess program type from ELF section 'tc/'"); "classifier" is
    # the same BPF_PROG_TYPE_SCHED_CLS. The product loads via vendored libbpf.
    "${BPFTOOL}" prog loadall vantage_rx_policer.o "${d}/rx" type xdp &&
    { "${BPFTOOL}" prog loadall vantage_tx_pacer.o "${d}/tx" type tc ||
      { echo "retrying with type classifier (old bpftool)"; rm -rf "${d}/tx"
        "${BPFTOOL}" prog loadall vantage_tx_pacer.o "${d}/tx" type classifier; }; }; local rc=$?
    rm -rf "${d}"
    # bpftool pins PIN_BY_NAME maps in the bpffs root; drop only the ones it created.
    local m; for m in ${ROOT_MAPS}; do
        [[ " ${PRE_ROOT_PINS} " == *" ${m} "* ]] || rm -f "/sys/fs/bpf/${m}"
    done
    return ${rc}
}
run verifier verifier

# ---- 2. load (CLI) ----
cleanup >/dev/null 2>&1
pins_ok() { "${CLI}" load && ls /sys/fs/bpf/vantage/{vantage_rx_policer,vantage_tx_pacer,ue_policy_map,ue_stats_map,rx_state_map,tx_tstamp_map}; }
run load pins_ok || { ls -R /sys/fs/bpf >> "${OUT}/load.log" 2>&1; rec SKIP "rest" "load failed"; exit 1; }
run load-idempotent "${CLI}" load

# ---- 3. topology + attach ----
if [[ "${VT_NO_BPFTOOL:-0}" == 1 ]]; then
    # From here on setup.sh/detach.sh see no bpftool (restored in cleanup; hidden only after
    # the pre-load cleanup above, which would restore it).
    run hide-bpftool hide_bpftool || exit 1
fi
run topology "${ROOT}/testbed/netns-topo.sh" up || exit 1
if [[ ${HAS_FQ} == 1 ]]; then
    run setup.sh op "${ROOT}/setup.sh" "${IF}" || exit 1
    if [[ "${VT_NO_BPFTOOL:-0}" == 1 ]]; then
        # Guard against the test silently exercising the bpftool path instead.
        run setup.sh-used-probe grep -q 'source: probe' "${OUT}/setup.sh.log"
    fi
    attach_snapshot > "${OUT}/attach-before-rerun.txt" 2>&1
    run setup.sh-rerun op "${ROOT}/setup.sh" "${IF}"
    attach_snapshot > "${OUT}/attach-after-rerun.txt" 2>&1
    if ! run attached-after-rerun attached_ok; then
        # The rerun failure is recorded above. Restore a clean attachment so the
        # pacing/killswitch steps below measure the datapath, not the rerun damage.
        reattach() { op "${ROOT}/detach.sh" "${IF}" && op "${ROOT}/setup.sh" "${IF}" && attached_ok; }
        run setup.sh-reattach reattach || exit 1
    fi
else
    rec SKIP setup.sh "no sch_fq on this kernel; attaching without fq (TX pacing untestable)"
    manual_attach() {
        tc qdisc replace dev "${IF}" clsact &&
        ip link set dev "${IF}" xdpgeneric pinned /sys/fs/bpf/vantage/vantage_rx_policer &&
        tc filter add dev "${IF}" egress bpf da pinned /sys/fs/bpf/vantage/vantage_tx_pacer
    }
    run attach-manual manual_attach || exit 1
fi

# ---- 4. policies ----
run set-A "${CLI}" set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20
run set-B "${CLI}" set --ue-ip 10.45.1.24 --rx-mbps 3  --tx-mbps 5
"${CLI}" list > "${OUT}/list.txt" 2>&1

# ---- 5. iperf3: all sessions concurrent (README §8) ----
for p in 5201 5202 5203 5204; do iperf3 -s -p ${p} -D; done
sleep 1
SPEC=${OUT}/spec.csv
echo "label,ue_ip,direction,cap_mbps,json_path" > "${SPEC}"
ip netns exec vt-ue-a iperf3 -c ${SVC} -p 5201 -t "${T}" -J > "${OUT}/a_ul.json" &
ip netns exec vt-ue-b iperf3 -c ${SVC} -p 5202 -t "${T}" -J > "${OUT}/b_ul.json" &
echo "A-UL,10.45.1.23,UL,10,a_ul.json" >> "${SPEC}"
echo "B-UL,10.45.1.24,UL,3,b_ul.json"  >> "${SPEC}"
if [[ ${HAS_FQ} == 1 ]]; then
    ip netns exec vt-ue-a iperf3 -c ${SVC} -p 5203 -t "${T}" -R -J > "${OUT}/a_dl.json" &
    ip netns exec vt-ue-b iperf3 -c ${SVC} -p 5204 -t "${T}" -R -J > "${OUT}/b_dl.json" &
    echo "A-DL,10.45.1.23,DL,20,a_dl.json" >> "${SPEC}"
    echo "B-DL,10.45.1.24,DL,5,b_dl.json"  >> "${SPEC}"
else
    rec SKIP dl-pacing "no sch_fq"
fi
if [[ ${HAS_FQ} == 1 ]]; then
    # Operator re-runs setup.sh on a live host: shaping must hold through it
    # (the verdict below covers the whole run, including this moment).
    sleep $(( T / 2 ))
    rerun_live() { op "${ROOT}/setup.sh" "${IF}" && attached_ok; }
    run setup.sh-rerun-under-load rerun_live
fi
wait
"${CLI}" stats > "${OUT}/stats_after_iperf.txt" 2>&1
python3 "${VERDICT}" "${SPEC}" > "${OUT}/verdict.txt" 2>&1 && rec PASS iperf-verdict || rec FAIL iperf-verdict "see verdict.txt"
cat "${OUT}/verdict.txt"

# ---- 6. killswitch (no fq needed: TC_ACT_SHOT) ----
killswitch() {
    "${CLI}" set --ue-ip 10.45.1.24 --rx-mbps 3 --tx-mbps 0 || return 1
    if ip netns exec vt-ue-b ping -c3 -W1 ${SVC} >/dev/null; then echo "ping succeeded under killswitch"; return 1; fi
    "${CLI}" stats --ue-ip 10.45.1.24 | tee /dev/stderr | awk 'NR==2 && $7>0 {ok=1} END {exit !ok}' || { echo "tx_drops did not increase"; return 1; }
    ip netns exec vt-ue-a ping -c2 -W1 ${SVC} >/dev/null || { echo "UE-A affected by UE-B killswitch"; return 1; }
    if [[ ${HAS_FQ} == 1 ]]; then
        # D3: a setup.sh re-run must not lift an active killswitch.
        op "${ROOT}/setup.sh" "${IF}" >/dev/null || { echo "setup.sh re-run under killswitch failed"; return 1; }
        if ip netns exec vt-ue-b ping -c3 -W1 ${SVC} >/dev/null; then echo "ping succeeded under killswitch after setup.sh re-run"; return 1; fi
        echo "killswitch held across setup.sh re-run"
    fi
    "${CLI}" set --ue-ip 10.45.1.24 --rx-mbps 3 --tx-mbps 5
}
run killswitch killswitch

# ---- 7. reset ----
run reset sh -c "'${CLI}' reset --ue-ip 10.45.1.24 && ! '${CLI}' list | grep -q 10.45.1.24"

# ---- 7b. D21: setup.sh/detach.sh as a non-root NOPASSWD-sudo user ----
if [[ ${HAS_FQ} == 1 ]]; then
    if id "${NONROOT_USER}" >/dev/null 2>&1 && as_user "${NONROOT_USER}" sudo -n true 2>/dev/null; then
        nonroot_cycle() {
            echo "--- rerun on live attach as ${NONROOT_USER}"
            as_user "${NONROOT_USER}" "${ROOT}/setup.sh" "${IF}" && attached_ok || return 1
            echo "--- detach as ${NONROOT_USER}"
            as_user "${NONROOT_USER}" "${ROOT}/detach.sh" "${IF}" || return 1
            if ip link show dev "${IF}" | grep -q xdp || tc filter show dev "${IF}" egress | grep -q bpf; then
                echo "hooks left after non-root detach.sh"; attach_snapshot; return 1
            fi
            echo "--- fresh setup as ${NONROOT_USER}"
            as_user "${NONROOT_USER}" "${ROOT}/setup.sh" "${IF}" && attached_ok
        }
        run setup.sh-nonroot nonroot_cycle
    else
        rec SKIP setup.sh-nonroot "user ${NONROOT_USER} missing or no NOPASSWD sudo"
    fi
fi

# ---- 8. detach + unload ----
detach_clean() {
    op "${ROOT}/detach.sh" "${IF}" || return 1
    if ip link show dev "${IF}" | grep -q xdp; then echo "XDP still attached after detach.sh"; ip link show dev "${IF}"; return 1; fi
    if tc filter show dev "${IF}" egress | grep -q bpf; then echo "tc filter still attached"; return 1; fi
}
run detach detach_clean

# ---- 8b. D22: an existing 'ingress' qdisc must be refused (exit 3, no change) ----
if [[ ${HAS_FQ} == 1 ]]; then
    ingress_refused() {
        tc qdisc add dev "${IF}" ingress || return 1
        local before after rc
        before=$(attach_snapshot 2>&1)
        op "${ROOT}/setup.sh" "${IF}"; rc=$?
        after=$(attach_snapshot 2>&1)
        tc qdisc del dev "${IF}" ingress 2>/dev/null
        echo "setup.sh rc=${rc} (expect 3)"
        [[ ${rc} == 3 ]] || return 1
        [[ "${before}" == "${after}" ]] || { echo "state changed:"; diff <(echo "${before}") <(echo "${after}"); return 1; }
    }
    run setup.sh-ingress-refused ingress_refused
fi
unload_clean() {
    "${CLI}" unload || return 1
    local left; left=$(ls /sys/fs/bpf | grep -E 'ue_|rx_state|tx_tstamp|vantage' || true)
    [[ -z "${left}" ]] || { echo "pins left in /sys/fs/bpf: ${left}"; return 1; }
}
run unload unload_clean

echo
echo "results: ${OUT}"
! grep -q '^\[FAIL' "${SUMMARY}"
