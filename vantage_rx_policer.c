// SPDX-License-Identifier: GPL-2.0
//
// vantage_rx_policer.c
// Vantage-5G RX (Uplink) bandwidth policer
//
// Attach: XDP on the service-node N6-facing NIC.
// Direction: UE -> Service (packet src IP = UE IP).
// Mechanism: per-UE token bucket. Drop when tokens < pkt_len.

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif

// ---- Shared policy record (RX policer + TX pacer both read this) ----
struct ue_policy {
    __u64 rx_bps;   // 0 = uncapped (bypass), non-zero = limit
    __u64 tx_bps;   // read by tx_pacer
};

// ---- Per-UE RX token-bucket state (RX policer owns this map) ----
struct rx_state {
    __u64 tokens;           // available tokens in bytes
    __u64 last_refill_ns;   // monotonic ktime of last refill
};

// ---- Per-UE stats (both programs write) ----
struct ue_stats {
    __u64 rx_bytes;
    __u64 rx_packets;
    __u64 rx_drops;
    __u64 tx_bytes;
    __u64 tx_packets;
    __u64 tx_drops;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);                 // UE IPv4 (network byte order)
    __type(value, struct ue_policy);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_policy_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, struct rx_state);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} rx_state_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, struct ue_stats);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_stats_map SEC(".maps");

// Burst capacity heuristic: 250ms worth of bytes, floored at 16 MTU.
static __always_inline __u64 bucket_capacity(__u64 rx_bps)
{
    __u64 cap = rx_bps / 32;      // rx_bps/8/4  == 250 ms
    __u64 floor = 16 * 1500;
    return cap > floor ? cap : floor;
}

static __always_inline void stats_rx(struct ue_stats *s, __u32 len, int dropped)
{
    if (dropped) {
        __sync_fetch_and_add(&s->rx_drops, 1);
    } else {
        __sync_fetch_and_add(&s->rx_bytes, len);
        __sync_fetch_and_add(&s->rx_packets, 1);
    }
}

SEC("xdp")
int vantage_rx_policer(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    __u32 ue_ip = ip->saddr;    // UL: source is the UE

    struct ue_policy *pol = bpf_map_lookup_elem(&ue_policy_map, &ue_ip);
    if (!pol || pol->rx_bps == 0)
        return XDP_PASS;         // no policy or explicit bypass

    __u32 pkt_len = data_end - data;
    __u64 now = bpf_ktime_get_ns();
    __u64 cap = bucket_capacity(pol->rx_bps);

    struct rx_state *st = bpf_map_lookup_elem(&rx_state_map, &ue_ip);
    if (!st) {
        struct rx_state init = { .tokens = cap, .last_refill_ns = now };
        bpf_map_update_elem(&rx_state_map, &ue_ip, &init, BPF_ANY);
        st = bpf_map_lookup_elem(&rx_state_map, &ue_ip);
        if (!st)
            return XDP_PASS;
    }

    // Refill: tokens += (elapsed_ns * rx_bps) / (8 * 1e9), capped.
    __u64 elapsed = now - st->last_refill_ns;
    __u64 refill  = (elapsed / 1000) * pol->rx_bps / 8000000ULL;
    __u64 tokens  = st->tokens + refill;
    if (tokens > cap)
        tokens = cap;
    st->last_refill_ns = now;

    struct ue_stats *stats = bpf_map_lookup_elem(&ue_stats_map, &ue_ip);
    if (!stats) {
        struct ue_stats init = {};
        bpf_map_update_elem(&ue_stats_map, &ue_ip, &init, BPF_ANY);
        stats = bpf_map_lookup_elem(&ue_stats_map, &ue_ip);
    }

    if (tokens < pkt_len) {
        st->tokens = tokens;
        if (stats)
            stats_rx(stats, pkt_len, 1);
        return XDP_DROP;
    }

    st->tokens = tokens - pkt_len;
    if (stats)
        stats_rx(stats, pkt_len, 0);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
