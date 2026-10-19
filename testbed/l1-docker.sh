#!/usr/bin/env bash
# l1-docker.sh — run testbed/run-tests.sh inside a privileged Ubuntu 24.04
# container on Docker Desktop (macOS or Linux host).
#
# The repo is mounted read-only and copied into the container, so build
# artifacts never touch the host tree. Results land in _workspace/l1-<ts>/.
#
# Limits of this level: the Docker Desktop kernel has no sch_fq, so DL (EDT)
# pacing and setup.sh are SKIPped. Use the L2 Ubuntu VM for those.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
TS=$(date +%Y%m%d_%H%M%S)
OUT=${ROOT}/_workspace/l1-${TS}
mkdir -p "${OUT}"

docker build -q -t vantage-dev:latest testbed/docker >/dev/null || exit 1

# Named volumes cache cargo registry and build output between runs.
docker run --rm --privileged \
    -v "${ROOT}:/src:ro" \
    -v "${OUT}:/results" \
    -v vantage-cargo-registry:/root/.cargo/registry \
    -v vantage-target:/work/target \
    -e OUT=/results -e T="${T:-15}" \
    vantage-dev:latest bash -c '
        tar -C /src --exclude=./target --exclude=./_workspace* --exclude=./.git -cf - . | tar -C /work -xf -
        git -C /src rev-parse --short HEAD > /results/commit.txt 2>/dev/null || true
        cd /work && bash testbed/run-tests.sh'
rc=$?
echo "L1 results: ${OUT}"
exit ${rc}
