#!/usr/bin/env bash
# core-provision.sh — L3 core VM (Ubuntu 22.04): Open5GS reference install + UERANSIM.
# Run as root on vantage-core (testbed/l3-vbox.sh does this over ssh). Idempotent:
# every step checks whether it is already done. Log: /var/log/vantage-core-provision.log.
#
# Follows the Open5GS quickstart (https://open5gs.org/open5gs/docs/guide/01-quickstart/):
#   MongoDB 8.0 from the official repo, ppa:open5gs/latest, subscribers via open5gs-dbctl.
# Deviations from a single-host quickstart, both taken from the quickstart's own
# "connect a gNB on another host" diff:
#   - AMF NGAP listens on 10.100.0.5, UPF GTP-U on 10.100.0.7 (instead of 127.0.0.5/7),
#     because the gNB/UEs run in a separate network namespace "ran" (see core-ran.sh)
#     so that UE addresses are not local addresses of the UPF host.
# The NAT/ip_forward step of the quickstart is applied by `core-ran.sh nat-reference`
# (non-persistent, exactly as the quickstart does with `sysctl -w` / `iptables -A`).
#
# Env: N6_MAC (MAC of the N6 NIC, required for the netplan drop-in), N6_ADDR (10.200.0.1/24),
#      UERANSIM_REF (git tag, default v3.2.7) + UERANSIM_COMMIT (commit it must resolve to;
#      known for v3.2.7), DBCTL_SHA256 (sha256 of open5gs-dbctl when Open5GS is not 2.8.0).
# ppa:open5gs/latest is not pinned: the installed version is printed here and recorded in
# each test's env.txt.

set -euo pipefail
exec > >(tee -a /var/log/vantage-core-provision.log) 2>&1
N6_ADDR=${N6_ADDR:-10.200.0.1/24}
UERANSIM_REF=${UERANSIM_REF:-v3.2.7}
# Commit the tag must resolve to (v3.2.7); for another UERANSIM_REF set UERANSIM_COMMIT.
UERANSIM_COMMIT=${UERANSIM_COMMIT:-$([[ ${UERANSIM_REF} == v3.2.7 ]] && echo 1d1e154f869260b5e98f6905827b1bd9b8663afc)}
UERANSIM_DIR=/opt/UERANSIM
export DEBIAN_FRONTEND=noninteractive
step() { echo "=== $(date +%T) $*"; }

# ---- N6 NIC (internal network vantage-n6), persistent ----
if [[ -n "${N6_MAC:-}" ]]; then
    step "netplan: N6 ${N6_MAC} ${N6_ADDR}"
    cat > /etc/netplan/60-vantage-n6.yaml <<EOF
network:
  version: 2
  ethernets:
    n6:
      match:
        macaddress: "${N6_MAC}"
      addresses: [${N6_ADDR}]
EOF
    chmod 600 /etc/netplan/60-vantage-n6.yaml
    netplan apply
fi
# netplan apply restarts systemd-networkd/resolved: wait until DNS answers again.
for _ in $(seq 1 30); do getent hosts repo.mongodb.org >/dev/null && break; sleep 2; done

# ---- MongoDB (quickstart "Getting MongoDB") ----
if ! dpkg -s mongodb-org >/dev/null 2>&1; then
    step "MongoDB 8.0"
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --batch --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-8.0.list
    apt-get update
    apt-get install -y mongodb-org
fi
systemctl enable --now mongod

# ---- Open5GS (quickstart "Ubuntu") ----
if ! dpkg -s open5gs >/dev/null 2>&1; then
    step "Open5GS (ppa:open5gs/latest)"
    add-apt-repository -y ppa:open5gs/latest
    apt-get update
    apt-get install -y open5gs
fi
O5GS_VER=$(dpkg-query -W -f='${Version}' open5gs)
echo "open5gs ${O5GS_VER}"

# ---- AMF NGAP / UPF GTP-U on the RAN link (quickstart's gNB-on-another-host diff) ----
step "amf.yaml ngap -> 10.100.0.5, upf.yaml gtpu -> 10.100.0.7"
python3 - <<'EOF'
import re
def sub_block(path, block, old, new):
    s = open(path).read()
    # replace the first "- address: <old>" after "<block>:" ... "server:"
    i = s.index(block + ":")
    j = s.index("- address: " + old, i) if ("- address: " + old) in s[i:] else -1
    if j < 0:
        if ("- address: " + new) in s[i:]:
            return
        raise SystemExit(f"{path}: no '{old}' under {block}")
    s = s[:j] + "- address: " + new + s[j + len("- address: " + old):]
    open(path, "w").write(s)
