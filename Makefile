.PHONY: build rust bpf clean check

BPF_SRC := vantage_ringbuf_edt.c
BPF_OBJ := vantage_ringbuf_edt.o
VMLINUX_H := vmlinux.h
VMLINUX_BTF := /sys/kernel/btf/vmlinux
TARGET_ARCH ?= x86

build: bpf rust

rust:
	cargo build --release

bpf: $(VMLINUX_H)
	clang -O2 -g -target bpf \
		-D__TARGET_ARCH_$(TARGET_ARCH) \
		-I. \
		-c $(BPF_SRC) \
		-o $(BPF_OBJ)

$(VMLINUX_H):
	bpftool btf dump file $(VMLINUX_BTF) format c > $(VMLINUX_H)

check:
	@command -v cargo >/dev/null || (echo "cargo not found"; exit 1)
	@command -v clang >/dev/null || (echo "clang not found"; exit 1)
	@command -v bpftool >/dev/null || (echo "bpftool not found"; exit 1)
	@test -f $(VMLINUX_BTF) || (echo "$(VMLINUX_BTF) not found"; exit 1)

clean:
	rm -f $(BPF_OBJ)
	rm -f $(VMLINUX_H)
	cargo clean
