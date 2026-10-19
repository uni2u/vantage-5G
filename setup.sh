#!/usr/bin/env bash
# setup.sh <iface> [--xdp-mode generic|native]
#
# Attach Vantage-5G RX policer (XDP) and TX pacer (tc-bpf + EDT) to the
# given N6-facing interface on the service node.
#
# Prerequisites (in this order):
#   1. `make build`                         # produces the .o objects
#   2. `sudo ./target/release/vantage-5G load`  # loads & pins the programs
#   3. `sudo ./setup.sh <iface>`            # this script
# Requires a working bpftool (also needed by `make build`). Ubuntu 22.04/24.04:
# install linux-tools-common linux-tools-$(uname -r); the /usr/sbin/bpftool
# wrapper only works with the latter, and neither release ships an installable
# 'bpftool' package.
#
# --xdp-mode generic (default) attaches with `xdpgeneric` (works on any
# driver); --xdp-mode native attaches with `xdpdrv` (driver support needed:
# veth, virtio_net, ixgbe, i40e, ice, mlx5, ...). A Vantage program already
# attached in the other mode is moved to the requested one (the kernel does
# not allow generic and native at the same time, so the RX policer is off for
# the moment between detach and attach). If the attach in the new mode fails,
# the previous mode is restored with the *pinned* program and the script exits
# 3 (see exit codes). Note: on several physical drivers a native
# attach/detach reconfigures the rings (brief link reset).
#
# TX qdisc depends on the number N of TX queues in use
# (/sys/class/net/<if>/queues/tx-*, = real_num_tx_queues):
#   N = 1   root fq
#   N >= 2  root mq (handle 1:) with an fq on every mq class 1:1 .. 1:<M> (hex),
#           M = numtxqueues (`ip -d link`), i.e. also the classes of queues
#           not in use yet, so `ethtool -L` raising the channel count later
#           does not expose a non-fq queue (it would bypass EDT pacing).
# Both keep the per-queue qdisc an fq, which honours skb->tstamp (EDT). The
# tc egress hook (clsact) runs before the TX queue is picked, so each packet
# carries its timestamp into whichever queue's fq it lands in.
#
# Creating root mq temporarily sets the global sysctl net.core.default_qdisc
# to fq (for one tc call; restored right after, also on HUP/INT/TERM). If the
# script is killed (SIGKILL, OOM, power loss) inside that window the value
# stays fq: the original is kept in /run/vantage-5g.default_qdisc, a later
# run warns, and `sudo sysctl -w net.core.default_qdisc=<original>` fixes it.
#
# Idempotent: safe to re-run on an interface that is already attached (e.g.
# after `detach.sh` -> `unload` -> `load` to pick up a new .o). On a re-run no
# step removes a hook before its replacement is in place:
#   - XDP:      `ip -force link set ... xdpgeneric|xdpdrv` = atomic program swap
#               (same mode). A mode switch detaches first (kernel rule).
#   - qdisc N=1: `tc qdisc replace root fq` (same kind -> in-place change)
#   - qdisc N>=2: left alone when root is already mq and every mq class has an
#               fq. Otherwise root mq is (re)created once; see step 2.
#   - clsact:   created only if missing, never deleted here (deleting it would
#               drop the egress filter = TX pacing + DL killswitch off)
#   - tc egress filter: fixed `pref 1 handle 1`, `tc filter replace` = atomic
#               swap. detach.sh removes it (it deletes all egress filters).
# The script ends by checking the resulting attach state and exits non-zero if
# it is not what is expected.
#
# Exit codes:
#   0  attached
#   1  usage / no such interface
#   2  programs not loaded, or bpftool not usable
#   3  refused. Nothing was changed (conflicting XDP program / ingress qdisc /
#      egress filter / qdisc holding handle 1:, missing kernel module, or the
#      XDP attach was rejected by the driver), with one exception: when moving
#      a Vantage program to the other XDP mode fails, the previous mode is
#      restored with the *pinned* program -- its prog id may differ from the
#      one that was attached (a program from an earlier `load`), RX policing
#      was off for a moment, and some physical drivers reset the link.
#   4  post-attach check failed, or a failed XDP mode switch could not be
#      rolled back (no RX policer attached)
#   5  a change step (1-4) failed after something was already changed: the
#      interface may be partially attached. Run `sudo ./detach.sh <iface>`,
#      fix the cause shown, and re-run.
#
# "Is this attached program Vantage's?" is decided by the attached prog id
# (iproute2 prints `id N` on 5.15 and 6.x; names only on 6.x and only with
# CAP_SYS_ADMIN, so names from iproute2 are not used):
#   1. id == id of the pinned program (bpftool prog show pinned), or
#   2. bpftool's kernel name for that id starts with vantage_rx_poli /
#      vantage_tx_pace: a program left attached from an earlier `load`.
# All reads go through ${SUDO}.

