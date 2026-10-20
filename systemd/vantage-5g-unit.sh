#!/usr/bin/env bash
# vantage-5g-unit.sh preflight|record|detach -- helper for vantage-5g.service
# (installed to /usr/local/lib/vantage-5g/ by install.sh; not meant to be run by hand).
#
#   preflight  mount bpffs if missing, validate the env file values, wait up to
#              IFACE_WAIT_SEC (clamped to IFACE_WAIT_MAX, default 240) for IFACE
#              to exist, check the policy file.
#              exit 1 config error, 6 IFACE did not appear in time
#   record     store IFACE in $RUNTIME_DIRECTORY (after a successful attach)
#   detach     detach.sh on the recorded interface (falls back to IFACE): the
#              env file may have been edited since the start, and detaching the
#              new interface would leave the old one attached.
#              Exit code = detach.sh's (the unit ignores it; `unload` decides).

set -u
LIB=/usr/local/lib/vantage-5g
ENV_FILE=/etc/vantage-5g/vantage-5g.env
POLICY_FILE=/etc/vantage-5g/policies.conf
STATE="${RUNTIME_DIRECTORY:-/run/vantage-5g}/iface"

valid_ifname() { [[ "$1" =~ ^[A-Za-z0-9_.:@-]{1,15}$ ]]; }

case "${1:-}" in
preflight)
    if ! mountpoint -q /sys/fs/bpf; then
        echo "[i] /sys/fs/bpf not mounted; mounting bpffs"
        mount -t bpf bpf /sys/fs/bpf || { echo "[-] cannot mount bpffs on /sys/fs/bpf"; exit 1; }
    fi
    IFACE="${IFACE:-}"
    if [[ -z "${IFACE}" ]]; then
        echo "[-] IFACE is not set in ${ENV_FILE} (the N6-facing interface, e.g. IFACE=ens3f0)"
        exit 1
    fi
    valid_ifname "${IFACE}" || { echo "[-] IFACE='${IFACE}' is not a valid interface name"; exit 1; }
    # The unit passes ${XDP_MODE} to setup.sh as exactly one argument, so an
    # empty value (XDP_MODE= in the env file) would reach setup.sh as '' and
    # fail there after load/apply. Reject it here; the unit's default
    # (Environment=XDP_MODE=generic) applies only when the line is absent.
    case "${XDP_MODE-}" in
        generic|native) ;;
        "") echo "[-] XDP_MODE is empty in ${ENV_FILE}: set generic or native (or delete the line for the default, generic)"; exit 1 ;;
        *) echo "[-] XDP_MODE='${XDP_MODE}' in ${ENV_FILE} must be generic or native"; exit 1 ;;
    esac
    WAIT="${IFACE_WAIT_SEC:-90}"
    [[ "${WAIT}" =~ ^[0-9]+$ ]] || { echo "[-] IFACE_WAIT_SEC='${WAIT}' is not a number of seconds"; exit 1; }
    # The whole start (this wait + load + apply + setup.sh) must finish within
    # the unit's TimeoutStartSec=300, or systemd kills it ("timeout" instead of
    # the documented exit 6). Clamp the wait to IFACE_WAIT_MAX (default 240);
    # raising TimeoutStartSec with `systemctl edit vantage-5g` should come with
    # Environment=IFACE_WAIT_MAX=<that minus ~60> in the same drop-in.
    MAX="${IFACE_WAIT_MAX:-240}"
    [[ "${MAX}" =~ ^[0-9]+$ ]] || MAX=240
    if (( 10#${WAIT} > 10#${MAX} )); then
        echo "[!] IFACE_WAIT_SEC=${WAIT} exceeds ${MAX}s (TimeoutStartSec=300 budget); waiting ${MAX}s"
        WAIT="${MAX}"
    fi
    if [[ ! -e "/sys/class/net/${IFACE}" ]]; then
        echo "[i] waiting up to ${WAIT}s for interface ${IFACE}"
        for ((i = 0; i < WAIT; i++)); do
            sleep 1
            [[ -e "/sys/class/net/${IFACE}" ]] && break
        done
        if [[ ! -e "/sys/class/net/${IFACE}" ]]; then
            echo "[-] interface ${IFACE} did not appear within ${WAIT}s"
            exit 6
        fi
        echo "[i] ${IFACE} appeared after ~$((i + 1))s"
    fi
    if [[ ! -r "${POLICY_FILE}" ]]; then
        echo "[-] ${POLICY_FILE} not found (it may be empty or comments only; see policies.conf.example)"
        exit 1
    fi
    exit 0
    ;;
record)
    printf '%s\n' "${IFACE}" > "${STATE}"
    ;;
detach)
    IF="$(cat "${STATE}" 2>/dev/null || true)"
    valid_ifname "${IF}" || IF="${IFACE:-}"
    if [[ -z "${IF}" ]]; then
        echo "[i] no interface recorded or configured; nothing to detach"
        exit 0
    fi
    [[ "${IF}" == "${IFACE:-}" ]] || echo "[i] detaching ${IF} (attached at start; IFACE is now '${IFACE:-}')"
    exec "${LIB}/detach.sh" "${IF}"
    ;;
*)
    echo "usage: $0 preflight|record|detach"
    exit 1
    ;;
esac
