# l3-test.sh — `testbed/l3-vbox.sh test` body (sourced; uses its helpers core/svc/croot/sroot).
#
# Scenarios (README §3.2 / §8, docs/install-runbook.md 1장·4장, commands as documented):
#   (a) Open5GS quickstart as installed (MASQUERADE): the service node's N6 sees only
#       the UPF's N6 address; Vantage policies for the UE addresses never match.
#   (b) README §3.2 (1) NAT exception (method A), (2) ip_forward, (3) return route,
#       end-to-end check, path capacity without policy, README §8 4-session run with
#       iperf3 -B <UE IP>, counter + iperf verdicts, killswitch; then (1) method B.

T=${T:-30}
TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/l3-${TS}
mkdir -p "${OUT}"
SUMMARY=${OUT}/summary.txt; : > "${SUMMARY}"
WORK=/home/ubuntu/work
CLI="${WORK}/target/release/vantage-5G"
VERDICT=${ROOT}/.claude/skills/vantage-testbed/scripts/iperf_verdict.py
CVERDICT=${ROOT}/.claude/skills/vantage-testbed/scripts/counter_verdict.py
rec() { printf '[%-4s] %-28s %s\n' "$1" "$2" "${3:-}" | tee -a "${SUMMARY}"; }
# run <name> <function>: PASS/FAIL by the function's rc, output in <name>.log
run() { local name=$1; shift; if "$@" >"${OUT}/${name}.log" 2>&1; then rec PASS "${name}"; return 0; else rec FAIL "${name}" "see ${name}.log"; return 1; fi; }
ran() { croot "ip netns exec ran $*"; }            # command on the UE side (netns ran on vantage-core)
vcli() { sroot "cd ${WORK} && ./target/release/vantage-5G $*"; }

IF=$(svc_n6_if)
[[ -n "${IF}" ]] || { echo "[-] vantage-svc has no N6 NIC: run ./testbed/l3-vbox.sh up"; exit 1; }
# Make sure the RAN is up (2 PDU sessions); a reboot of vantage-core loses the netns.
[[ $(croot "bash /home/ubuntu/core-ran.sh ues" | wc -l) -ge 2 ]] || croot "bash /home/ubuntu/core-ran.sh up" >/dev/null || exit 1
read -r TUN_A UE_A <<<"$(croot "bash /home/ubuntu/core-ran.sh ues" | sed -n 1p)"
read -r TUN_B UE_B <<<"$(croot "bash /home/ubuntu/core-ran.sh ues" | sed -n 2p)"
echo "UE-A ${TUN_A} ${UE_A}   UE-B ${TUN_B} ${UE_B}   service node ${SVC} on ${IF}"

svc_clean() {
    sroot "cd ${WORK}; pkill -x iperf3; pkill -x tcpdump; ./detach.sh ${IF} >/dev/null 2>&1; ./target/release/vantage-5G unload >/dev/null 2>&1
           ip route del ${UE_NET} 2>/dev/null; true"
}
# L3-1: whatever happens (failure, Ctrl-C, ssh drop), leave both VMs as `test` found them:
# no Vantage on <IF>, no return route, no iperf3/tcpdump, core NAT back to the quickstart state.
l3_cleanup() {
    trap - EXIT INT TERM
    local j; for j in $(jobs -p); do kill "${j}" 2>/dev/null; done
    svc_clean >/dev/null 2>&1
    croot "pkill -x iperf3; bash /home/ubuntu/core-ran.sh nat-reference" > "${OUT}/nat-reference-end.log" 2>&1
}
trap l3_cleanup EXIT
trap 'echo "[!] interrupted, cleaning up"; exit 130' INT TERM
svc_clean
croot "pkill -x iperf3; bash /home/ubuntu/core-ran.sh nat-reference" > "${OUT}/nat-reference-start.log" 2>&1

# Rsync the tree under test to the service node and build (operator path, README §4).
svc
rsync -a --delete -e "ssh ${SSH_OPTS[*]}" --exclude target --exclude '_workspace*' --exclude .git \
    "${ROOT}/" ubuntu@127.0.0.1:work/ || exit 1
run build ssh_s "sudo -i bash -c 'cd ${WORK} && make build'" || { rec SKIP rest "build failed"; exit 1; }