set -eu

usage() {
    echo "usage: sudo $0 <iface> [--xdp-mode generic|native]   (e.g. eth0, ens3f0, enp0s3)"
    echo "  --xdp-mode generic  XDP in generic/SKB mode (default; any driver)"
    echo "  --xdp-mode native   XDP in driver mode (xdpdrv; faster, needs driver support)"
}

IFACE=""
XDP_MODE="generic"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --xdp-mode)
            [[ $# -ge 2 ]] || { echo "[-] --xdp-mode needs a value"; usage; exit 1; }
            XDP_MODE="$2"; shift 2 ;;
        --xdp-mode=*) XDP_MODE="${1#*=}"; shift ;;
        -*) echo "[-] unknown option: $1"; usage; exit 1 ;;
        *)
            [[ -z "${IFACE}" ]] || { echo "[-] more than one interface given: ${IFACE} $1"; usage; exit 1; }
            IFACE="$1"; shift ;;
    esac
done
if [[ -z "${IFACE}" ]]; then
    usage
    exit 1
fi
case "${XDP_MODE}" in
    # REQ_KW: keyword `ip link show` prints for that mode; REQ_CMD: `ip link set` keyword.
    generic) REQ_KW="xdpgeneric"; REQ_CMD="xdpgeneric"; OTHER_KW="xdp";        OTHER_CMD="xdpdrv" ;;
    native)  REQ_KW="xdp";        REQ_CMD="xdpdrv";     OTHER_KW="xdpgeneric"; OTHER_CMD="xdpgeneric" ;;
    *) echo "[-] --xdp-mode must be 'generic' or 'native' (got '${XDP_MODE}')"; usage; exit 1 ;;
esac

# Commands (reads included) go through sudo unless already root.
SUDO=""
[[ "$(id -u)" -eq 0 ]] || SUDO="sudo"

PIN_DIR="/sys/fs/bpf/vantage"
PROG_XDP="${PIN_DIR}/vantage_rx_policer"
PROG_TC="${PIN_DIR}/vantage_tx_pacer"

# Our egress filter slot. Fixed so a re-run replaces instead of stacking.
TC_PREF=1
TC_HANDLE=1
# Kernel prog names are truncated to 15 chars (BPF_OBJ_NAME_LEN - 1).
XDP_KNAME="vantage_rx_poli"
TC_KNAME="vantage_tx_pace"
# Handle of the root mq setup.sh creates on multi-queue interfaces. Fixed so
# detach.sh can tell it from the kernel's default mq (handle 0:).
MQ_HANDLE=1

if ! ${SUDO} test -e "${PROG_XDP}" || ! ${SUDO} test -e "${PROG_TC}"; then
    echo "[-] pinned programs not found under ${PIN_DIR}"
    echo "    run 'sudo ./target/release/vantage-5G load' first."
    exit 2
fi

