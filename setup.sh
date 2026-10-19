#!/usr/bin/env bash
# setup.sh <iface>
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
# Idempotent: safe to re-run on an interface that is already attached (e.g.
# after `detach.sh` -> `unload` -> `load` to pick up a new .o). No step removes
# a hook before its replacement is in place:
#   - root fq:  `tc qdisc replace` (same kind -> in-place change, no flush)
#   - clsact:   created only if missing, never deleted here (deleting it would
#               drop the egress filter = TX pacing + DL killswitch off)
#   - XDP:      `ip -force link set ... xdpgeneric` = atomic program swap
#   - tc egress filter: fixed `pref 1 handle 1`, `tc filter replace` = atomic
#               swap. detach.sh removes it (it deletes all egress filters).
# The script ends by checking the resulting attach state and exits non-zero if
# it is not what is expected.
#
# Exit codes: 1 usage / no such iface, 2 programs not loaded or bpftool not
# usable, 3 conflicting hook found (nothing was changed), 4 post-attach check
# failed, other = command failure.
#
# "Is this attached program Vantage's?" is decided by the attached prog id
# (iproute2 prints `id N` on 5.15 and 6.x; names only on 6.x and only with
# CAP_SYS_ADMIN, so names from iproute2 are not used):
#   1. id == id of the pinned program (bpftool prog show pinned), or
#   2. bpftool's kernel name for that id starts with vantage_rx_poli /
#      vantage_tx_pace: a program left attached from an earlier `load`.
# All reads go through ${SUDO}.

set -eu

IFACE="${1:-}"
if [[ -z "${IFACE}" ]]; then
    echo "usage: sudo $0 <iface>   (e.g. eth0, ens3f0, enp0s3)"
    exit 1
fi

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

if ! ${SUDO} test -e "${PROG_XDP}" || ! ${SUDO} test -e "${PROG_TC}"; then
    echo "[-] pinned programs not found under ${PIN_DIR}"
    echo "    run 'sudo ./target/release/vantage-5G load' first."
    exit 2
fi

if ! ${SUDO} ip link show dev "${IFACE}" >/dev/null 2>&1; then
    echo "[-] interface ${IFACE} not found"
    exit 1
fi

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

# XDP attach-mode keyword of IFACE (xdp|xdpgeneric|xdpoffload|xdpmulti) or "".
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

# -------------------------------------------------------------- pre-flight ---

echo "=== 0. pre-flight: look for conflicting hooks (nothing changed yet) ==="
echo "    pinned prog ids: xdp=${PIN_XDP_ID} tc=${PIN_TC_ID}"
# XDP mode policy:
#   - nothing attached                 -> attach in generic mode
#   - generic, Vantage program (re-run / reload) -> atomic replace with -force
#   - generic, someone else's program  -> exit 3
#   - native / offload / multi (any program, including ours attached by hand
#     with xdpdrv)                      -> refuse (exit 3). The kernel forbids
#     generic and native on the same device at the same time, and silently
#     replacing a native program could remove another tool's datapath. The
#     operator decides: `sudo ./detach.sh <iface>` (removes generic + native)
#     or `ip link set dev <iface> xdp off`, then re-run this script.
MODE="$(xdp_mode)"
case "${MODE}" in
    "")  ;;
    xdpgeneric)
        AID="$(xdp_attached_id)"
        if ! is_vantage_id "${AID}" "${PIN_XDP_ID}" "${XDP_KNAME}"; then
            echo "[-] ${IFACE} already has a generic-mode XDP program (id ${AID:-?}) that is not Vantage's."
            echo "    Refusing to replace it; detach the other tool's program first."
            exit 3
        fi
        ;;
    *)
        echo "[-] ${IFACE} has an XDP program attached in '${MODE}' (native/offload) mode (id $(xdp_attached_id))."
        echo "    setup.sh attaches in generic mode; the kernel does not allow both."
        echo "    Run 'sudo ./detach.sh ${IFACE}' (or 'ip link set dev ${IFACE} xdp off') and re-run."
        exit 3
        ;;
esac

# A classic `ingress` qdisc occupies the same ffff: slot clsact needs; adding
# clsact would fail half-way (after root fq is already set).
if ${SUDO} tc qdisc show dev "${IFACE}" | grep -q '^qdisc ingress '; then
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

# ------------------------------------------------------------------ attach ---

echo "=== 1. root qdisc -> fq  (required for EDT / skb->tstamp pacing) ==="
${SUDO} tc qdisc replace dev "${IFACE}" root fq

echo "=== 2. clsact qdisc for tc-bpf hook (create if missing, never deleted here) ==="
if ${SUDO} tc qdisc show dev "${IFACE}" | grep -q '^qdisc clsact '; then
    echo "    clsact already present (kept, existing filters untouched)"
else
    ${SUDO} tc qdisc add dev "${IFACE}" clsact
fi

echo "=== 3. attach XDP RX policer (generic mode: broadest compatibility) ==="
# -force: atomic replace if our program is already attached (re-run / reload).
${SUDO} ip -force link set dev "${IFACE}" xdpgeneric pinned "${PROG_XDP}"

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
[[ "${MODE}" == "xdpgeneric" ]] || fail "XDP mode is '${MODE:-none}', expected xdpgeneric"
[[ "${AID}" == "${PIN_XDP_ID}" ]] || fail "XDP prog id ${AID:-none} != pinned ${PROG_XDP} id ${PIN_XDP_ID}"

QDISCS="$(${SUDO} tc qdisc show dev "${IFACE}")"
grep -q '^qdisc fq [0-9a-f]*: root' <<<"${QDISCS}" \
    || fail "root qdisc is not fq: $(grep ' root' <<<"${QDISCS}" | head -1)"
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
    ${SUDO} tc qdisc show dev "${IFACE}" | sed 's/^/      /'
    ${SUDO} tc filter show dev "${IFACE}" egress | sed 's/^/      /'
    exit 4
fi

echo
echo "[+] Vantage-5G attached to ${IFACE}."
echo "    - RX policer (XDP generic, id ${AID}): ${PROG_XDP}"
echo "    - TX pacer  (tc egress pref ${TC_PREF}): ${PROG_TC}"
echo
echo "Next:"
echo "    sudo ./target/release/vantage-5G set --ue-ip 10.45.1.23 --rx-mbps 10 --tx-mbps 20"
echo "    sudo ./target/release/vantage-5G monitor"
echo
echo "To detach:  sudo ./detach.sh ${IFACE}"