{ git -C "${ROOT}" describe --always --dirty 2>/dev/null; echo "host uptime: $(uptime)"
  echo "--- vantage-core"; croot ". /etc/os-release; echo \$PRETTY_NAME; uname -r
      echo open5gs \$(dpkg-query -W -f='\${Version}' open5gs) mongodb-org \$(dpkg-query -W -f='\${Version}' mongodb-org)
      echo UERANSIM \$(git -C /opt/UERANSIM describe --tags 2>/dev/null)
      ip -br -4 addr show; ip -n ran -br -4 addr show; bash /home/ubuntu/core-ran.sh status"
  echo "--- vantage-svc"; sroot ". /etc/os-release; echo \$PRETTY_NAME; uname -r; ip -V; ip -br -4 addr show
      ethtool -i ${IF} | head -2; ethtool -l ${IF} 2>/dev/null | tail -5; tc qdisc show dev ${IF}"
} > "${OUT}/env.txt" 2>&1
echo "UE_A=${UE_A} TUN_A=${TUN_A} UE_B=${UE_B} TUN_B=${TUN_B} IF=${IF} SVC=${SVC}" >> "${OUT}/env.txt"

# cap_n6 <name> <tcpdump filter> <count> <command in netns ran>: capture on the
# service node's N6 NIC while the UE side runs the command.
cap_n6() {
    local name=$1 filt=$2 cnt=$3; shift 3
    ssh_s "sudo timeout 20 tcpdump -lni ${IF} -c ${cnt} ${filt}" > "${OUT}/${name}.tcpdump.txt" 2>&1 &
    local p=$!; sleep 3
    ran "$@" > "${OUT}/${name}.ue.txt" 2>&1; local rc=$?
    wait ${p}
    return ${rc}
}

# ---- 0. UE side: README §8.1 ----
ue_addrs() {
    ran "ip -br -4 addr show | grep uesimtun"
    ran "ip -4 addr show ${TUN_A}"
    local ok=0
    for u in "${TUN_A} ${UE_A}" "${TUN_B} ${UE_B}"; do
        set -- ${u}
        [[ $2 == 10.45.* ]] || { echo "$2 not in ${UE_NET}"; ok=1; }
        ran "ip route get ${SVC} from $2" | tee /dev/stderr | grep -q "dev $1" || { echo "route from $2 not via $1"; ok=1; }
    done
    return ${ok}
}
run ue-addr-8.1 ue_addrs
run nr-binder-in-build croot "ls -l /opt/UERANSIM/build/nr-binder /opt/UERANSIM/build/libdevbnd.so && cat /opt/UERANSIM/build/nr-binder"

# ---- Vantage on the service node (README §5): load, setup.sh <IF>, servers ----
run load vcli load
run setup.sh sroot "cd ${WORK} && ./setup.sh ${IF} && tc qdisc show dev ${IF} && ip -d link show dev ${IF} | grep -o 'xdpgeneric.*' ; tc filter show dev ${IF} egress"
sroot "for p in 5201 5202 5203 5204; do iperf3 -s -p \$p -D; done"

# ---- (a) reference install: MASQUERADE ----
A_CAP=2   # Mbps, far below the path: any match would show
a_upf_ip_only() {
    cap_n6 a-ping icmp 6 "ping -I ${TUN_A} -c 5 ${SVC}" || { echo "ping from UE failed"; return 1; }
    cat "${OUT}/a-ping.tcpdump.txt"
    grep -q "IP ${CORE_N6} > ${SVC}: ICMP echo request" "${OUT}/a-ping.tcpdump.txt" || { echo "no request from UPF N6 address"; return 1; }
    ! grep -q '10\.45\.' "${OUT}/a-ping.tcpdump.txt" || { echo "UE address visible despite NAT"; return 1; }
    # README §3.2 "Check end to end" filter: nothing to see in (a)
    cap_n6 a-ping-uenet "net ${UE_NET}" 10 "ping -I ${TUN_A} -c 5 ${SVC}"
    echo "packets with net ${UE_NET}: $(grep -c ' IP ' "${OUT}/a-ping-uenet.tcpdump.txt")"
    ! grep -q ' IP ' "${OUT}/a-ping-uenet.tcpdump.txt"
}
run a-n6-sees-upf-ip-only a_upf_ip_only
a_no_match() {
    vcli set --ue-ip ${UE_A} --rx-mbps ${A_CAP} --tx-mbps ${A_CAP} || return 1
    vcli set --ue-ip ${UE_B} --rx-mbps ${A_CAP} --tx-mbps ${A_CAP} || return 1
    ran "iperf3 -c ${SVC} -B ${UE_A} -p 5201 -t 10 -J" > "${OUT}/a_ul.json"
    ran "iperf3 -c ${SVC} -B ${UE_A} -p 5203 -t 10 -R -J" > "${OUT}/a_dl.json"
    vcli stats | tee "${OUT}/a_stats.txt"
    local ul dl
    ul=$(jq '.end.sum_received.bits_per_second/1e6' "${OUT}/a_ul.json"); dl=$(jq '.end.sum_received.bits_per_second/1e6' "${OUT}/a_dl.json")
    echo "UE-A with policy rx=tx=${A_CAP} Mbps: UL ${ul} Mbps, DL ${dl} Mbps"
    grep -qE "^(${UE_A}|${UE_B}) " "${OUT}/a_stats.txt" && { echo "UE rows in stats under NAT?"; return 1; }
    awk -v u="${ul}" -v d="${dl}" -v c="${A_CAP}" 'BEGIN {exit !(u > 3*c && d > 3*c)}' || { echo "rate not above the cap"; return 1; }
    vcli reset --ue-ip ${UE_A}; vcli reset --ue-ip ${UE_B}
}
run a-policy-never-matches a_no_match

