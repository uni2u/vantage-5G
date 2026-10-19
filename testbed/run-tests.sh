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
#      VT_NO_BPFTOOL=1      accepted for compatibility; no longer needed. setup.sh
#                           requires bpftool (exit 2, nothing changed, when it is
#                           missing) and the setup.sh-no-bpftool step checks that
#                           on every run. The test itself keeps using the real binary.
#
# Regression steps (3rd round): D4 forwarded-UDP overload -> TCP still connects,
# D6 rx 1 Mbps + small-packet flood, D7 set/reset clear rx/tx state, D14 unload
# refused while attached, P-M1 detach.sh exit 4/1, D19 upgrade from HASH pins.
# 4th round: D25 LRU max_entries 16384 (map-sizes-d25, upgrade from LRU-1024
# pins), D26 same-value set keeps rx/tx state, changed value clears it.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=${OUT:-${ROOT}/_workspace/test-$(date +%Y%m%d_%H%M%S)}
T=${T:-15}
CLI=${ROOT}/target/release/vantage-5G
IF=vt-n6
SVC=10.99.0.1
VERDICT=${ROOT}/.claude/skills/vantage-testbed/scripts/iperf_verdict.py
CVERDICT=${ROOT}/.claude/skills/vantage-testbed/scripts/counter_verdict.py
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
    restore_bpftool
    # detach -> unload: unload refuses while a Vantage program is attached (D14).
    op "${ROOT}/detach.sh" "${IF}" >/dev/null 2>&1 || true
    ip link set dev "${IF}" xdpgeneric off 2>/dev/null || true
    tc qdisc del dev "${IF}" clsact 2>/dev/null || true
    pkill -x iperf3 2>/dev/null || true
    ip netns del vt-src 2>/dev/null || true; ip link del vt-s0 2>/dev/null || true
    "${ROOT}/testbed/netns-topo.sh" down >/dev/null 2>&1 || true
    "${CLI}" unload >/dev/null 2>&1 || true
}
trap cleanup EXIT