if ! ${SUDO} ip link show dev "${IFACE}" >/dev/null 2>&1; then
    echo "[-] interface ${IFACE} not found"
    exit 1
fi

# TXQ: TX queues in use (real_num_tx_queues; one tx-<n> per queue).
# TXQ_ALL: TX queues allocated (numtxqueues; mq has one class per allocated
# queue, so `ethtool -L` can bring more of them into use later).
count_txq() {
    TXQ="$(find "/sys/class/net/${IFACE}/queues/" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${TXQ}" -ge 1 ]] 2>/dev/null || TXQ=1
    TXQ_ALL="$(${SUDO} ip -d link show dev "${IFACE}" | sed -n 's/.* numtxqueues \([0-9]*\) .*/\1/p' | head -1)"
    [[ "${TXQ_ALL}" -ge "${TXQ}" ]] 2>/dev/null || TXQ_ALL="${TXQ}"
}
count_txq

# Id of pinned prog $1, or "" (bpftool's first line is "<id>: <type> name ...").
pinned_id() { ${SUDO} bpftool prog show pinned "$1" 2>/dev/null | sed -n '1s/^\([0-9]*\):.*/\1/p'; }

PIN_XDP_ID="$(pinned_id "${PROG_XDP}")"
PIN_TC_ID="$(pinned_id "${PROG_TC}")"
if [[ -z "${PIN_XDP_ID}" || -z "${PIN_TC_ID}" ]]; then
    echo "[-] bpftool is not usable: 'bpftool prog show pinned ${PROG_XDP}' failed."
    echo "    setup.sh needs it to identify attached programs (make build needs it too)."
    echo "    Ubuntu 22.04/24.04: sudo apt install linux-tools-common linux-tools-$(uname -r)"
    echo "    (/usr/sbin/bpftool is only a wrapper; there is no installable 'bpftool' package)"
    exit 2
fi

# ---------------------------------------------------------------- helpers ---

# XDP attach-mode keyword of IFACE (xdp = native|xdpgeneric|xdpoffload|xdpmulti) or "".
xdp_mode() {
    ${SUDO} ip link show dev "${IFACE}" | head -1 \
        | grep -oE ' xdp(generic|offload|multi)?( |/)' | tr -d ' /' || true
}

# Id of the (first) XDP program attached to IFACE, or "".
xdp_attached_id() {
    ${SUDO} ip -d link show dev "${IFACE}" \
        | sed -n 's/.*prog\/xdp[a-z]* id \([0-9]*\).*/\1/p' | head -1
}

# Is prog id $1 Vantage's? $2 = pinned id, $3 = kernel name prefix.
is_vantage_id() {
    local id="$1" pin="$2" kname="$3" name
    [[ -n "${id}" ]] || return 1
    [[ "${id}" == "${pin}" ]] && return 0
    name="$(${SUDO} bpftool prog show id "${id}" 2>/dev/null | sed -n '1s/.* name \([^ ]*\) .*/\1/p')"
    [[ -n "${name}" && "${name}" == "${kname}"* ]]
}

# Filter detail lines (the ones carrying "handle") on IFACE egress.
tc_egress_lines() { ${SUDO} tc filter show dev "${IFACE}" egress "$@" | grep 'handle' || true; }

# Is this `tc filter show` detail line a Vantage pacer?
is_vantage_tc_line() {
    is_vantage_id "$(sed -n 's/.* id \([0-9]*\) .*/\1/p' <<<"$1")" "${PIN_TC_ID}" "${TC_KNAME}"
}

qdisc_lines() { ${SUDO} tc qdisc show dev "${IFACE}"; }

# "<kind> <handle>" of the root qdisc, e.g. "mq 1:", "fq 8001:", "noqueue 0:".
root_qdisc() { qdisc_lines | awk '$4 == "root" { print $2 " " $3; exit }'; }