# ---- (b) README §3.2 (1) method A, (2), (3) — commands as documented ----
b1() {
    croot "iptables -t nat -S POSTROUTING"
    croot "iptables -t nat -I POSTROUTING 1 -s ${UE_NET} -d ${SVC_NET} -j ACCEPT" || return 1
    croot "iptables -t nat -L POSTROUTING -n -v --line-numbers" | tee "${OUT}/b1-nat.txt"
    awk '/ACCEPT/ && /10.200.0.0\/24/ {a=$1} /MASQUERADE/ {m=$1} END {exit !(a && m && a < m)}' "${OUT}/b1-nat.txt" \
        || { echo "ACCEPT not above MASQUERADE"; return 1; }
    # existing NATed connections (scenario a): README's conntrack command
    croot "apt-get install -y conntrack >/dev/null 2>&1 && conntrack -D -s ${UE_NET}"; echo "conntrack -D rc=$?"
}
run b1-nat-exception-A b1
b2() {
    croot "sysctl net.ipv4.ip_forward
           echo 'net.ipv4.ip_forward=1' | tee /etc/sysctl.d/90-ue-forward.conf
           sysctl --system >/dev/null
           sysctl net.ipv4.ip_forward
           iptables -S FORWARD | head -1
           ip route get ${SVC}" | tee "${OUT}/b2.txt"
    grep -q 'net.ipv4.ip_forward = 1' "${OUT}/b2.txt" && grep -q -- '-P FORWARD ACCEPT' "${OUT}/b2.txt"
}
run b2-ip-forward b2
# (3) missing: requests arrive, replies leave through the default route (not <IF>)
b3_missing() {
    sroot "ip route get 10.45.0.2"
    cap_n6 b3-noroute "net ${UE_NET}" 10 "ping -I ${TUN_A} -c 3 -W 1 ${SVC}"; echo "ping rc=$? (expected 1: replies lost)"
    cat "${OUT}/b3-noroute.tcpdump.txt"
    grep -q "IP ${UE_A} > ${SVC}: ICMP echo request" "${OUT}/b3-noroute.tcpdump.txt" && ! grep -q "ICMP echo reply" "${OUT}/b3-noroute.tcpdump.txt"
}
run b3-no-route-replies-lost b3_missing
b3() {
    sroot "ip route add ${UE_NET} via ${CORE_N6} dev ${IF}" || return 1
    sroot "ip route get 10.45.0.2" | tee /dev/stderr | grep -q "via ${CORE_N6} dev ${IF}"
}
run b3-return-route b3
e2e() {
    cap_n6 b-e2e "net ${UE_NET}" 10 "ping -I ${TUN_A} -c 5 ${SVC}" || { echo "ping failed"; return 1; }
    cat "${OUT}/b-e2e.tcpdump.txt"
    grep -q "IP ${UE_A} > ${SVC}: ICMP echo request" "${OUT}/b-e2e.tcpdump.txt" \
        && grep -q "IP ${SVC} > ${UE_A}: ICMP echo reply" "${OUT}/b-e2e.tcpdump.txt"
}
run b-e2e-ue-ip-on-n6 e2e

