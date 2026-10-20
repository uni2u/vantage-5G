#!/usr/bin/env bash
# systemd-test.sh pre|post|cleanup -- systemd service test (install.sh, systemd/ units,
# apply/export) inside an L2 VM, run as root from the synced repository. Driven by
# testbed/l2-systemd.sh, which runs pre, reboots the VM, then post and cleanup:
#   pre      make build, persistent test iface, install twice (config kept), enable, start
#   (host reboots the VM)
#   post     after-boot checks (active, attached, policies restored, monitor bind), real
#            traffic, reload (D26, CLI-only UE removed), stop/start/restart (monitor
#            keeps running: Wants=), IFACE edited while running, late interface, failure paths
#            (exit 6, invalid policies.conf, setup.sh exit 3, empty XDP_MODE), IFACE_WAIT_SEC
#            clamp, empty policies.conf reload refused, writer lock, bpffs mount under
#            the unit hardening, quoted MONITOR_ARGS, unload gate (stop fails, pins
#            kept, uninstall rc 4)
#   cleanup  uninstall (running) + uninstall --purge, remove the test iface config
# Every check prints PASS/FAIL; the last line is "RESULT-<step> pass=N fail=M".
# Test N6 interface: veth pair vn6 <-> vn6p created by systemd-networkd at every
# boot (/etc/systemd/network/50-vn6.*). vn6p is moved into netns "ue" at test
# time to send real UL/DL traffic. Subnet 10.99.1.0/24 (not 10.45.x: keeps the
# L2 run-tests path untouched even if cleanup is skipped).
# Changes the VM system-wide (/usr/local, /etc/systemd, /etc/vantage-5g): run it only
# on a test VM, and not while run-tests.sh is running there.
set -u
REPO=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
B=/usr/local/bin/vantage-5G
PASS=0; FAIL=0
ok()  { echo "PASS $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "######## $*"; }
st()  { systemctl show -p ActiveState,SubState,Result,ExecMainStatus "$1" | paste -sd' '; }
attached() { ip -d link show dev vn6 2>/dev/null | grep -q 'prog/xdp' && tc filter show dev vn6 egress | grep -q vantage_tx; }
ue_ns() {
    ip netns add ue 2>/dev/null
    ip link set vn6p netns ue 2>/dev/null
    ip -n ue addr replace 10.99.1.23/24 dev vn6p
    ip -n ue addr replace 10.99.1.24/24 dev vn6p
    ip -n ue link set lo up; ip -n ue link set vn6p up
}
traffic() {
    ue_ns
    pkill -f 'iperf3 -s -p 5299' 2>/dev/null; iperf3 -s -p 5299 -D -B 10.99.1.1; sleep 0.5
    echo "--- DL to .23 (tx cap 20 Mbps), 4 s"
    ip netns exec ue iperf3 -c 10.99.1.1 -p 5299 -B 10.99.1.23 -R -t 4 -f m 2>&1 | grep -E 'receiver|error'
    echo "--- UL from .23 (rx cap 10 Mbps), 4 s"
    ip netns exec ue iperf3 -c 10.99.1.1 -p 5299 -B 10.99.1.23 -t 4 -f m 2>&1 | grep -E 'receiver|error'
    echo "--- ping .24 (killswitch tx=0)"
    ping -c 5 -i 0.2 -W 1 10.99.1.24 | tail -2
    pkill -f 'iperf3 -s -p 5299'
    $B stats
}

case "${1:-}" in
pre)
    hdr "build"
    cd "${REPO}" && make build >/tmp/build.log 2>&1 || { tail -20 /tmp/build.log; exit 1; }
    hdr "persistent test interface (systemd-networkd veth)"
    cat > /etc/systemd/network/50-vn6.netdev <<'EOF'
[NetDev]
Name=vn6
Kind=veth
[Peer]
Name=vn6p
EOF
    cat > /etc/systemd/network/50-vn6.network <<'EOF'
[Match]
Name=vn6
[Link]
RequiredForOnline=no
[Network]
Address=10.99.1.1/24
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
    cat > /etc/systemd/network/50-vn6p.network <<'EOF'
