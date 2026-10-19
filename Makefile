.PHONY: build rust bpf clean check

# Phase 1 BPF objects: XDP RX policer + tc-bpf EDT TX pacer.
BPF_SRCS  := vantage_rx_policer.c vantage_tx_pacer.c
BPF_OBJS  := $(BPF_SRCS:.c=.o)

VMLINUX_H   := vmlinux.h
VMLINUX_BTF := /sys/kernel/btf/vmlinux
TARGET_ARCH ?= x86

CLANG_FLAGS := -O2 -g -target bpf -D__TARGET_ARCH_$(TARGET_ARCH) -I.

build: bpf rust

rust:
	cargo build --release

bpf: $(VMLINUX_H) $(BPF_OBJS)

%.o: %.c $(VMLINUX_H)
	clang $(CLANG_FLAGS) -c $< -o $@

$(VMLINUX_H):
	bpftool btf dump file $(VMLINUX_BTF) format c > $(VMLINUX_H)

check:
	@command -v cargo   >/dev/null || (echo "cargo not found"; exit 1)
	@command -v clang   >/dev/null || (echo "clang not found"; exit 1)
	@bpftool version >/dev/null 2>&1 || (echo "bpftool not usable (Ubuntu: apt install linux-tools-common linux-tools-$$(uname -r))"; exit 1)
	@command -v tc      >/dev/null || (echo "tc not found"; exit 1)
	@command -v ip      >/dev/null || (echo "ip not found"; exit 1)
	@test -f $(VMLINUX_BTF) || (echo "$(VMLINUX_BTF) not found"; exit 1)
	@echo "OK: all required tools and BTF are available."

clean:
	rm -f $(BPF_OBJS)
	rm -f $(VMLINUX_H)
	cargo clean