# mq classes 1..TXQ_ALL (as tc prints them: "<major>:<queue hex>", ":<hex>"
# for major 0) under root mq handle $1 whose child qdisc is not fq. A class
# whose child tc does not list (a queue beyond the ones in use, still with its
# default child) counts as not fq. Empty = all fq.
mq_non_fq_children() {
    local maj="${1%:}" fqp q cls out=""
    [[ "${maj}" == 0 ]] && maj=""
    # " <parent> <parent> ... " of every fq that has a parent class.
    fqp=" $(qdisc_lines | awk '$2 == "fq" && $4 == "parent" { printf "%s ", $5 }')"
    for ((q = 1; q <= TXQ_ALL; q++)); do
        cls="${maj}:$(printf '%x' "${q}")"
        [[ "${fqp}" == *" ${cls} "* ]] || out+=" ${cls}"
    done
    echo "${out# }"
}

# Does the TX qdisc already match what setup.sh wants for TXQ queues?
#   1 queue: root fq.  >=2 queues: root mq (any handle) with fq on every class.
qdisc_ok() {
    local r kind
    r="$(root_qdisc)"; kind="${r%% *}"
    if [[ "${TXQ}" -eq 1 ]]; then
        [[ "${kind}" == fq ]]
    else
        [[ "${kind}" == mq && -z "$(mq_non_fq_children "${r#* }")" ]]
    fi
}

# Create root mq ${MQ_HANDLE}: so that its per-queue children are fq from the
# start. mq creates one child per TX queue from net.core.default_qdisc, so when
# that is not already fq it is set to fq for the duration of this single tc
# call and put back right after (and by the EXIT trap). The other way -- mq
# with default children, then one `tc qdisc replace parent <h>:<q> fq` per
# queue -- leaves those queues unpaced in between and deactivates the device
# once per queue. If the sysctl cannot be written (e.g. inside a container)
# the caller falls back to that way.
DQ_RESTORE=""
DQ_MARK="/run/vantage-5g.default_qdisc"
restore_default_qdisc() {
    [[ -n "${DQ_RESTORE}" ]] || return 0
    local want="${DQ_RESTORE}" cur
    DQ_RESTORE=""
    cur="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "${cur}" != fq ]]; then
        # Someone else changed it meanwhile; do not overwrite their value.
        echo "[!] net.core.default_qdisc is now '${cur}' (changed by something else); not restoring '${want}'"
    elif ! ${SUDO} sysctl -q -w "net.core.default_qdisc=${want}" >/dev/null; then
        echo "[!] could not restore net.core.default_qdisc; run: sudo sysctl -w net.core.default_qdisc=${want}"
        return 0   # keep ${DQ_MARK} so the next run warns again
    else
        echo "    net.core.default_qdisc restored to ${want}"
    fi
    ${SUDO} rm -f "${DQ_MARK}"
}
trap restore_default_qdisc EXIT
trap 'restore_default_qdisc; exit 129' HUP
trap 'restore_default_qdisc; exit 130' INT
trap 'restore_default_qdisc; exit 143' TERM

mq_create() {
    local old rc=0
    old="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    # (When it is already fq -- possibly left so by an interrupted run -- it is
    # not touched, and neither is ${DQ_MARK}.)
    if [[ -n "${old}" && "${old}" != fq ]] \
        && echo "${old}" | ${SUDO} tee "${DQ_MARK}" >/dev/null 2>&1; then
        if ${SUDO} sysctl -q -w net.core.default_qdisc=fq >/dev/null 2>&1; then
            DQ_RESTORE="${old}"
            echo "    net.core.default_qdisc ${old} -> fq for the mq creation only"
        else
            ${SUDO} rm -f "${DQ_MARK}" 2>/dev/null || true
        fi
    fi
    ${SUDO} tc qdisc replace dev "${IFACE}" root handle "${MQ_HANDLE}:" mq || rc=$?
    restore_default_qdisc
    return "${rc}"
}

# -------------------------------------------------------------- pre-flight ---

echo "=== 0. pre-flight: look for conflicting hooks (nothing changed yet) ==="
echo "    pinned prog ids: xdp=${PIN_XDP_ID} tc=${PIN_TC_ID}; TX queues: ${TXQ} in use / ${TXQ_ALL} allocated; XDP mode: ${XDP_MODE}"
# A previous run killed between setting and restoring net.core.default_qdisc.
if DQ_OLD="$(cat "${DQ_MARK}" 2>/dev/null)" && [[ -n "${DQ_OLD}" ]]; then
    echo "[!] ${DQ_MARK} exists: an earlier setup.sh was interrupted while net.core.default_qdisc"
    echo "    was temporarily fq (now: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?'), original: ${DQ_OLD})."
    echo "    If it should be ${DQ_OLD}: sudo sysctl -w net.core.default_qdisc=${DQ_OLD}; sudo rm ${DQ_MARK}"
fi
# XDP mode policy (requested mode = --xdp-mode, default generic):
#   - nothing attached                          -> attach in the requested mode
#   - requested mode, Vantage program (re-run / reload) -> atomic replace (-force)
#   - other of generic/native, Vantage program  -> switch: detach that slot,
#                                                  attach in the requested mode
#                                                  (rolled back if that fails)
#   - generic or native, someone else's program -> exit 3
#   - offload / multi                           -> exit 3
MODE="$(xdp_mode)"
AID="$(xdp_attached_id)"
case "${MODE}" in
    "")
        XDP_ACTION="attach" ;;
    "${REQ_KW}"|"${OTHER_KW}")
        if ! is_vantage_id "${AID}" "${PIN_XDP_ID}" "${XDP_KNAME}"; then
            echo "[-] ${IFACE} already has an XDP program in '${MODE}' mode (id ${AID:-?}) that is not Vantage's."
            echo "    Refusing to replace it; detach the other tool's program first."
            exit 3
        fi
        if [[ "${MODE}" == "${REQ_KW}" ]]; then XDP_ACTION="replace"; else XDP_ACTION="switch"; fi
        ;;
    *)
        echo "[-] ${IFACE} has XDP attached in '${MODE}' mode (id ${AID:-?}); setup.sh only manages generic/native."
        echo "    Run 'sudo ./detach.sh ${IFACE}' (or detach that program) and re-run."
        exit 3
        ;;
