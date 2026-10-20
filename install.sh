#!/usr/bin/env bash
# install.sh -- install / remove Vantage-5G as systemd services.
#
#   make build                          # as a normal user, first
#   sudo ./install.sh install [--enable]
#   sudo ./install.sh uninstall [--purge] [--force]
#
# install (re-run = upgrade; safe while the service runs):
#   /usr/local/lib/vantage-5g/   vantage-5G, vantage_rx_policer.o, vantage_tx_pacer.o,
#                                setup.sh, detach.sh, vantage-5g-unit.sh
#   /usr/local/bin/vantage-5G    symlink to the binary above
#   /etc/systemd/system/         vantage-5g.service, vantage-5g-monitor.service
#                                (overwritten: customise with `systemctl edit`)
#   /etc/vantage-5g/             vantage-5g.env, policies.conf -- created from the
#                                examples only if missing, never overwritten;
#                                the *.example copies next to them are refreshed
#   Files are replaced one by one by rename (a running monitor/setup keeps its
#   old copy); .o files and scripts first, the binary last, temp files removed
#   on failure/interrupt. Not atomic as a set: re-run after an interrupted
#   install before restarting the service.
#   A running vantage-5g.service is NOT restarted (that re-attaches = short
#   shaping gap); the new binary/.o take effect on `systemctl restart vantage-5g`.
#   --enable  also `systemctl enable` both units (start at boot; not started now)
#
# uninstall (re-run safe):
#   stops both units (stop = detach.sh + unload), removes leftover pins with
#   `vantage-5G unload`, disables and removes the units, the symlink and
#   /usr/local/lib/vantage-5g. Aborts with files left in place if a Vantage
#   program is still attached (stop/unload refused) -- unless --force.
#   /etc/vantage-5g is kept unless --purge.
#
# Exit codes: 0 ok, 1 usage / not root, 2 build artifacts missing,
#             4 uninstall aborted (still attached; nothing removed)
#             5 uninstall finished, but pins are left under /sys/fs/bpf/vantage
#               and no vantage-5G binary was available to remove them (e.g.
#               after an earlier --force); clean up with a repository build:
#               sudo <repo>/detach.sh <iface>; sudo <repo>/target/release/vantage-5G unload

set -eu

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB=/usr/local/lib/vantage-5g
BIN_LINK=/usr/local/bin/vantage-5G
UNIT_DIR=/etc/systemd/system
ETC=/etc/vantage-5g
PIN_DIR=/sys/fs/bpf/vantage
MAIN=vantage-5g.service
MON=vantage-5g-monitor.service

usage() {
    echo "usage: sudo $0 install [--enable]"
    echo "       sudo $0 uninstall [--purge] [--force]"
}

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift
ENABLE=0; PURGE=0; FORCE=0
for a in "$@"; do
    case "${ACTION}:${a}" in
        install:--enable)  ENABLE=1 ;;
        uninstall:--purge) PURGE=1 ;;
        uninstall:--force) FORCE=1 ;;
        *) echo "[-] unknown option for '${ACTION}': ${a}"; usage; exit 1 ;;
    esac
done
case "${ACTION}" in
    install|uninstall) ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
esac
if [[ "$(id -u)" -ne 0 ]]; then
    echo "[-] run as root: sudo $0 ${ACTION}"
    exit 1
fi
command -v systemctl >/dev/null || { echo "[-] systemctl not found (systemd required)"; exit 1; }

# put <src> <dst> <mode>: copy to a temp file next to dst, then rename over it.
# PUT_TMP is removed by the EXIT trap if we fail or are interrupted in between.
PUT_TMP=""
put() {
    PUT_TMP="$(dirname "$2")/.$(basename "$2").new.$$"
    install -m "$3" "$1" "${PUT_TMP}"
    mv -f "${PUT_TMP}" "$2"
    PUT_TMP=""
}
trap '[[ -z "${PUT_TMP}" ]] || rm -f "${PUT_TMP}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