# ---- run4 <tag> <capA_rx> <capA_tx> <capB_rx> <capB_tx>: README §8.3/8.4, 4 sessions at once ----
run4() {
    local tag=$1 d=${OUT}/$1
    mkdir -p "${d}"
    croot "rm -rf /tmp/l3 && mkdir -p /tmp/l3"
    # §8.4 snapshots (service node), started with the clients
    sroot "sleep 5; { echo t=\$(date +%s.%N); ${CLI} stats; } > /tmp/stats_t1.txt
           sleep 20; { echo t=\$(date +%s.%N); ${CLI} stats; } > /tmp/stats_t2.txt" &
    local sp=$!
    croot "cd /tmp/l3
        ip netns exec ran iperf3 -c ${SVC} -B ${UE_A} -p 5201 -t ${T}    -J > a_ul.json &
        ip netns exec ran iperf3 -c ${SVC} -B ${UE_A} -p 5203 -t ${T} -R -J > a_dl.json &
        ip netns exec ran iperf3 -c ${SVC} -B ${UE_B} -p 5202 -t ${T}    -J > b_ul.json &
        ip netns exec ran iperf3 -c ${SVC} -B ${UE_B} -p 5204 -t ${T} -R -J > b_dl.json &
        wait"
    wait ${sp}
    csh "sudo tar -C /tmp/l3 -cf - ." | tar -C "${d}" -xf -
    ssh_s "cat /tmp/stats_t1.txt" > "${d}/stats_t1.txt"; ssh_s "cat /tmp/stats_t2.txt" > "${d}/stats_t2.txt"
    vcli stats > "${d}/stats_after.txt"
    sroot "tc -s qdisc show dev ${IF}" > "${d}/qdisc_after.txt"
    printf 'label,ue_ip,direction,cap_mbps,json_path\nA-UL,%s,UL,%s,a_ul.json\nB-UL,%s,UL,%s,b_ul.json\nA-DL,%s,DL,%s,a_dl.json\nB-DL,%s,DL,%s,b_dl.json\n' \
        "${UE_A}" "$2" "${UE_B}" "$4" "${UE_A}" "$3" "${UE_B}" "$5" > "${d}/spec.csv"
    echo "host uptime: $(uptime)" > "${d}/uptime.txt"
}
# per-session Mbps summary of a run directory
rates() { for f in a_ul a_dl b_ul b_dl; do printf '%s %.2f\n' "${f}" "$(jq '.end.sum_received.bits_per_second/1e6' "$1/${f}.json" 2>/dev/null || echo 0)"; done; }

# ---- path capacity without policy (Vantage attached, no UE policy) ----
baseline() {
    vcli list
    run4 baseline 1000 1000 1000 1000
    rates "${OUT}/baseline" | tee "${OUT}/baseline/rates.txt"
    awk '$2 > 1 {n++} END {exit !(n == 4)}' "${OUT}/baseline/rates.txt"
}
run b-baseline-no-policy baseline
MIN=$(awk 'NR==1 || $2 < m {m=$2} END {printf "%d", m}' "${OUT}/baseline/rates.txt" 2>/dev/null)
if [[ -n "${VT_L3_CAPS:-}" ]]; then read -r CA_RX CA_TX CB_RX CB_TX <<<"${VT_L3_CAPS}"
elif [[ ${MIN:-0} -ge 60 ]]; then CA_RX=10; CA_TX=20; CB_RX=3; CB_TX=5      # README §8 values
else CA_RX=4; CA_TX=6; CB_RX=2; CB_TX=3; fi
echo "baseline min session ${MIN} Mbps -> caps A rx/tx ${CA_RX}/${CA_TX}, B rx/tx ${CB_RX}/${CB_TX}" | tee "${OUT}/caps.txt"

# ---- README §8.2 policies + 4-session run ----
run set-A vcli set --ue-ip ${UE_A} --rx-mbps ${CA_RX} --tx-mbps ${CA_TX}
run set-B vcli set --ue-ip ${UE_B} --rx-mbps ${CB_RX} --tx-mbps ${CB_TX}
vcli list > "${OUT}/list.txt" 2>&1
run4 run "${CA_RX}" "${CA_TX}" "${CB_RX}" "${CB_TX}"
R=${OUT}/run
rates "${R}" > "${R}/rates.txt"
python3 "${VERDICT}" "${R}/spec.csv" > "${OUT}/verdict.txt" 2>&1 && rec PASS iperf-verdict || rec FAIL iperf-verdict "see verdict.txt"
python3 "${CVERDICT}" "${R}/spec.csv" "${R}/stats_t1.txt" "${R}/stats_t2.txt" > "${OUT}/verdict_counters.txt" 2>&1 \
    && rec PASS counter-verdict || rec FAIL counter-verdict "see verdict_counters.txt"