esac

# A classic `ingress` qdisc occupies the same ffff: slot clsact needs; adding
# clsact would fail half-way (after XDP and the root qdisc are already set).
if qdisc_lines | grep -q '^qdisc ingress '; then
    echo "[-] ${IFACE} has an 'ingress' qdisc; clsact cannot be added next to it."
    echo "    Remove it ('tc qdisc del dev ${IFACE} ingress') if nothing else uses it, and re-run."
    exit 3
fi

# Our fixed filter slot must be empty or already hold the Vantage pacer.
while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if ! is_vantage_tc_line "${line}"; then
        echo "[-] ${IFACE} egress pref ${TC_PREF} holds a non-Vantage filter:"
        echo "      ${line}"
        echo "    Refusing to replace it."
        exit 3
    fi
done <<<"$(tc_egress_lines pref "${TC_PREF}")"

# Root mq needs handle ${MQ_HANDLE}:. If another qdisc on IFACE already uses it
# (e.g. root `prio 1:` / `htb 1:` / `fq 1:`), `tc qdisc replace root handle 1:
# mq` is taken as a change of that qdisc and fails ("must match existing
# qdisc") -- after XDP would already be attached. Refuse up front instead.
if [[ "${TXQ}" -ge 2 ]] && ! qdisc_ok && [[ "$(root_qdisc)" != "mq ${MQ_HANDLE}:" ]]; then
    H1="$(qdisc_lines | awk -v h="${MQ_HANDLE}:" '$3 == h { print $2 " " $3 " " $4 ($4 == "parent" ? " " $5 : ""); exit }')"
    if [[ -n "${H1}" ]]; then
        echo "[-] ${IFACE} has a qdisc using handle ${MQ_HANDLE}: (${H1}); setup.sh needs that handle"
        echo "    for its root mq on this ${TXQ}-queue interface. Remove it if nothing else needs it"
        echo "    (root: 'sudo tc qdisc del dev ${IFACE} root') and re-run."
        exit 3
    fi
