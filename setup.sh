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
# Exit codes: 1 usage, 2 programs not loaded, 3 conflicting hook found
# (nothing was changed), 4 post-attach check failed, other = command failure.
#
# How "is this attached program Vantage's?" is decided (iproute2 5.15 /
# Ubuntu 22.04 prints only `id N tag ...`, no prog name; and without
# CAP_SYS_ADMIN no iproute2 prints the name), by attached prog id:
#   1. id == id of the pinned program  (pinned ids from `bpftool prog show
#      pinned`, or -- if bpftool is not usable -- from a short-lived dummy
#      probe interface the pinned programs are attached to and read back)
#   2. else the kernel prog name of that id starts with vantage_rx_poli /
#      vantage_tx_pace (from `bpftool prog show id N`, or from iproute2 output
#      when it prints names). This catches a program left attached from an
#      earlier `load` (same name, different id).
#   3. the attached program's tag (hash of its instructions, printed by
#      iproute2 5.15 and 6.x) equals the pinned program's tag: same .o loaded
#      again, e.g. `unload`/`load` while attached, without bpftool on 22.04.
#   4. tc only: the cls_bpf label tc stored at attach time
#      (`vantage_tx_pacer:[*fsobj]`, printed by 5.15 and 6.x).
# If none of these can be evaluated, an occupied slot counts as "not ours"
# (exit 3, nothing changed).
# All reads go through ${SUDO}: iproute2 needs CAP_SYS_ADMIN to resolve names.

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
# Kernel prog names are truncated to 15 chars (BPF_OBJ_NAME_LEN - 1);
# that is what iproute2 6.x prints. bpftool prints the full BTF name.
XDP_KNAME="vantage_rx_poli"
TC_KNAME="vantage_tx_pace"
TC_LABEL="vantage_tx_pacer:["

if ! ${SUDO} test -e "${PROG_XDP}" || ! ${SUDO} test -e "${PROG_TC}"; then
    echo "[-] pinned programs not found under ${PIN_DIR}"
    echo "    run 'sudo ./target/release/vantage-5G load' first."
    exit 2
fi

if ! ${SUDO} ip link show dev "${IFACE}" >/dev/null 2>&1; then
    echo "[-] interface ${IFACE} not found"
    exit 1
fi

# ---------------------------------------------------------------- helpers ---

# XDP attach-mode keyword of IFACE (xdp|xdpgeneric|xdpoffload|xdpmulti) or "".
xdp_mode() {
    ${SUDO} ip link show dev "${IFACE}" | head -1 \
        | grep -oE ' xdp(generic|offload|multi)?( |/)' | tr -d ' /' || true
}

# Tag of the (first) XDP program attached to IFACE, or "".
xdp_attached_tag() {
    ${SUDO} ip -d link show dev "${IFACE}" \
        | sed -n 's/.*prog\/xdp[a-z]* id [0-9]* .*tag \([0-9a-f]*\).*/\1/p' | head -1
}

# Id of the (first) XDP program attached to IFACE, or "".
xdp_attached_id() {
    ${SUDO} ip -d link show dev "${IFACE}" \
        | sed -n 's/.*prog\/xdp[a-z]* id \([0-9]*\).*/\1/p' | head -1
}

# Name iproute2 printed for the attached XDP program ("" on 5.15 / no caps).
xdp_attached_name() {
    ${SUDO} ip -d link show dev "${IFACE}" \
        | sed -n 's/.*prog\/xdp[a-z]* id [0-9]* name \([^ ]*\).*/\1/p' | head -1
}

HAVE_BPFTOOL=0
if command -v bpftool >/dev/null 2>&1 \
        && ${SUDO} bpftool prog show pinned "${PROG_XDP}" >/dev/null 2>&1; then
    HAVE_BPFTOOL=1   # (Ubuntu's /usr/sbin/bpftool wrapper fails without linux-tools-$(uname -r))
fi

# Kernel name of prog id $1 via bpftool, or "".
prog_name_by_id() {
    [[ "${HAVE_BPFTOOL}" -eq 1 && -n "$1" ]] || return 0
    ${SUDO} bpftool prog show id "$1" 2>/dev/null | head -1 \
        | sed -n 's/.* name \([^ ]*\) .*/\1/p'
}

# Pinned program ids. bpftool first; otherwise attach the pins to a temporary
# dummy interface and read the ids back with iproute2 (works on 5.15).
PIN_XDP_ID=""; PIN_TC_ID=""; PIN_XDP_TAG=""; PIN_TC_TAG=""; ID_SRC="none"
PROBE="vtprobe$$"
cleanup_probe() { ${SUDO} ip link del "${PROBE}" >/dev/null 2>&1 || true; }
if [[ "${HAVE_BPFTOOL}" -eq 1 ]]; then
    PIN_XDP_ID="$(${SUDO} bpftool prog show pinned "${PROG_XDP}" | head -1 | sed -n 's/^\([0-9]*\):.*/\1/p')"
    PIN_TC_ID="$(${SUDO} bpftool prog show pinned "${PROG_TC}" | head -1 | sed -n 's/^\([0-9]*\):.*/\1/p')"
    PIN_XDP_TAG="$(${SUDO} bpftool prog show pinned "${PROG_XDP}" | head -1 | sed -n 's/.* tag \([0-9a-f]*\).*/\1/p')"
    PIN_TC_TAG="$(${SUDO} bpftool prog show pinned "${PROG_TC}" | head -1 | sed -n 's/.* tag \([0-9a-f]*\).*/\1/p')"
    ID_SRC="bpftool"