cat "${OUT}/verdict.txt" "${OUT}/verdict_counters.txt"
# Functional checks independent of the host's load: every UE seen by its own address,
# and no session above its cap (iperf err% and counter err% <= +10%).
stats_rows() {
    cat "${R}/stats_after.txt"
    awk -v a="${UE_A}" -v b="${UE_B}" '$1==a && $2>0 && $5>0 {na=1} $1==b && $2>0 && $5>0 {nb=1} END {exit !(na && nb)}' "${R}/stats_after.txt"
}
run b-stats-has-ue-rows stats_rows
no_over_cap() {
    awk '$1 ~ /^[AB]-(UL|DL)$/ && $7+0 > 10 {print "over cap (iperf): " $0; bad=1} END {exit bad}' "${OUT}/verdict.txt" || return 1
    awk '$1 ~ /^[AB]-(UL|DL)$/ && $6+0 > 10 {print "over cap (counter): " $0; bad=1} END {exit bad}' "${OUT}/verdict_counters.txt" || return 1
    echo "no session above cap +10%"
}
run b-no-session-over-cap no_over_cap
# E1' environment classification evidence for under-cap rows: tx_drops of the UEs.
awk -v a="${UE_A}" -v b="${UE_B}" '$1==a || $1==b {print "tx_drops " $1 " = " $7}' "${R}/stats_after.txt" > "${OUT}/tx_drops.txt"

# ---- DL controls (evidence for classifying an under-cap DL) ----
# ctl_dl <name> <iperf3 extra args>: UE-A DL for 16 s, counter delta over 4..14 s.
ctl_dl() {
    local name=$1; shift
    sroot "sleep 4; { echo t=\$(date +%s.%N); ${CLI} stats; } > /tmp/c1; sleep 10; { echo t=\$(date +%s.%N); ${CLI} stats; } > /tmp/c2" &
    local sp=$!
    ran "iperf3 -c ${SVC} -B ${UE_A} -p 5203 -t 16 -R -J $*" > "${OUT}/${name}.json"; wait ${sp}
    ssh_s "cat /tmp/c1 /tmp/c2" > "${OUT}/${name}_stats.txt"
    jq -r '(.end.sum_received // .end.sum).bits_per_second/1e6 | "iperf \(.) Mbps"' "${OUT}/${name}.json"
    awk -v ip="${UE_A}" '/^t=/{sub("t=","");t[++n]=$0} $1==ip{b[n]=$5;d[n]=$7} END{if (n==2) printf "counter %.3f Mbps tx_drops +%d\n",(b[2]-b[1])*8/(t[2]-t[1])/1e6,d[2]-d[1]}' "${OUT}/${name}_stats.txt"
}
# UDP (no TSQ back-pressure from TX completions): the pacer alone, counter within ±10% of A's tx cap.
udp_ctl() {
    local out; out=$(ctl_dl ctl_udp_dl -u -b $(( CA_TX * 2 ))M); echo "${out}"
    echo "${out}" | awk -v c="${CA_TX}" '/^counter/ {r=$2} END {d=(r-c)/c; printf "err %+.1f%%\n", d*100; exit !(d >= -0.10 && d <= 0.10)}'
}
run b-dl-udp-pacer-control udp_ctl
# Kernel shaper on the same NIC, no Vantage policy for UE-A: fq maxrate = A's tx cap.
kfq_ctl() {
    vcli reset --ue-ip ${UE_A}
    sroot "tc qdisc replace dev ${IF} root fq maxrate ${CA_TX}mbit"
    ran "iperf3 -c ${SVC} -B ${UE_A} -p 5203 -t 12 -R -J" > "${OUT}/ctl_kfq_dl.json"
    jq -r '.end.sum_received.bits_per_second/1e6 | "kernel fq maxrate '"${CA_TX}"'mbit: TCP DL \(.) Mbps"' "${OUT}/ctl_kfq_dl.json"
    # `replace root fq` would keep maxrate: delete and let setup.sh rebuild (supported re-run).
    sroot "tc qdisc del dev ${IF} root; cd ${WORK} && ./setup.sh ${IF} >/dev/null && tc qdisc show dev ${IF} | head -1" || return 1
    vcli set --ue-ip ${UE_A} --rx-mbps ${CA_RX} --tx-mbps ${CA_TX}
}
run b-dl-kernel-fq-control kfq_ctl
# Classification of the 4-session iperf verdict (E1'): under cap only, tx_drops 0, pacer exact on UDP.
if grep -q '^\[FAIL\] iperf-verdict' "${SUMMARY}"; then
    if grep -q '^\[PASS\] b-no-session-over-cap' "${SUMMARY}" && [[ $(wc -l < "${OUT}/tx_drops.txt") -eq 2 ]] \
       && ! grep -qv '= 0$' "${OUT}/tx_drops.txt" \
       && grep -q '^\[PASS\] b-dl-udp-pacer-control' "${SUMMARY}"; then
        rec INFO iperf-verdict-class "environment: under cap only, tx_drops 0, UDP pacer control in tolerance ($(grep -h 'kernel fq' "${OUT}/b-dl-kernel-fq-control.log"))"
    else
        rec INFO iperf-verdict-class "not classified as environment: check over-cap / tx_drops / UDP control"
    fi