do_install() {
    local f missing=""
    for f in target/release/vantage-5G vantage_rx_policer.o vantage_tx_pacer.o setup.sh detach.sh \
             systemd/vantage-5g-unit.sh systemd/${MAIN} systemd/${MON} \
             systemd/vantage-5g.env.example systemd/policies.conf.example; do
        [[ -f "${SRC}/${f}" ]] || missing+=" ${f}"
    done
    if [[ -n "${missing}" ]]; then
        echo "[-] missing in ${SRC}:${missing}"
        echo "    build first (as a normal user): make build"
        exit 2
    fi

    echo "=== 1. ${LIB} ==="
    install -d -m 0755 "${LIB}"
    # Leftovers of an install killed with SIGKILL (the trap could not run).
    rm -f "${LIB}"/.*.new.* "${UNIT_DIR}"/.vantage-5g*.new.* "${ETC}"/.*.new.* 2>/dev/null || true
    # The binary goes last: if the copy stops part-way, the old binary is
    # still in place and `load` keeps failing loudly on a map mismatch rather
    # than a new binary running against old .o files.
    put "${SRC}/vantage_rx_policer.o"       "${LIB}/vantage_rx_policer.o" 0644
    put "${SRC}/vantage_tx_pacer.o"         "${LIB}/vantage_tx_pacer.o"   0644
    put "${SRC}/setup.sh"                   "${LIB}/setup.sh"             0755
    put "${SRC}/detach.sh"                  "${LIB}/detach.sh"            0755
    put "${SRC}/systemd/vantage-5g-unit.sh" "${LIB}/vantage-5g-unit.sh"   0755
    put "${SRC}/target/release/vantage-5G"  "${LIB}/vantage-5G"           0755
    echo "    $(${LIB}/vantage-5G --version)"

    echo "=== 2. ${BIN_LINK} ==="
    if [[ -e "${BIN_LINK}" && ! -L "${BIN_LINK}" ]]; then
        echo "[!] ${BIN_LINK} is a regular file, not a symlink: left alone (use ${LIB}/vantage-5G)"
    else
        [[ -L "${BIN_LINK}" && "$(readlink "${BIN_LINK}")" != "${LIB}/vantage-5G" ]] \
            && echo "    replacing symlink -> $(readlink "${BIN_LINK}")"
        ln -sfn "${LIB}/vantage-5G" "${BIN_LINK}"
        echo "    ${BIN_LINK} -> ${LIB}/vantage-5G"
    fi

    echo "=== 3. systemd units ==="
    put "${SRC}/systemd/${MAIN}" "${UNIT_DIR}/${MAIN}" 0644
    put "${SRC}/systemd/${MON}"  "${UNIT_DIR}/${MON}"  0644
    systemctl daemon-reload
    echo "    ${UNIT_DIR}/${MAIN}, ${UNIT_DIR}/${MON}"

    echo "=== 4. ${ETC} (existing files kept) ==="
    install -d -m 0755 "${ETC}"
    for f in vantage-5g.env policies.conf; do
        put "${SRC}/systemd/${f}.example" "${ETC}/${f}.example" 0644
        if [[ -e "${ETC}/${f}" ]]; then
            echo "    ${ETC}/${f} exists (kept)"
        else
            install -m 0644 "${SRC}/systemd/${f}.example" "${ETC}/${f}"
            echo "    ${ETC}/${f} created from the example"
        fi
    done

    if [[ "${ENABLE}" -eq 1 ]]; then
        echo "=== 5. enable ==="
        systemctl enable "${MAIN}" "${MON}"
    fi

    echo
    echo "[+] Vantage-5G installed."
    if ! grep -qE '^[[:space:]]*IFACE=[^[:space:]]' "${ETC}/vantage-5g.env"; then
        echo "    [!] set IFACE= in ${ETC}/vantage-5g.env (the unit fails while it is empty)"
    fi
    if ! grep -qE '^[[:space:]]*MONITOR_ARGS=.*--bind' "${ETC}/vantage-5g.env"; then
        echo "    [!] MONITOR_ARGS in ${ETC}/vantage-5g.env has no --bind: the exporter listens on"
        echo "        0.0.0.0:9090 (N6 side included) and shows every UE's IP/policy/counters."
        echo "        Use --bind 127.0.0.1 or a management-network address."
    fi
    if is_active "${MAIN}"; then
        echo "    ${MAIN} is running the previous version; to switch (re-attach, short shaping gap):"
        echo "      sudo systemctl restart ${MAIN}"
    else
        echo "    start: sudo systemctl start ${MAIN} ${MON}"
    fi
    [[ "${ENABLE}" -eq 1 ]] || echo "    boot:  sudo systemctl enable ${MAIN} ${MON}"
}