else
    trap cleanup_probe EXIT
    if ${SUDO} ip link add "${PROBE}" type dummy >/dev/null 2>&1 \
            && ${SUDO} ip link set dev "${PROBE}" xdpgeneric pinned "${PROG_XDP}" >/dev/null 2>&1 \
            && ${SUDO} tc qdisc add dev "${PROBE}" clsact >/dev/null 2>&1 \
            && ${SUDO} tc filter add dev "${PROBE}" egress pref 1 handle 1 bpf da pinned "${PROG_TC}" >/dev/null 2>&1; then
        PIN_XDP_ID="$(${SUDO} ip -d link show dev "${PROBE}" | sed -n 's/.*prog\/xdp[a-z]* id \([0-9]*\).*/\1/p' | head -1)"
        PIN_TC_ID="$(${SUDO} tc filter show dev "${PROBE}" egress | sed -n 's/.* id \([0-9]*\) .*/\1/p' | head -1)"
        PIN_XDP_TAG="$(${SUDO} ip -d link show dev "${PROBE}" | sed -n 's/.*prog\/xdp[a-z]* id [0-9]* .*tag \([0-9a-f]*\).*/\1/p' | head -1)"
        PIN_TC_TAG="$(${SUDO} tc filter show dev "${PROBE}" egress | sed -n 's/.* tag \([0-9a-f]*\).*/\1/p' | head -1)"
        ID_SRC="probe"
    fi
    cleanup_probe
    trap - EXIT
    if [[ -z "${PIN_XDP_ID}" || -z "${PIN_TC_ID}" ]]; then
        PIN_XDP_ID=""; PIN_TC_ID=""; PIN_XDP_TAG=""; PIN_TC_TAG=""; ID_SRC="none"
    fi
fi

# Is attached XDP prog id $1 (iproute2 name $2, tag $3; may be "") Vantage's?
is_vantage_xdp() {
    local id="$1" name="$2" tag="${3:-}"
    [[ -n "${id}" ]] || return 1
    [[ -n "${PIN_XDP_ID}" && "${id}" == "${PIN_XDP_ID}" ]] && return 0
    [[ -n "${PIN_XDP_TAG}" && "${tag}" == "${PIN_XDP_TAG}" ]] && return 0
    [[ -z "${name}" ]] && name="$(prog_name_by_id "${id}")"
    [[ "${name}" == "${XDP_KNAME}"* ]]
}

# Is this `tc filter show` detail line a Vantage pacer?
is_vantage_tc_line() {
    local line="$1" id name
    id="$(sed -n 's/.* id \([0-9]*\) .*/\1/p' <<<"${line}")"
    [[ -n "${id}" && -n "${PIN_TC_ID}" && "${id}" == "${PIN_TC_ID}" ]] && return 0
    [[ -n "${PIN_TC_TAG}" && "${line}" == *" tag ${PIN_TC_TAG}"* ]] && return 0
    [[ "${line}" == *"${TC_LABEL}"* ]] && return 0
    name="$(sed -n 's/.* name \([^ ]*\) .*/\1/p' <<<"${line}")"
    [[ -z "${name}" ]] && name="$(prog_name_by_id "${id}")"
    [[ -n "${name}" && "${name}" == "${TC_KNAME}"* ]]
}

# Filter detail lines (the ones carrying "handle") on IFACE egress.
tc_egress_lines() { ${SUDO} tc filter show dev "${IFACE}" egress "$@" | grep 'handle' || true; }

# -------------------------------------------------------------- pre-flight ---

echo "=== 0. pre-flight: look for conflicting hooks (nothing changed yet) ==="
echo "    pinned prog ids: xdp=${PIN_XDP_ID:-?} tc=${PIN_TC_ID:-?} (source: ${ID_SRC})"
# XDP mode policy:
#   - nothing attached                 -> attach in generic mode
#   - generic, Vantage program (re-run / reload) -> atomic replace with -force
#   - generic, someone else's program, or ownership undeterminable -> exit 3
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
        if ! is_vantage_xdp "${AID}" "$(xdp_attached_name)" "$(xdp_attached_tag)"; then
            echo "[-] ${IFACE} already has a generic-mode XDP program (id ${AID:-?}, tag $(xdp_attached_tag))"
            echo "    that is not the pinned Vantage program (id ${PIN_XDP_ID:-?}, tag ${PIN_XDP_TAG:-?})"
            echo "    and could not be identified as an older Vantage load (name not available:"
            echo "    iproute2 < 6 prints no names; install bpftool to resolve names by id)."
            echo "    Refusing to replace it. If it is Vantage (e.g. after loading a new .o),"
            echo "    run 'sudo ./detach.sh ${IFACE}' and re-run; otherwise detach the other tool's program."
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
        echo "[-] ${IFACE} egress pref ${TC_PREF} holds a non-Vantage (or unidentifiable) filter:"
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
if [[ -n "${PIN_XDP_ID}" ]]; then
    [[ "${AID}" == "${PIN_XDP_ID}" ]] || fail "XDP prog id ${AID:-none} != pinned ${PROG_XDP} id ${PIN_XDP_ID}"
else
    is_vantage_xdp "${AID}" "$(xdp_attached_name)" "$(xdp_attached_tag)" \
        || echo "    [!] XDP prog id ${AID:-none}: identity not verifiable (no bpftool, probe failed)"
    [[ -n "${AID}" ]] || fail "no XDP program attached"
fi

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
    if [[ -n "${PIN_TC_ID}" ]]; then
        grep -q " id ${PIN_TC_ID} " <<<"${OURS}" || fail "egress filter prog id != pinned ${PROG_TC} id ${PIN_TC_ID}"
    fi
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
