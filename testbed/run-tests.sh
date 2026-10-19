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

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=${OUT:-${ROOT}/_workspace/test-$(date +%Y%m%d_%H%M%S)}
T=${T:-15}
CLI=${ROOT}/target/release/vantage-5G
IF=vt-n6
SVC=10.99.0.1
VERDICT=${ROOT}/.claude/skills/vantage-testbed/scripts/iperf_verdict.py
mkdir -p "${OUT}"
SUMMARY=${OUT}/summary.txt
: > "${SUMMARY}"

rec() { printf '[%-4s] %-28s %s\n' "$1" "$2" "${3:-}" | tee -a "${SUMMARY}"; }
run() { local name=$1; shift; if "$@" >"${OUT}/${name}.log" 2>&1; then rec PASS "${name}"; return 0; else rec FAIL "${name}" "see ${name}.log"; return 1; fi; }

cleanup() {
    "${ROOT}/detach.sh" "${IF}" >/dev/null 2>&1 || true
    ip link set dev "${IF}" xdpgeneric off 2>/dev/null || true
    "${CLI}" unload >/dev/null 2>&1 || true
    pkill -x iperf3 2>/dev/null || true
    "${ROOT}/testbed/netns-topo.sh" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

{ uname -r; git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo "no-git"; } > "${OUT}/env.txt"
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf

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
    bpftool prog loadall vantage_rx_policer.o "${d}/rx" type xdp &&
    bpftool prog loadall vantage_tx_pacer.o  "${d}/tx" type tc; local rc=$?
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
run topology "${ROOT}/testbed/netns-topo.sh" up || exit 1
if [[ ${HAS_FQ} == 1 ]]; then
    run setup.sh "${ROOT}/setup.sh" "${IF}" || exit 1
    run setup.sh-rerun "${ROOT}/setup.sh" "${IF}"
    if ! run attached-after-rerun sh -c "ip link show dev ${IF} | grep -q xdp && tc filter show dev ${IF} egress | grep -q vantage_tx_pacer"; then
        # The rerun failure is recorded above. Restore a clean attachment so the
        # pacing/killswitch steps below measure the datapath, not the rerun damage.
        run setup.sh-reattach sh -c "'${ROOT}/detach.sh' '${IF}' && '${ROOT}/setup.sh' '${IF}' && tc filter show dev '${IF}' egress | grep -q vantage_tx_pacer" || exit 1
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
    "${CLI}" set --ue-ip 10.45.1.24 --rx-mbps 3 --tx-mbps 5
}
run killswitch killswitch

# ---- 7. reset ----
run reset sh -c "'${CLI}' reset --ue-ip 10.45.1.24 && ! '${CLI}' list | grep -q 10.45.1.24"

# ---- 8. detach + unload ----
detach_clean() {
    "${ROOT}/detach.sh" "${IF}" || return 1
    if ip link show dev "${IF}" | grep -q xdp; then echo "XDP still attached after detach.sh"; ip link show dev "${IF}"; return 1; fi
    if tc filter show dev "${IF}" egress | grep -q bpf; then echo "tc filter still attached"; return 1; fi
}
run detach detach_clean
unload_clean() {
    "${CLI}" unload || return 1
    local left; left=$(ls /sys/fs/bpf | grep -E 'ue_|rx_state|tx_tstamp|vantage' || true)
    [[ -z "${left}" ]] || { echo "pins left in /sys/fs/bpf: ${left}"; return 1; }
}
run unload unload_clean

echo
echo "results: ${OUT}"
! grep -q '^\[FAIL' "${SUMMARY}"
