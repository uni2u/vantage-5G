#!/usr/bin/env bash
# l1-docker.sh — run testbed/run-tests.sh inside a privileged Ubuntu 24.04
# container on Docker Desktop (macOS or Linux host).
#
# The repo is mounted read-only and copied into the container, so build
# artifacts never touch the host tree. Results land in _workspace/l1-<ts>/.
#
# Limits of this level: the Docker Desktop kernel has no sch_fq, so DL (EDT)
# pacing and setup.sh are SKIPped. Use the L2 Ubuntu VM for those.
#
# Passed into the container (when set on the host): T and the run-tests.sh /
# netns-topo.sh variables VT_SETUP_AS, VT_NONROOT_USER, VT_NO_BPFTOOL, VT_NAT,
# VT_NETEM, VT_XDP_MODE, VT_N6_TXQ, VT_N6_TXQ_MAX. VT_SETUP_AS / VT_NONROOT_USER name users that
# do not exist in the container (setup.sh is not run there anyway without fq).

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/l1-${TS}
mkdir -p "${OUT}"

docker build -q -t vantage-dev:latest testbed/docker >/dev/null || exit 1
# Tested tree: HEAD plus "-dirty" when tracked files have uncommitted changes.
git -C "${ROOT}" describe --always --dirty > "${OUT}/commit.txt" 2>/dev/null || echo no-git > "${OUT}/commit.txt"

PASS_ENV=(-e OUT=/results -e T="${T:-15}")
for v in VT_SETUP_AS VT_NONROOT_USER VT_NO_BPFTOOL VT_NAT VT_NETEM VT_XDP_MODE VT_N6_TXQ VT_N6_TXQ_MAX; do
    [[ -n "${!v:-}" ]] && PASS_ENV+=(-e "${v}=${!v}")
done

# Named volumes cache cargo registry and build output between runs.
docker run --rm --privileged \
    -v "${ROOT}:/src:ro" \
    -v "${OUT}:/results" \
    -v vantage-cargo-registry:/root/.cargo/registry \
    -v vantage-target:/work/target \
    "${PASS_ENV[@]}" \
    vantage-dev:latest bash -c '
        tar -C /src --exclude=./target --exclude=./_workspace* --exclude=./.git -cf - . | tar -C /work -xf -
        cd /work && bash testbed/run-tests.sh'
rc=$?
echo "L1 results: ${OUT}"
exit ${rc}