fi

# Kernel modules the later steps need, checked while nothing is changed yet.
# Skipped where modprobe or the module tree is not available (containers);
# a failure there surfaces as exit 5.
kmod_missing() {
    local m out=""
    command -v modprobe >/dev/null 2>&1 && [[ -d "/lib/modules/$(uname -r)" ]] || return 0
    for m in "$@"; do
        [[ -d "/sys/module/${m}" ]] || modprobe -n -q "${m}" 2>/dev/null || out+=" ${m}"
    done
    echo "${out# }"
}
NEED_MODS="sch_fq cls_bpf"
qdisc_lines | grep -q '^qdisc clsact ' || NEED_MODS+=" sch_ingress"
# shellcheck disable=SC2086
MISSING="$(kmod_missing ${NEED_MODS})"
if [[ -n "${MISSING}" ]]; then
    echo "[-] kernel module(s) not available: ${MISSING} (needed for fq / clsact / tc-bpf)."
    echo "    Install the kernel's extra modules (Ubuntu: linux-modules-extra-$(uname -r)) and re-run."
    exit 3
fi

# ------------------------------------------------------------------ attach ---

# From here on a failing command leaves a partial state: exit 5 (not the raw
# tc/ip status, whose 1/2 would read as "usage"/"not loaded").
partial_fail() {
    # In a $(...) subshell just propagate; the caller's ERR trap reports once.
    [[ "${BASH_SUBSHELL}" -eq 0 ]] || exit 5
    echo
    echo "[-] step failed (status $1, setup.sh line $2) after ${IFACE} was already changed."
    echo "    ${IFACE} may be partially attached. Run 'sudo ./detach.sh ${IFACE}',"
    echo "    fix the cause above, and re-run setup.sh."
    exit 5
}
set -E
trap 'partial_fail $? ${LINENO}' ERR

# XDP goes first: it is the only step that can be refused by the driver
# (native mode), and nothing else has been changed at that point.
echo "=== 1. attach XDP RX policer (${XDP_MODE} mode: ip link ${REQ_CMD}; ${XDP_ACTION}) ==="
xdp_attach_failed() {   # $1 = ip's output
    echo "[-] XDP attach in ${XDP_MODE} mode failed: $1"
    if [[ "${XDP_MODE}" == native ]]; then
        local drv
        drv="$(basename "$(readlink -f "/sys/class/net/${IFACE}/device/driver" 2>/dev/null)" 2>/dev/null || true)"
        echo "    The driver of ${IFACE} (${drv:-virtual device}) does not accept native XDP"
        echo "    (no XDP support, or a driver limit such as MTU / queue count)."
        echo "    Use '--xdp-mode generic' (the default)."
    fi
    return 3    # nothing was changed (or the previous mode was restored)
}
if [[ "${XDP_ACTION}" == "switch" ]]; then
    echo "    moving the Vantage program (id ${AID}) from '${MODE}' to ${XDP_MODE} mode;"
    echo "    the kernel allows only one of them, so RX policing pauses until the attach below"
    ${SUDO} ip link set dev "${IFACE}" "${OTHER_CMD}" off
    RC=0; OUT="$(${SUDO} ip link set dev "${IFACE}" "${REQ_CMD}" pinned "${PROG_XDP}" 2>&1)" || RC=$?
    if [[ "${RC}" -ne 0 ]]; then
        xdp_attach_failed "${OUT}" || RC=$?
        echo "    restoring the previous attach (${OTHER_CMD}, pinned ${PROG_XDP})"
        if ! ${SUDO} ip link set dev "${IFACE}" "${OTHER_CMD}" pinned "${PROG_XDP}"; then
            echo "[-] restore failed: ${IFACE} has NO XDP RX policer now."
            exit 4
        fi
        exit "${RC}"
    fi