{ uname -r; git -C "${ROOT}" describe --always --dirty 2>/dev/null || echo "no-git"
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

# Counter of UE $1, column $2 of `vantage-5G stats` (2 rx_bytes 3 rx_pkts
# 4 rx_drops 5 tx_bytes 6 tx_pkts 7 tx_drops); 0 when the UE has no stats yet.
stat_of() { "${CLI}" stats --ue-ip "$1" 2>/dev/null | awk -v c="$2" 'NR==2 && $c ~ /^[0-9]+$/ {v=$c} END {print v+0}'; }
snap() { echo "t=$(date +%s.%N)"; "${CLI}" stats; }
now_s() { date +%s.%N; }
ipkey() { echo "$1" | tr . ' '; }
has_state() { "${BPFTOOL}" map lookup pinned "/sys/fs/bpf/vantage/$1" key $(ipkey "$2") >/dev/null 2>&1; }
# Attach the loaded programs: setup.sh where fq exists, otherwise the L1 manual path.
attach() {
    if [[ ${HAS_FQ} == 1 ]]; then op "${ROOT}/setup.sh" "${IF}" && attached_ok
    else manual_attach; fi
}
manual_attach() {
    tc qdisc replace dev "${IF}" clsact &&
    ip link set dev "${IF}" xdpgeneric pinned /sys/fs/bpf/vantage/vantage_rx_policer &&
    tc filter add dev "${IF}" egress bpf da pinned /sys/fs/bpf/vantage/vantage_tx_pacer
}
is_attached_any() { ip -d link show dev "${IF}" | grep -q 'prog/xdp' || tc filter show dev "${IF}" egress | grep -q bpf; }
# setup.sh without bpftool must refuse (exit 2) before changing anything (D23/D24/O12).
no_bpftool_refused() {
    local before after rc
    hide_bpftool || { echo "could not hide bpftool"; restore_bpftool; return 1; }
    before=$(attach_snapshot 2>&1)
    op "${ROOT}/setup.sh" "${IF}"; rc=$?
    after=$(attach_snapshot 2>&1)
    restore_bpftool
    echo "setup.sh rc=${rc} (expect 2)"
    [[ ${rc} == 2 ]] || return 1
    [[ "${before}" == "${after}" ]] || { echo "state changed:"; diff <(echo "${before}") <(echo "${after}"); return 1; }
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
# D25: the three LRU state maps hold 16384 entries (pre-6.16 per-CPU LRU
# free lists take 128 entries per allocating CPU); policy map stays HASH 1024.
# Also records nproc and memlock (fully preallocated at load) for the README.
map_sizes() {
    local m line rc=0 tot=0 ml
    echo "nproc=$(nproc) kernel=$(uname -r) bpftool=$("${BPFTOOL}" version | head -1)"
    for m in rx_state_map tx_tstamp_map ue_stats_map ue_policy_map; do
        line=$("${BPFTOOL}" map show pinned /sys/fs/bpf/vantage/${m} | tr '\n' ' ')
        echo "${line}"
        if [[ ${m} == ue_policy_map ]]; then
            echo "${line}" | grep -qE "^[0-9]+: hash .*max_entries 1024 " || { echo "${m}: expect hash max_entries 1024"; rc=1; }
        else
            echo "${line}" | grep -qE "^[0-9]+: lru_hash .*max_entries 16384 " || { echo "${m}: expect lru_hash max_entries 16384"; rc=1; }
            ml=$(echo "${line}" | sed -n 's/.*memlock \([0-9]*\)B.*/\1/p'); tot=$(( tot + ${ml:-0} ))
        fi
    done
    echo "LRU memlock total: ${tot} B ($(( tot / 1024 )) KiB)"
    return ${rc}
}
run map-sizes-d25 map_sizes

# ---- 3. topology + attach ----
run topology "${ROOT}/testbed/netns-topo.sh" up || exit 1
# Fresh interface, bpftool hidden: exit 2 before step 1 (runs on L1 too: the
# bpftool check precedes the fq step).
run setup.sh-no-bpftool no_bpftool_refused
if [[ ${HAS_FQ} == 1 ]]; then
    run setup.sh op "${ROOT}/setup.sh" "${IF}" || exit 1
    # Attached interface, bpftool hidden: refuse, hooks untouched.
    run setup.sh-no-bpftool-attached no_bpftool_refused
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
# X3 (B): counter snapshots for the L2-byte verdict, same skip window as iperf_verdict.
( sleep 5; snap > "${OUT}/stats_t1.txt" 2>&1; sleep $(( T - 6 )); snap > "${OUT}/stats_t2.txt" 2>&1 ) &
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
python3 "${CVERDICT}" "${SPEC}" "${OUT}/stats_t1.txt" "${OUT}/stats_t2.txt" > "${OUT}/verdict_counters.txt" 2>&1 \
    && rec PASS counter-verdict || rec FAIL counter-verdict "see verdict_counters.txt"
cat "${OUT}/verdict_counters.txt"
if [[ ${HAS_FQ} == 1 ]]; then
    # D16: tx_packets counts wire segments, so bytes/packet <= one MTU frame
    # (a GSO skb counted once would give tens of KB).
    d16() { awk '$1=="10.45.1.23" {b=$5; p=$6} END {r=(p? b/p : 0); printf "A tx_bytes/tx_packets=%.0f\n", r; exit !(p && r <= 1514)}' "${OUT}/stats_after_iperf.txt"; }
    run d16-tx-segments d16
fi

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

# ---- 7a. regressions (3rd round) ----
UA=10.45.1.23
# D7: reset clears the UE's rx_state_map / tx_tstamp_map entries.
# D26: set with the same values keeps them (output says so); a changed value
# (tx or rx) clears them.
state_val() { "${BPFTOOL}" map lookup pinned "/sys/fs/bpf/vantage/$1" key $(ipkey "$2") 2>/dev/null; }
d7_seed() {
    "${CLI}" set --ue-ip ${UA} --rx-mbps ${1} --tx-mbps ${2} || return 1
    ip netns exec vt-ue-a ping -c2 -W1 ${SVC} >/dev/null || { echo "ping failed"; return 1; }
    local m; for m in rx_state_map tx_tstamp_map; do has_state ${m} ${UA} || { echo "${m}: no entry after traffic"; return 1; }; done
}
d7_gone() { local m; for m in rx_state_map tx_tstamp_map; do has_state ${m} ${UA} && { echo "${m}: entry left after $1"; return 1; }; done; echo "$1 cleared both"; }
d7() {
    d7_seed 10 20 || return 1
    "${CLI}" reset --ue-ip ${UA} || return 1
    d7_gone reset
}
d7_same() {
    local m out b_rx b_tx
    d7_seed 10 20 || return 1
    b_rx=$(state_val rx_state_map ${UA}); b_tx=$(state_val tx_tstamp_map ${UA})
    out=$("${CLI}" set --ue-ip ${UA} --rx-mbps 10 --tx-mbps 20) || return 1
    echo "${out}"
    echo "${out}" | grep -qF '(unchanged; rx/tx state kept)' || { echo "missing '(unchanged; rx/tx state kept)'"; return 1; }
    for m in rx_state_map tx_tstamp_map; do has_state ${m} ${UA} || { echo "${m}: entry removed by same-value set"; return 1; }; done
    # No traffic in between: the entries must be the very same values.
    [[ "$(state_val rx_state_map ${UA})" == "${b_rx}" && "$(state_val tx_tstamp_map ${UA})" == "${b_tx}" ]] \
        || { echo "state values changed by same-value set"; return 1; }
    "${CLI}" list | grep -F "${UA}" || true
    echo "same-value set kept both (values identical)"
}
d7_changed() {
    local out
    d7_seed 10 20 || return 1
    out=$("${CLI}" set --ue-ip ${UA} --rx-mbps 10 --tx-mbps 30) || return 1
    echo "${out}"
    echo "${out}" | grep -qF 'unchanged' && { echo "tx change reported as unchanged"; return 1; }
    d7_gone "tx change (20->30)" || return 1
    d7_seed 10 30 || return 1
    "${CLI}" set --ue-ip ${UA} --rx-mbps 11 --tx-mbps 30 || return 1
    d7_gone "rx change (10->11)"
}
run d7-reset-clears d7
run d26-same-set-keeps-state d7_same
run d26-changed-set-clears d7_changed

# D6: rx 1 Mbps + 64 B UDP flood (~100+ kpps offered) -> admitted rate ~1 Mbps, not starved.
d6() {
    local r0 r1 t0 t1 mbps rc=0
    "${CLI}" set --ue-ip ${UA} --rx-mbps 1 --tx-mbps 100 || return 1
    r0=$(stat_of ${UA} 2); t0=$(now_s)
    ip netns exec vt-ue-a iperf3 -c ${SVC} -p 5201 -u -l 64 -b 64M -t 10 -J > "${OUT}/d6_udp.json"
    r1=$(stat_of ${UA} 2); t1=$(now_s)
    mbps=$(python3 -c 'import sys;a=[float(x) for x in sys.argv[1:]];print("%.3f"%((a[1]-a[0])*8/(a[3]-a[2])/1e6))' ${r0} ${r1} ${t0} ${t1})
    python3 -c 'import json,sys;e=json.load(open(sys.argv[1]))["end"]["sum"];print("offered %.1f Mbps, %d datagrams"%(e["bits_per_second"]/1e6,e.get("packets",0)))' "${OUT}/d6_udp.json" 2>/dev/null
    echo "rx_bytes rate ${mbps} Mbps (cap 1, expect ~1.05 incl. initial 67 KB bucket)"
    python3 -c "import sys;sys.exit(0 if 0.9<=float(sys.argv[1])<=1.2 else 1)" "${mbps}" || rc=1
    "${CLI}" set --ue-ip ${UA} --rx-mbps 10 --tx-mbps 20
    return ${rc}
}
run d6-small-pkt-no-starvation d6

# D4: forwarded DL (no socket backpressure) far over a 1 Mbps cap must not push the
# EDT slot past the 2 s horizon; TCP right after must connect. Local -R UDP does not
# reproduce it (sndbuf backpressure), so traffic comes from vt-src via root-ns forwarding.
d4() {
    local fwd0 d0 d1 r0 r1 lead mbps rc=0
    fwd0=$(sysctl -n net.ipv4.ip_forward)
    ip netns add vt-src && ip link add vt-s0 type veth peer name vt-s1 && ip link set vt-s1 netns vt-src || return 1
    ip addr add 10.98.0.1/24 dev vt-s0; ip link set vt-s0 up
    ip -n vt-src addr add 10.98.0.2/24 dev vt-s1; ip -n vt-src link set vt-s1 up; ip -n vt-src link set lo up
    ip -n vt-src route add default via 10.98.0.1
    sysctl -qw net.ipv4.ip_forward=1
    ip netns exec vt-ue-a iperf3 -s -p 5301 -D; ip netns exec vt-ue-a iperf3 -s -p 5302 -D; sleep 1
    "${CLI}" set --ue-ip ${UA} --rx-mbps 0 --tx-mbps 1 || rc=1
    d0=$(stat_of ${UA} 7); r0=$(stat_of ${UA} 2)
    ip netns exec vt-src iperf3 -c ${UA} -p 5301 -u -b 100M -t 10 -J > "${OUT}/d4_udp.json"
    d1=$(stat_of ${UA} 7)
    lead=$("${BPFTOOL}" -j map lookup pinned /sys/fs/bpf/vantage/tx_tstamp_map key $(ipkey ${UA}) 2>/dev/null | python3 -c '
import json,sys,struct,time
try:
    v=bytes(int(x,16) for x in json.load(sys.stdin)["value"])
    print("%.3f"%((struct.unpack("<Q",v)[0]-time.clock_gettime_ns(time.CLOCK_MONOTONIC))/1e9))
except Exception: print("none")')
    echo "UDP 100M fwd @1 Mbps: tx_drops +$((d1 - d0)), tx_tstamp - now = ${lead} s (limit 2 s)"
    tc -s qdisc show dev "${IF}" | grep -A2 '^qdisc fq' | grep -E 'dropped|horizon'
    timeout 40 ip netns exec vt-src iperf3 -c ${UA} -p 5302 -t 10 -J > "${OUT}/d4_tcp.json"; local trc=$?
    r1=$(stat_of ${UA} 2)
    mbps=$(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print("%.3f"%(j["end"]["sum_received"]["bits_per_second"]/1e6))' "${OUT}/d4_tcp.json" 2>/dev/null || echo 0)
    echo "TCP fwd right after: rc=${trc} received ${mbps} Mbps"
    echo "D15: rx_bps=0 UE rx_bytes +$((r1 - r0)) (must count)"
    [[ $((d1 - d0)) -gt 0 ]] || { echo "tx_drops did not increase"; rc=1; }
    [[ "${lead}" != none ]] && python3 -c "import sys;sys.exit(0 if float(sys.argv[1])<=2.1 else 1)" "${lead}" \
        || { echo "EDT slot beyond 2 s horizon (or unreadable)"; rc=1; }
    [[ ${trc} == 0 ]] && python3 -c "import sys;sys.exit(0 if float(sys.argv[1])>=0.3 else 1)" "${mbps}" \
        || { echo "TCP after overload failed/blackholed"; rc=1; }
    if [[ ${HAS_FQ} == 1 ]]; then
        python3 -c "import sys;sys.exit(0 if float(sys.argv[1])<=1.1 else 1)" "${mbps}" || { echo "TCP over 1 Mbps cap"; rc=1; }
    fi
    [[ $((r1 - r0)) -gt 0 ]] || { echo "D15: rx counters not updated for rx_bps=0"; rc=1; }
    pkill -f 'iperf3 -s -p 530[12]' 2>/dev/null
    ip netns del vt-src; ip link del vt-s0 2>/dev/null
    sysctl -qw net.ipv4.ip_forward="${fwd0}"
    "${CLI}" set --ue-ip ${UA} --rx-mbps 10 --tx-mbps 20
    return ${rc}
}
run d4-fwd-overload-then-tcp d4

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
# D14: unload must refuse while attached, pins untouched, hooks untouched.
unload_guard() {
    local before after out
    before=$(ls /sys/fs/bpf/vantage)
    if out=$("${CLI}" unload 2>&1); then echo "${out}"; echo "unload succeeded while attached"; return 1; fi
    echo "${out}"
    echo "${out}" | grep -q "detach.sh ${IF}" || { echo "no detach.sh hint for ${IF}"; return 1; }
    after=$(ls /sys/fs/bpf/vantage)
    [[ "${before}" == "${after}" ]] || { echo "pins changed"; return 1; }
    if [[ ${HAS_FQ} == 1 ]]; then attached_ok; else is_attached_any; fi
}
run unload-refused-while-attached unload_guard
# P-M1: detach.sh exits 4 when hooks remain (here: unprivileged user, no sudo),
# 1 for a missing interface.
detach_rc() {
    local d rc before after
    d=$(mktemp -d /tmp/vt-detach-XXXXXX); cp "${ROOT}/detach.sh" "${d}/"; chmod 755 "${d}" "${d}/detach.sh"
    before=$(attach_snapshot 2>&1)
    timeout 30 setpriv --reuid=nobody --regid=nogroup --clear-groups -- "${d}/detach.sh" "${IF}" </dev/null; rc=$?
    after=$(attach_snapshot 2>&1)
    echo "detach.sh as nobody rc=${rc} (expect 4)"
    [[ ${rc} == 4 ]] || { rm -rf "${d}"; return 1; }
    [[ "${before}" == "${after}" ]] || { echo "state changed"; rm -rf "${d}"; return 1; }
    "${d}/detach.sh" vt-nonexistent0; rc=$?
    rm -rf "${d}"
    echo "detach.sh missing iface rc=${rc} (expect 1)"
    [[ ${rc} == 1 ]]
}
run detach-rc detach_rc
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

# ---- 9. D19 upgrade: an older build loaded + attached, then the new build ----
# $1=hash   : 2nd-round release (state maps HASH, 1024 entries)
# $1=lru1024: 3rd-round build (LRU_HASH, 1024 entries; D25 changes only max_entries)
upgrade() {
    local variant=$1 od s out rc m oldtype exp
    od=$(mktemp -d /tmp/vt-old-XXXXXX)
    for s in vantage_rx_policer vantage_tx_pacer; do
        if [[ ${variant} == hash ]]; then
            sed -e 's/BPF_MAP_TYPE_LRU_HASH/BPF_MAP_TYPE_HASH/' -e 's/max_entries, 16384/max_entries, 1024/' "${ROOT}/${s}.c" > "${od}/${s}.c"
        else
            sed -e 's/max_entries, 16384/max_entries, 1024/' "${ROOT}/${s}.c" > "${od}/${s}.c"
        fi
        grep -q 'max_entries, 16384' "${od}/${s}.c" && { echo "old build still has 16384"; return 1; }
        clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -I"${ROOT}" -c "${od}/${s}.c" -o "${od}/${s}.o" || return 1
    done
    [[ ${variant} == hash ]] && oldtype=hash || oldtype=lru_hash
    echo "--- old build (${variant}): load + attach + set"
    # cwd is searched last (5th round, M-D1), so name the old build explicitly.
    "${CLI}" load --obj-dir "${od}" || return 1
    "${BPFTOOL}" map show pinned /sys/fs/bpf/vantage/rx_state_map | tr '\n' ' ' | grep -qE "^[0-9]+: ${oldtype} .*max_entries 1024 " \
        || { echo "old rx_state_map not ${oldtype}/1024"; return 1; }
    attach || return 1
    "${CLI}" set --ue-ip ${UA} --rx-mbps 10 --tx-mbps 20 || return 1
    echo "--- new build on old pins: load must refuse (rc=1) with the procedure, nothing changed"
    local before after; before=$(attach_snapshot 2>&1; ls /sys/fs/bpf/vantage)
    out=$("${CLI}" load 2>&1); rc=$?
    echo "${out}"
    after=$(attach_snapshot 2>&1; ls /sys/fs/bpf/vantage)
    [[ ${rc} == 1 ]] || { echo "load rc=${rc} (expect 1)"; return 1; }
    echo "${out}" | grep -q 'do not match' && echo "${out}" | grep -q 'detach.sh' && echo "${out}" | grep -q 'unload' \
        || { echo "upgrade hint missing"; return 1; }
    echo "${out}" | grep -q 'max_entries 1024 -> 16384' || { echo "max_entries difference not reported"; return 1; }
    [[ "${before}" == "${after}" ]] || { echo "state changed by refused load"; return 1; }
    "${CLI}" list | grep -q ${UA} || { echo "policy lost by refused load"; return 1; }
    echo "--- documented procedure: detach -> unload -> load -> setup -> set"
    op "${ROOT}/detach.sh" "${IF}" || return 1
    "${CLI}" unload || return 1
    "${CLI}" load || return 1
    attach || return 1
    for m in rx_state_map tx_tstamp_map ue_stats_map; do
        "${BPFTOOL}" map show pinned /sys/fs/bpf/vantage/${m} | tr '\n' ' ' | grep -qE "^[0-9]+: lru_hash .*max_entries 16384 " \
            || { echo "${m} not lru_hash/16384 after upgrade"; return 1; }
    done
    "${CLI}" list | grep -q ${UA} && { echo "policy survived unload?"; return 1; }
    "${CLI}" set --ue-ip ${UA} --rx-mbps 10 --tx-mbps 20 || return 1
    ip netns exec vt-ue-a ping -c2 -W1 ${SVC} >/dev/null || { echo "UE-A unreachable after upgrade"; return 1; }
    [[ $(stat_of ${UA} 6) -gt 0 ]] || { echo "no tx counters after upgrade"; return 1; }
    rm -rf "${od}"
    op "${ROOT}/detach.sh" "${IF}" && "${CLI}" unload
}
run upgrade-from-hash-pins upgrade hash
run upgrade-from-lru1024-pins upgrade lru1024

echo
echo "results: ${OUT}"
! grep -q '^\[FAIL' "${SUMMARY}"
