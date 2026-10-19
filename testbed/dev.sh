#!/usr/bin/env bash
# dev.sh '<command>' — run a command in the Ubuntu 24.04 dev container against a
# throwaway copy of the repo (host tree is mounted read-only).
#
#   ./testbed/dev.sh 'make build'
#   ./testbed/dev.sh 'make bpf && bpftool prog loadall vantage_tx_pacer.o /sys/fs/bpf/t type tc'
#   ./testbed/dev.sh 'cargo clippy --release'
#
# Privileged, with bpffs mounted, so verifier/load experiments work too.
# Not available here: sch_fq (EDT pacing) — use testbed/l2-vbox.sh.

set -u
cd "$(dirname "$0")/.."
docker build -q -t vantage-dev:latest testbed/docker >/dev/null || exit 1
exec docker run --rm --privileged \
    -v "$(pwd):/src:ro" \
    -v vantage-cargo-registry:/root/.cargo/registry \
    -v vantage-target:/work/target \
    vantage-dev:latest bash -c '
        tar -C /src --exclude=./target --exclude="./_workspace*" --exclude=./.git -cf - . | tar -C /work -xf -
        mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
        cd /work && '"$*"