else
    # -force: atomic replace if our program is already attached (re-run / reload).
    RC=0; OUT="$(${SUDO} ip -force link set dev "${IFACE}" "${REQ_CMD}" pinned "${PROG_XDP}" 2>&1)" || RC=$?
    if [[ "${RC}" -ne 0 ]]; then
        xdp_attach_failed "${OUT}" || RC=$?
        exit "${RC}"
    fi
fi

# Re-read the queue counts: a driver may change them on XDP attach.
count_txq

if [[ "${TXQ}" -eq 1 ]]; then
    echo "=== 2. root qdisc -> fq  (1 TX queue; required for EDT / skb->tstamp pacing) ==="
    ${SUDO} tc qdisc replace dev "${IFACE}" root fq
else
    echo "=== 2. root qdisc -> mq ${MQ_HANDLE}: + fq per TX queue (${TXQ} in use, ${TXQ_ALL} mq classes; EDT needs fq) ==="
    if qdisc_ok; then
        echo "    root $(root_qdisc) with fq on all ${TXQ_ALL} mq classes already in place (kept, no change)"
    else
        ROOT_Q="$(root_qdisc)"
        if [[ "${ROOT_Q}" != "mq ${MQ_HANDLE}:" ]]; then
            # One graft of the root: packets queued in the old root qdisc are
            # dropped and the device is briefly deactivated (see notes).
            echo "    current root: ${ROOT_Q:-none}; creating root mq ${MQ_HANDLE}:"
            mq_create
        fi
        NONFQ="$(mq_non_fq_children "${MQ_HANDLE}:")"
        if [[ -n "${NONFQ}" ]]; then
            echo "    setting fq on mq classes: ${NONFQ}"
            CMDS=""
            for c in ${NONFQ}; do CMDS+="qdisc replace dev ${IFACE} parent ${c} fq"$'\n'; done
            ${SUDO} tc -batch - <<<"${CMDS}"
        fi
    fi
fi

echo "=== 3. clsact qdisc for tc-bpf hook (create if missing, never deleted here) ==="
if qdisc_lines | grep -q '^qdisc clsact '; then
    echo "    clsact already present (kept, existing filters untouched)"
else
    ${SUDO} tc qdisc add dev "${IFACE}" clsact
fi

echo "=== 4. attach tc-bpf TX pacer on egress (pref ${TC_PREF} handle ${TC_HANDLE}, replace) ==="
${SUDO} tc filter replace dev "${IFACE}" egress protocol all pref "${TC_PREF}" handle "${TC_HANDLE}" \
    bpf da pinned "${PROG_TC}"

# Migration: setup.sh before this version used `tc filter add` without pref, so
# a pacer could sit at an auto pref (49152, ...) next to ours. A second pacer
# advances the per-UE EDT slot twice per packet. Remove any Vantage pacer
# outside our slot -- only after ours is in place, so there is no gap.
STALE=""
while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    p="$(sed -n 's/.* pref \([0-9]*\) .*/\1/p' <<<"${line}")"
    [[ -n "${p}" && "${p}" != "${TC_PREF}" ]] || continue
    is_vantage_tc_line "${line}" && STALE="${STALE} ${p}"
done <<<"$(tc_egress_lines)"
for p in $(tr ' ' '\n' <<<"${STALE}" | sort -u); do
    echo "    removing stale Vantage pacer at egress pref ${p}"
    ${SUDO} tc filter del dev "${IFACE}" egress pref "${p}"
done

# ------------------------------------------------------------------ verify ---