do_uninstall() {
    local stop_failed=0
    echo "=== 1. stop units ==="
    is_active "${MON}" && { systemctl stop "${MON}" || true; }
    if is_active "${MAIN}"; then
        systemctl stop "${MAIN}" || stop_failed=1
        # A failed ExecStop leaves the unit "failed" (stop itself may return 0).
        if systemctl is-failed --quiet "${MAIN}" 2>/dev/null; then stop_failed=1; fi
    else
        # Not running (or a failed start: no ExecStop runs for that). Whatever
        # it left behind is handled by the pin check below.
        echo "    ${MAIN} not active"
    fi

    echo "=== 2. leftover pins ==="
    local cli="" orphan=0
    if [[ -x "${LIB}/vantage-5G" ]]; then cli="${LIB}/vantage-5G"
    elif [[ -x "${SRC}/target/release/vantage-5G" ]]; then cli="${SRC}/target/release/vantage-5G"; fi
    if [[ ! -d "${PIN_DIR}" ]]; then
        echo "    none (${PIN_DIR} absent)"
    elif [[ -z "${cli}" ]]; then
        # Installed copy already gone (earlier --force) and no build here:
        # nothing left that this script could protect -- finish, exit 5.
        orphan=1
    elif ! "${cli}" unload; then
        stop_failed=1
    fi
    if [[ "${stop_failed}" -ne 0 ]]; then
        echo
        echo "[-] Vantage-5G did not stop cleanly (see above / journalctl -u ${MAIN})."
        if [[ "${FORCE}" -eq 0 ]]; then
            echo "    Nothing was removed, so the CLI and detach.sh stay available:"
            if [[ -x "${LIB}/detach.sh" ]]; then
                echo "      sudo ${LIB}/detach.sh <iface>; sudo $0 uninstall"
            else
                echo "      sudo ${SRC}/detach.sh <iface>; sudo $0 uninstall"
            fi
            echo "    (or --force to remove the files anyway)"
            exit 4
        fi
        echo "    --force: removing the files anyway"
    fi

    echo "=== 3. units ==="
    for u in "${MON}" "${MAIN}"; do
        systemctl disable "${u}" 2>/dev/null || true
        rm -f "${UNIT_DIR}/${u}"
    done
    systemctl daemon-reload
    systemctl reset-failed "${MAIN}" "${MON}" 2>/dev/null || true

    echo "=== 4. files ==="
    if [[ -L "${BIN_LINK}" && "$(readlink "${BIN_LINK}")" == "${LIB}/vantage-5G" ]]; then
        rm -f "${BIN_LINK}"
    fi
    rm -rf "${LIB}"
    if [[ "${PURGE}" -eq 1 ]]; then
        rm -rf "${ETC}"
        echo "    removed ${LIB}, ${ETC}"
    else
        echo "    removed ${LIB}; kept ${ETC} (--purge removes it)"
    fi
    if [[ "${orphan}" -eq 1 ]]; then
        echo
        echo "[-] pins are still under ${PIN_DIR}, and no vantage-5G binary is left to remove them"
        echo "    (${LIB} was removed earlier, e.g. by --force). With a repository build:"
        echo "      sudo <repo>/detach.sh <iface>; sudo <repo>/target/release/vantage-5G unload"
        exit 5
    fi
    echo "[+] Vantage-5G uninstalled."
}

"do_${ACTION}"
