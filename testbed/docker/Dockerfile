# Vantage-5G dev image: Ubuntu 24.04 + clang/libbpf/bpftool + Rust.
# Used by testbed/l1-docker.sh (build, verifier, load, RX shaping on veth).
# sudo: setup.sh/detach.sh call "sudo tc/ip ..." and hide errors with
# 2>/dev/null || true, so without it detach.sh silently does nothing.

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config \
    linux-tools-common linux-tools-generic iproute2 iptables iperf3 iputils-ping tcpdump jq \
    curl ca-certificates git python3 sudo && rm -rf /var/lib/apt/lists/* \
 && ln -sf $(ls -d /usr/lib/linux-tools/*/bpftool | head -1) /usr/local/sbin/bpftool
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
# minimal profile omits these; needed for `cargo fmt --check` / `cargo clippy` in dev.sh
RUN rustup component add rustfmt clippy
WORKDIR /work