echo "=== 5. verify attach state ==="
ERR=0
fail() { echo "[-] verify: $*"; ERR=1; }

MODE="$(xdp_mode)"
AID="$(xdp_attached_id)"
[[ "${MODE}" == "${REQ_KW}" ]] || fail "XDP mode is '${MODE:-none}', expected ${REQ_KW} (${XDP_MODE})"
[[ "${AID}" == "${PIN_XDP_ID}" ]] || fail "XDP prog id ${AID:-none} != pinned ${PROG_XDP} id ${PIN_XDP_ID}"

QDISCS="$(qdisc_lines)"
ROOT_Q="$(root_qdisc)"
if [[ "${TXQ}" -eq 1 ]]; then
    [[ "${ROOT_Q%% *}" == fq ]] || fail "root qdisc is not fq: ${ROOT_Q:-none}"
    QDESC="root fq"
elif [[ "${ROOT_Q%% *}" != mq ]]; then
    fail "${IFACE} has ${TXQ} TX queues but root qdisc is not mq: ${ROOT_Q:-none}"
else
    NONFQ="$(mq_non_fq_children "${ROOT_Q#* }")"
    [[ -z "${NONFQ}" ]] || fail "mq classes without fq under root ${ROOT_Q}: ${NONFQ}"
    QDESC="root ${ROOT_Q} + fq on all ${TXQ_ALL} mq classes (${TXQ} TX queues in use)"
fi
grep -q '^qdisc clsact ' <<<"${QDISCS}" || fail "clsact qdisc missing"

OURS=""; OTHERS=""
while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if is_vantage_tc_line "${line}"; then OURS+="${line}"$'\n'; else OTHERS+="${line}"$'\n'; fi
done <<<"$(tc_egress_lines)"
N="$(grep -c . <<<"${OURS%$'\n'}" || true)"
[[ -n "${OURS}" ]] || N=0
if [[ "${N}" -ne 1 ]]; then
    fail "expected exactly 1 Vantage egress filter, found ${N}"
else
    grep -q "pref ${TC_PREF} .*handle 0x${TC_HANDLE} " <<<"${OURS}" \
        || fail "Vantage egress filter not at pref ${TC_PREF} handle ${TC_HANDLE}: ${OURS}"
    grep -q 'direct-action' <<<"${OURS}" || fail "Vantage egress filter is not direct-action"
    grep -q " id ${PIN_TC_ID} " <<<"${OURS}" || fail "egress filter prog id != pinned ${PROG_TC} id ${PIN_TC_ID}"
fi
# Other egress filters are not ours to touch, but a direct-action filter at a
# lower pref can return before the pacer runs. Warn.
if [[ -n "${OTHERS}" ]]; then
    echo "[!] other egress filters on ${IFACE} (left alone; check they don't bypass the pacer):"
    printf '%s' "${OTHERS}" | sed 's/^/      /'
fi

if [[ "${ERR}" -ne 0 ]]; then
    echo
    echo "[-] Vantage-5G attach on ${IFACE} is NOT in the expected state (see above)."
    echo "    Current state:"
    ${SUDO} ip -d link show dev "${IFACE}" | sed 's/^/      /'
    sed 's/^/      /' <<<"${QDISCS}"
    ${SUDO} tc filter show dev "${IFACE}" egress | sed 's/^/      /'
    exit 4
fi

echo
echo "[+] Vantage-5G attached to ${IFACE}."
echo "    - RX policer (XDP ${XDP_MODE}, id ${AID}): ${PROG_XDP}"
echo "    - TX pacer  (tc egress pref ${TC_PREF}): ${PROG_TC}"
echo "    - TX qdisc  ${QDESC}"
echo
echo "Next:"
echo "    sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20"
echo "    sudo ./target/release/vantage-5G monitor"
echo
echo "To detach:  sudo ./detach.sh ${IFACE}"