[Match]
Name=vn6p
[Link]
RequiredForOnline=no
[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
    networkctl reload; sleep 2; ip -br link show vn6
    hdr "install --enable (twice: idempotent)"
    "${REPO}/install.sh" install --enable; echo "rc=$?"
    "${REPO}/install.sh" install --enable >/tmp/i2.log; rc=$?
    [[ $rc -eq 0 ]] && grep -q 'exists (kept)' /tmp/i2.log && ok "install re-run keeps config" || bad "install re-run rc=$rc"
    systemctl is-enabled vantage-5g.service vantage-5g-monitor.service
    hdr "configure"
    sed -i 's/^IFACE=.*/IFACE=vn6/; s/^MONITOR_ARGS=.*/MONITOR_ARGS=--bind 127.0.0.1 --port 9090/' /etc/vantage-5g/vantage-5g.env
    cat >> /etc/vantage-5g/policies.conf <<'EOF'
10.99.1.23   10   20     # test UE
10.99.1.24    5    0     # killswitch
EOF
    echo "# marker: user edit" >> /etc/vantage-5g/vantage-5g.env
    "${REPO}/install.sh" install >/dev/null && grep -q 'marker: user edit' /etc/vantage-5g/vantage-5g.env \
        && ok "install keeps edited env" || bad "install overwrote env"
    hdr "start"
    systemctl start vantage-5g.service vantage-5g-monitor.service; echo "rc=$?"   # monitor has After= only (Q8-11)
    st vantage-5g; st vantage-5g-monitor
    attached && ok "pre-reboot attached" || bad "pre-reboot not attached"
    $B list
    echo "RESULT-pre pass=$PASS fail=$FAIL"
    ;;
post)
    hdr "after boot"
    uptime; systemd-analyze 2>/dev/null | head -1
    st vantage-5g; st vantage-5g-monitor
    [[ "$(systemctl is-active vantage-5g)" == active ]] && ok "boot: vantage-5g active" || bad "boot: vantage-5g not active"
    sleep 2
    [[ "$(systemctl is-active vantage-5g-monitor)" == active ]] && ok "boot: monitor active" || bad "boot: monitor not active"
    journalctl -b -u vantage-5g --no-pager | tail -40
    systemd-analyze critical-chain vantage-5g.service --no-pager 2>/dev/null | head -12
    attached && ok "boot: attached" || bad "boot: not attached"
    ip -d link show dev vn6 | grep -o 'prog/xdp[a-z]* id [0-9]*'; tc qdisc show dev vn6; tc filter show dev vn6 egress | head -3
    $B list
    [[ "$($B export | grep -v '^#' | awk '{print $1,$2,$3}' | paste -sd,)" == "10.99.1.23 10 20,10.99.1.24 5 0" ]] \
        && ok "boot: policies restored" || bad "boot: policies"
    curl -s 127.0.0.1:9090/metrics | grep -E '^vantage_ue_policy_(rx|tx)_bps' && ok "boot: monitor metrics on 127.0.0.1" || bad "boot: metrics"
    ss -ltn | grep -q '0.0.0.0:9090' && bad "MONITOR_ARGS bind ignored" || ok "MONITOR_ARGS --bind applied"
    hdr "traffic"
    traffic 2>&1 | tee /tmp/traffic.txt
    awk '$1=="10.99.1.24" && $7>0 {f=1} END {exit !f}' /tmp/traffic.txt && ok "killswitch drops counted" || bad "killswitch drops"
    awk '$1=="10.99.1.23" && $2>0 && $5>0 {f=1} END {exit !f}' /tmp/traffic.txt && ok "UE .23 rx/tx counted" || bad "UE .23 counters"

    hdr "reload (policies.conf edited, D26)"
    sed -i 's/^10.99.1.24 .*/10.99.1.24    5    7/' /etc/vantage-5g/policies.conf
    $B set --ue-ip 10.99.1.50 --rx-mbps 1 --tx-mbps 1 >/dev/null
    systemctl reload vantage-5g; echo "rc=$?"
    journalctl -u vantage-5g --no-pager -n 6 | grep -E 'applied|removed|changed'
    [[ "$($B export | grep -v '^#' | awk '{print $1,$3}' | paste -sd,)" == "10.99.1.23 20,10.99.1.24 7" ]] \
        && ok "reload applied (+ CLI-only UE removed)" || bad "reload"
    attached && ok "reload kept attach" || bad "reload detached"

    hdr "stop / start / restart"
    systemctl stop vantage-5g; echo "stop rc=$?"; st vantage-5g; st vantage-5g-monitor
    ! attached && [[ ! -d /sys/fs/bpf/vantage ]] && ok "stop: detached + unloaded" || bad "stop"
    sleep 2
    [[ "$(systemctl is-active vantage-5g-monitor)" == active ]] && ok "stop: monitor keeps running (After= only)" || bad "stop: monitor went down"
    [[ -z "$(curl -s 127.0.0.1:9090/metrics | grep '^vantage_ue_policy_')" ]] && ok "stop: monitor dropped series" || bad "stop: stale series"
    systemctl start vantage-5g; echo "start rc=$?"
    attached && [[ "$($B export | grep -vc '^#')" -eq 2 ]] && ok "start: attached + 2 policies" || bad "start"
    MID1=$(systemctl show -p MainPID --value vantage-5g-monitor)
    systemctl restart vantage-5g; echo "restart rc=$?"; sleep 1
    MID2=$(systemctl show -p MainPID --value vantage-5g-monitor)
    attached && [[ "$(systemctl is-active vantage-5g)" == active ]] && ok "restart: active + attached" || bad "restart"
    sleep 2
    [[ "${MID1}" == "${MID2}" ]] && curl -s 127.0.0.1:9090/metrics | grep -q '^vantage_ue_policy_rx_bps' \
        && ok "restart: monitor not restarted, re-reads new maps" || bad "monitor after restart (${MID1} -> ${MID2})"

    hdr "IFACE edited while running: stop detaches the recorded iface"
    sed -i 's/^IFACE=.*/IFACE=lo/' /etc/vantage-5g/vantage-5g.env
    systemctl stop vantage-5g; echo "stop rc=$?"
    ! attached && [[ ! -d /sys/fs/bpf/vantage ]] && ok "stop used recorded vn6" || bad "stop with edited IFACE"
    sed -i 's/^IFACE=.*/IFACE=vn6/' /etc/vantage-5g/vantage-5g.env

    hdr "late interface (wait loop)"
    ip netns del ue 2>/dev/null; ip link del vn6 2>/dev/null; sleep 1
    systemctl start --no-block vantage-5g; sleep 8
    st vantage-5g
    networkctl reload; sleep 1; ip link show vn6 >/dev/null 2>&1 || systemctl restart systemd-networkd
    for i in $(seq 30); do [[ "$(systemctl is-active vantage-5g)" == activating ]] || break; sleep 1; done
    journalctl -u vantage-5g --no-pager -n 30 | grep -E 'waiting|appeared'
    [[ "$(systemctl is-active vantage-5g)" == active ]] && attached && ok "late iface: attached after it appeared" || bad "late iface"

    hdr "failure: interface never appears (exit 6)"
    systemctl stop vantage-5g
    sed -i 's/^IFACE=.*/IFACE=nosuch0/; s/^IFACE_WAIT_SEC=.*/IFACE_WAIT_SEC=3/' /etc/vantage-5g/vantage-5g.env
    systemctl start vantage-5g; echo "rc=$?"; st vantage-5g
    [[ "$(systemctl show -p ExecMainStatus --value vantage-5g)" == 6 ]] || systemctl status vantage-5g --no-pager | grep -q 'status=6' \
        && ok "missing iface -> failed status=6" || bad "missing iface status"
    sed -i 's/^IFACE=.*/IFACE=vn6/; s/^IFACE_WAIT_SEC=.*/IFACE_WAIT_SEC=90/' /etc/vantage-5g/vantage-5g.env
    systemctl reset-failed vantage-5g

    hdr "failure: empty XDP_MODE= -> preflight status=1 (Q8-7)"
    sed -i 's/^XDP_MODE=.*/XDP_MODE=/' /etc/vantage-5g/vantage-5g.env
    systemctl start vantage-5g; systemctl status vantage-5g --no-pager | grep -E 'ExecStartPre.*status='
    journalctl -u vantage-5g --no-pager -n 5 | grep 'XDP_MODE is empty' && [[ ! -d /sys/fs/bpf/vantage ]] \
        && ok "empty XDP_MODE rejected by preflight, nothing loaded" || bad "empty XDP_MODE"
    sed -i 's/^XDP_MODE=.*/XDP_MODE=generic/' /etc/vantage-5g/vantage-5g.env; systemctl reset-failed vantage-5g

    hdr "IFACE_WAIT_SEC above 240 clamped (Q8-8)"
    sed -i 's/^IFACE_WAIT_SEC=.*/IFACE_WAIT_SEC=600/' /etc/vantage-5g/vantage-5g.env
    systemctl start vantage-5g && journalctl -u vantage-5g --no-pager -n 40 | grep -q 'exceeds 240s' && attached \
        && ok "IFACE_WAIT_SEC=600 clamped, start ok" || bad "clamp"
    sed -i 's/^IFACE_WAIT_SEC=.*/IFACE_WAIT_SEC=90/' /etc/vantage-5g/vantage-5g.env

    hdr "empty policies.conf + reload -> refused, policies kept (O-8a)"
    cp /etc/vantage-5g/policies.conf /tmp/pol.keep; : > /etc/vantage-5g/policies.conf
    systemctl reload vantage-5g; echo "reload rc=$?"
    journalctl -u vantage-5g --no-pager -n 5 | grep -- '--allow-empty'
    [[ "$($B export | grep -vc '^#')" -eq 2 && "$(systemctl is-active vantage-5g)" == active ]] && ok "empty reload refused, 2 policies kept, unit active" || bad "empty reload"
    cp /tmp/pol.keep /etc/vantage-5g/policies.conf

    hdr "writer lock (Q8-2): reload waits for a concurrent CLI writer"
    flock /run/vantage-5g.lock sleep 3 & sleep 0.3
    t0=$(date +%s); systemctl reload vantage-5g; t1=$(date +%s); wait
    [[ $((t1-t0)) -ge 2 ]] && journalctl -u vantage-5g --no-pager -n 6 | grep -q 'waiting for /run/vantage-5g.lock' && ok "reload waited $((t1-t0)) s for the lock" || bad "lock wait"
    systemctl stop vantage-5g

    hdr "hardening: kernel modules auto-loaded from the hardened unit (no CAP_SYS_MODULE)"
    # Unload the qdisc/classifier modules setup.sh needs (only possible when
    # nothing uses them and they are modules, not built in), then start: tc's
    # request_module runs via the kernel usermode helper, not with the unit's caps.
    MODS="sch_fq cls_bpf sch_ingress"
    for m in ${MODS}; do modprobe -r "${m}" 2>/dev/null; done
    lsmod | awk '{print $1}' > /tmp/lsmod.before
    LOADED=""; for m in ${MODS}; do grep -qx "${m}" /tmp/lsmod.before && LOADED+=" ${m}"; done
    BUILTIN=""; for m in ${MODS}; do grep -q "/${m}.ko" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null && BUILTIN+=" ${m}"; done
    echo "still loaded (in use): ${LOADED:-none}; built in: ${BUILTIN:-none}"
    systemctl start vantage-5g; echo "rc=$?"
    lsmod | grep -E '^(sch_fq|cls_bpf|sch_ingress) ' 
    if [[ -n "${LOADED}${BUILTIN}" ]]; then
        bad "module autoload not testable (could not unload:${LOADED}${BUILTIN})"
    else
        attached && lsmod | grep -q '^sch_fq ' && lsmod | grep -q '^cls_bpf ' \
            && ok "sch_fq/cls_bpf/sch_ingress auto-loaded under the hardened unit, attached" || bad "module autoload under hardening"
    fi
    systemctl stop vantage-5g

    hdr "hardening: bpffs unmounted before start -> mounted in the host ns (VERIFY-L2-8c)"
    umount /sys/fs/bpf && ! mountpoint -q /sys/fs/bpf && echo "bpffs unmounted"
    systemctl start vantage-5g; echo "rc=$?"
    mountpoint -q /sys/fs/bpf && [[ -e /sys/fs/bpf/vantage/ue_policy_map ]] && attached && ok "preflight mount visible on host, pins + attach ok" || bad "bpffs mount under hardening"
    UBD=$(sysctl -n kernel.unprivileged_bpf_disabled)
    sleep 2
    if [[ "${UBD}" == 0 ]]; then
        bad "monitor caps not testable: kernel.unprivileged_bpf_disabled=0 (map ops need no capability)"
    else
        curl -s 127.0.0.1:9090/metrics | grep -q '^vantage_ue_policy_rx_bps' \
            && ok "monitor (CAP_BPF+DAC_OVERRIDE only, unprivileged_bpf_disabled=${UBD}) reads maps" || bad "monitor caps"
    fi
    systemctl show -p CapabilityBoundingSet,NoNewPrivileges,RestrictAddressFamilies vantage-5g vantage-5g-monitor
    systemctl stop vantage-5g

    hdr "failure: invalid policies.conf -> fails before attach"
    cp /etc/vantage-5g/policies.conf /tmp/pol.bak
    echo "10.99.1.23 1 1" >> /etc/vantage-5g/policies.conf
    systemctl start vantage-5g; echo "rc=$?"
    systemctl status vantage-5g --no-pager | grep -E 'Active|status='
    journalctl -u vantage-5g --no-pager -n 8 | grep -E 'duplicate|nothing was changed'
    [[ "$(systemctl is-failed vantage-5g)" == failed ]] && ! attached && ok "bad policy file: failed, nothing attached" || bad "bad policy file"
    cp /tmp/pol.bak /etc/vantage-5g/policies.conf
    $B unload >/dev/null; systemctl reset-failed vantage-5g

    hdr "failure: setup.sh refuses (ingress qdisc) -> status=3"
    tc qdisc add dev vn6 ingress
    systemctl start vantage-5g; echo "rc=$?"
    systemctl status vantage-5g --no-pager | grep -E 'Active|status='
    systemctl status vantage-5g --no-pager | grep -q 'setup.sh.*status=3' && ok "setup.sh exit 3 visible as unit failure" || bad "setup exit 3"
    tc qdisc show dev vn6 | grep -q '^qdisc ingress' && ok "refusal: other tool's ingress qdisc untouched" || bad "ingress qdisc removed"
    tc qdisc del dev vn6 ingress
    systemctl reset-failed vantage-5g
    systemctl start vantage-5g && attached && ok "start after fixing the cause" || bad "start after fix"

    hdr "stop with a Vantage program left attached elsewhere -> stop fails, pins kept"
    ip link add vx0 type dummy; ip link set dev vx0 xdpgeneric pinned /sys/fs/bpf/vantage/vantage_rx_policer
    systemctl stop vantage-5g; echo "stop rc=$?"; st vantage-5g
    journalctl -u vantage-5g --no-pager -n 12 | grep -E 'still attached|refusing'
    [[ "$(systemctl is-failed vantage-5g)" == failed && -d /sys/fs/bpf/vantage ]] && ok "unload gate: failed + pins kept" || bad "unload gate"
    $B list >/dev/null && ok "CLI still works after failed stop" || bad "CLI after failed stop"
    hdr "uninstall while still attached -> aborts (rc 4), nothing removed"
    "${REPO}/install.sh" uninstall; rc=$?
    [[ $rc -eq 4 && -x /usr/local/lib/vantage-5g/vantage-5G && -f /etc/systemd/system/vantage-5g.service ]] && ok "uninstall aborts while attached" || bad "uninstall abort rc=$rc"
    /usr/local/lib/vantage-5g/detach.sh vx0 >/dev/null; ip link del vx0
    systemctl reset-failed vantage-5g
    systemctl start vantage-5g vantage-5g-monitor && attached && ok "back to running" || bad "restart after gate"
    hdr "VERIFY-L2-8e: monitor restart does not start a stopped vantage-5g (Q8-11)"
    systemctl show -p Wants,Requires,After vantage-5g-monitor
    systemctl show -p Wants,Requires --value vantage-5g-monitor | grep -q 'vantage-5g.service' \
        && bad "monitor still Wants/Requires vantage-5g" || ok "monitor: After= only (no Wants/Requires on vantage-5g)"
    systemctl stop vantage-5g
    systemctl restart vantage-5g-monitor; sleep 3
    [[ "$(systemctl is-active vantage-5g)" == inactive ]] && ! attached && [[ ! -d /sys/fs/bpf/vantage ]] \
        && [[ "$(systemctl is-active vantage-5g-monitor)" == active ]] \
        && ok "main stopped: monitor restart keeps it inactive, nothing loaded/attached" || bad "monitor restart started main"
    systemctl start vantage-5g

    hdr "VERIFY-L2-8e: MONITOR_ARGS change takes effect with the documented restart (Q8-10)"
    cp /etc/vantage-5g/vantage-5g.env /tmp/env.keep8e
    sed -i 's/^MONITOR_ARGS=.*/MONITOR_ARGS=/' /etc/vantage-5g/vantage-5g.env
    systemctl restart vantage-5g-monitor; sleep 2
    ss -ltn | grep -q '0.0.0.0:9090' && echo "(setup) monitor on 0.0.0.0:9090 without --bind"
    sed -i 's/^MONITOR_ARGS=.*/MONITOR_ARGS=--bind 127.0.0.1/' /etc/vantage-5g/vantage-5g.env
    systemctl restart vantage-5g; sleep 2
    ss -ltn | grep -q '0.0.0.0:9090' && echo "[i] restart vantage-5g alone leaves the monitor on 0.0.0.0:9090 (why the docs say restart vantage-5g-monitor)"
    systemctl restart vantage-5g-monitor; sleep 2
    ss -ltn | grep 9090
    ss -ltn | grep -q '127.0.0.1:9090' && ! ss -ltn | grep -q '0.0.0.0:9090' && curl -s 127.0.0.1:9090/metrics | grep -q '^vantage_ue_policy_rx_bps' \
        && ok "after restart vantage-5g-monitor: bind moved 0.0.0.0 -> 127.0.0.1" || bad "MONITOR_ARGS change not applied"
    cp /tmp/env.keep8e /etc/vantage-5g/vantage-5g.env

    hdr "MONITOR_ARGS with quotes (VERIFY-L2-8a): systemd strips them, \$MONITOR_ARGS splits into words"
    cp /etc/vantage-5g/vantage-5g.env /tmp/env.keep
    sed -i 's/^MONITOR_ARGS=.*/MONITOR_ARGS="--bind 127.0.0.1 --port 9091"/' /etc/vantage-5g/vantage-5g.env
    systemctl restart vantage-5g-monitor; sleep 2
    tr '\0' ' ' < /proc/"$(systemctl show -p MainPID --value vantage-5g-monitor)"/cmdline; echo
    ss -ltn | grep -q '127.0.0.1:9091' && curl -s 127.0.0.1:9091/metrics | grep -q '^vantage_ue_policy_rx_bps' \
        && ok "quoted MONITOR_ARGS: listening on 127.0.0.1:9091" || bad "quoted MONITOR_ARGS"
    cp /tmp/env.keep /etc/vantage-5g/vantage-5g.env; systemctl restart vantage-5g-monitor
    echo "RESULT-post pass=$PASS fail=$FAIL"
    ;;