fi

# ---- killswitch (README §6, runbook 4.5) ----
killswitch_body() {
    vcli set --ue-ip ${UE_B} --rx-mbps ${CB_RX} --tx-mbps 0 | tee /dev/stderr | grep -q '(killswitch: DL blocked)' || return 1
    # Test hook for the harness itself: fail here, with the killswitch still set.
    [[ "${VT_L3_FORCE_KS_FAIL:-0}" == 1 ]] && { echo "forced failure (VT_L3_FORCE_KS_FAIL=1)"; return 1; }
    local d1 d2
    d1=$(vcli stats | awk -v b="${UE_B}" '$1==b {print $7}')
    if ran "ping -I ${TUN_B} -c 3 -W 1 ${SVC}"; then echo "UE-B ping succeeded under killswitch"; return 1; fi
    ran "ping -I ${TUN_A} -c 3 -W 1 ${SVC}" || { echo "UE-A ping failed"; return 1; }
    ran "timeout 20 iperf3 -c ${SVC} -B ${UE_B} -p 5204 -t 8 -R -J" > "${OUT}/ks_b_dl.json"
    printf 'label,ue_ip,direction,cap_mbps,json_path\nB-DL-kill,%s,DL,0,ks_b_dl.json\n' "${UE_B}" > "${OUT}/ks_spec.csv"
    python3 "${VERDICT}" "${OUT}/ks_spec.csv" || return 1
    d2=$(vcli stats | awk -v b="${UE_B}" '$1==b {print $7}')
    echo "UE-B TX_DROPS ${d1} -> ${d2}"
    [[ ${d2:-0} -gt ${d1:-0} ]]
}
# L3-2: restore UE-B's policy even when a check above failed, so later steps are not blocked.
killswitch() {
    killswitch_body; local rc=$?
    vcli set --ue-ip ${UE_B} --rx-mbps ${CB_RX} --tx-mbps ${CB_TX} || rc=1
    ran "ping -I ${TUN_B} -c 3 -W 1 ${SVC}" || rc=1
    return ${rc}
}
run killswitch killswitch

# ---- README §3.2 (1) method B: replace the MASQUERADE rule instead of the exception ----
b1_methodB() {
    croot "iptables -t nat -D POSTROUTING -s ${UE_NET} -d ${SVC_NET} -j ACCEPT"
    croot "iptables -t nat -D POSTROUTING -s ${UE_NET} ! -o ogstun -j MASQUERADE
           iptables -t nat -A POSTROUTING -s ${UE_NET} ! -d ${SVC_NET} ! -o ogstun -j MASQUERADE
           iptables -t nat -L POSTROUTING -n -v --line-numbers
           conntrack -D -s ${UE_NET}; true"
    cap_n6 b1B-e2e "net ${UE_NET}" 10 "ping -I ${TUN_B} -c 5 ${SVC}" || { echo "ping failed"; return 1; }
    cat "${OUT}/b1B-e2e.tcpdump.txt"
    grep -q "IP ${UE_B} > ${SVC}: ICMP echo request" "${OUT}/b1B-e2e.tcpdump.txt" \
        && grep -q "IP ${SVC} > ${UE_B}: ICMP echo reply" "${OUT}/b1B-e2e.tcpdump.txt"
}
run b1-nat-exception-B b1_methodB

# ---- detach -> unload (README §9) ----
sroot "pkill -x iperf3"
run detach sroot "cd ${WORK} && ./detach.sh ${IF}"
run unload vcli unload

git -C "${ROOT}" describe --always --dirty > "${OUT}/commit.txt" 2>/dev/null
echo "L3 results: ${OUT}"
! grep -q '^\[FAIL\]' "${SUMMARY}"