sub_block("/etc/open5gs/amf.yaml", "ngap", "127.0.0.5", "10.100.0.5")
sub_block("/etc/open5gs/upf.yaml", "gtpu", "127.0.0.7", "10.100.0.7")
EOF
grep -n -A3 'ngap:' /etc/open5gs/amf.yaml; grep -n -A3 'gtpu:' /etc/open5gs/upf.yaml
grep -n -A2 'session:' /etc/open5gs/upf.yaml /etc/open5gs/smf.yaml || true

# ---- open5gs-dbctl + subscribers (UERANSIM's default open5gs-ue.yaml credentials) ----
# The Ubuntu package does not ship open5gs-dbctl; it is fetched from misc/db/ of the
# installed version's tag and run as root, so its sha256 is pinned (computed from the
# v2.8.0 tag). Another Open5GS version needs DBCTL_SHA256=<sha256 of that version's file>.
DBCTL_SHA256_2_8_0=7a4cc2df9c8fa882b81e27f5e8c41eee8bade11daaa85bf1803330b26ad3752e
DBCTL=$(command -v open5gs-dbctl || true)
if [[ -z "${DBCTL}" || "${DBCTL}" == /usr/local/bin/open5gs-dbctl ]]; then
    ver=${O5GS_VER%%~*}
    want=${DBCTL_SHA256:-}
    [[ -z "${want}" && "${ver}" == 2.8.0 ]] && want=${DBCTL_SHA256_2_8_0}
    [[ -n "${want}" ]] || { echo "open5gs ${ver}: no pinned sha256 for open5gs-dbctl; set DBCTL_SHA256"; exit 1; }
    DBCTL=/usr/local/bin/open5gs-dbctl
    if ! echo "${want}  ${DBCTL}" | sha256sum -c --status 2>/dev/null; then
        step "open5gs-dbctl not packaged; fetching misc/db/open5gs-dbctl from v${ver}"
        curl -fsSL -o "${DBCTL}.part" "https://raw.githubusercontent.com/open5gs/open5gs/v${ver}/misc/db/open5gs-dbctl"
        echo "${want}  ${DBCTL}.part" | sha256sum -c || { rm -f "${DBCTL}.part"; echo "open5gs-dbctl sha256 mismatch"; exit 1; }
        mv "${DBCTL}.part" "${DBCTL}"; chmod +x "${DBCTL}"
    fi
    echo "${want}  ${DBCTL}" | sha256sum -c
fi
echo "dbctl=${DBCTL}"
SUBS=$("${DBCTL}" showfiltered 2>/dev/null || true)
for i in 1 2; do
    imsi=99970000000000${i}
    if grep -q "${imsi}" <<<"${SUBS}"; then
        echo "subscriber ${imsi} present"
    else
        step "add subscriber ${imsi}"
        "${DBCTL}" add "${imsi}" 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA
    fi
done

# ---- UERANSIM (source build) ----
if [[ ! -x ${UERANSIM_DIR}/build/nr-ue ]]; then
    step "UERANSIM ${UERANSIM_REF} build"
    rm -rf "${UERANSIM_DIR}"
    git clone --depth 1 -b "${UERANSIM_REF}" https://github.com/aligungr/UERANSIM "${UERANSIM_DIR}"
    [[ -n "${UERANSIM_COMMIT}" && $(git -C "${UERANSIM_DIR}" rev-parse HEAD) == "${UERANSIM_COMMIT}" ]] \
        || { echo "UERANSIM ${UERANSIM_REF}: HEAD $(git -C "${UERANSIM_DIR}" rev-parse HEAD) != expected '${UERANSIM_COMMIT}' (set UERANSIM_COMMIT)"; exit 1; }
    make -C "${UERANSIM_DIR}"
fi
echo "UERANSIM HEAD $(git -C "${UERANSIM_DIR}" rev-parse HEAD)"
ls -l "${UERANSIM_DIR}/build/"
mkdir -p /etc/ueransim
sed -e 's/^linkIp: 127.0.0.1/linkIp: 10.100.0.2/' -e 's/^ngapIp: 127.0.0.1/ngapIp: 10.100.0.2/' \
    -e 's/^gtpIp: 127.0.0.1/gtpIp: 10.100.0.2/' -e 's/- address: 127.0.0.5/- address: 10.100.0.5/' \
    "${UERANSIM_DIR}/config/open5gs-gnb.yaml" > /etc/ueransim/gnb.yaml
sed -e 's/^  - 127.0.0.1$/  - 10.100.0.2/' "${UERANSIM_DIR}/config/open5gs-ue.yaml" > /etc/ueransim/ue.yaml
grep -nE '^(mcc|mnc|linkIp|ngapIp|gtpIp)|address:' /etc/ueransim/gnb.yaml
grep -nE '^(supi|mcc|mnc)' /etc/ueransim/ue.yaml; grep -n -A1 gnbSearchList /etc/ueransim/ue.yaml
grep -nE 'mcc|mnc' /etc/open5gs/amf.yaml | head -3
step "provision done"