cleanup)
    hdr "uninstall (running) + re-run"
    "${REPO}/install.sh" uninstall; rc=$?
    [[ $rc -eq 0 ]] && ! attached && [[ ! -d /sys/fs/bpf/vantage && ! -e /usr/local/lib/vantage-5g && ! -e /usr/local/bin/vantage-5G \
        && ! -e /etc/systemd/system/vantage-5g.service && -f /etc/vantage-5g/policies.conf ]] \
        && ok "uninstall: stopped, detached, removed, config kept" || bad "uninstall rc=$rc"
    "${REPO}/install.sh" uninstall --purge; rc=$?
    [[ $rc -eq 0 && ! -e /etc/vantage-5g ]] && ok "uninstall re-run + --purge" || bad "uninstall re-run rc=$rc"
    systemctl list-unit-files | grep -E '^vantage-5g' && bad "unit files left" || ok "no unit files left"
    ip netns del ue 2>/dev/null
    rm -f /etc/systemd/network/50-vn6.netdev /etc/systemd/network/50-vn6.network /etc/systemd/network/50-vn6p.network
    ip link del vn6 2>/dev/null; networkctl reload
    ip -br link | grep -E 'vn6|vx0' && bad "test iface left" || ok "test iface removed"
    echo "RESULT-cleanup pass=$PASS fail=$FAIL"
    ;;
*) echo "usage: $0 pre|post|cleanup"; exit 1 ;;
esac
