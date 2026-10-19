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
    __u64 rx_bps;   // 0 = uncapped (pass, still counted), non-zero = limit
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

// Must match vantage_tx_pacer.c exactly (shared pinned map). Stays HASH:
// admin-set policy must never be evicted.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);                 // UE IPv4 (network byte order)
    __type(value, struct ue_policy);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_policy_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);   // D7: evict instead of failing when full
    __type(key, __u32);
    __type(value, struct rx_state);
    __uint(max_entries, 16384);  // D25: >= 2*128*nCPU (pre-6.16 LRU local free lists)
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} rx_state_map SEC(".maps");

// Must match vantage_tx_pacer.c exactly (shared pinned map).
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);   // D7
    __type(key, __u32);
    __type(value, struct ue_stats);
    __uint(max_entries, 16384);  // D25: >= 2*128*nCPU (pre-6.16 LRU local free lists)
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_stats_map SEC(".maps");

#define NSEC_PER_SEC 1000000000ULL

// Bucket capacity floor. xdpgeneric runs after GRO, so a single coalesced
// IPv4 skb can be up to 64KB (IP tot_len <= 65535) + L2 header. A bucket
// smaller than that would drop such a frame forever. Floor = one maximal GRO
// frame + one MTU frame. (IPv4 BIG TCP / gro_max_size > 64K is not covered,
// see _workspace/03_datapath_notes.md.)
#define RX_CAP_FLOOR (65536ULL + 1514ULL)

// Upper bound on the rate the arithmetic has to handle, in bytes/s.
// 5e10 B/s = 400 Gbps. Keeps cap * 1e9 below 2^64 (see refill()).
#define RX_BYTES_PER_SEC_MAX 50000000000ULL

// Burst capacity: 250 ms worth of bytes, floored at RX_CAP_FLOOR.
static __always_inline __u64 bucket_capacity(__u64 bytes_per_sec)
{
    __u64 cap = bytes_per_sec / 4;    // 250 ms
    return cap > RX_CAP_FLOOR ? cap : RX_CAP_FLOOR;
}

static __always_inline void stats_rx(struct ue_stats *s, __u32 len, int dropped)
{
    if (!s)
        return;
    if (dropped) {
        __sync_fetch_and_add(&s->rx_drops, 1);
    } else {
        __sync_fetch_and_add(&s->rx_bytes, len);
        __sync_fetch_and_add(&s->rx_packets, 1);
    }
}

static __always_inline struct ue_stats *get_stats(__u32 *ue_ip)
{
    struct ue_stats *s = bpf_map_lookup_elem(&ue_stats_map, ue_ip);
    if (!s) {
        struct ue_stats init = {};
        // D9: NOEXIST so a concurrent creator (RX or TX, other CPU) is not
        // overwritten; on EEXIST the lookup below finds its entry.
        bpf_map_update_elem(&ue_stats_map, ue_ip, &init, BPF_NOEXIST);
        s = bpf_map_lookup_elem(&ue_stats_map, ue_ip);
    }
    return s;
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
    if (!pol)
        return XDP_PASS;         // no policy: bypass, not counted

    __u32 pkt_len = data_end - data;   // L2 included (same unit as tc skb->len)
    struct ue_stats *stats = get_stats(&ue_ip);

    __u64 rx_bps = pol->rx_bps;
    if (rx_bps == 0) {               // explicit uncapped: pass, but count (D15)
        stats_rx(stats, pkt_len, 0);
        return XDP_PASS;
    }

    // bits/s -> bytes/s (CLI writes Mbps*1e6, always divisible by 8).
    __u64 bps = rx_bps / 8;
    if (bps == 0)
        bps = 1;
    if (bps > RX_BYTES_PER_SEC_MAX)
        bps = RX_BYTES_PER_SEC_MAX;

    __u64 now = bpf_ktime_get_ns();
    __u64 cap = bucket_capacity(bps);

    struct rx_state *st = bpf_map_lookup_elem(&rx_state_map, &ue_ip);
    if (!st) {
        struct rx_state init = { .tokens = cap, .last_refill_ns = now };
        bpf_map_update_elem(&rx_state_map, &ue_ip, &init, BPF_NOEXIST);  // D9
        st = bpf_map_lookup_elem(&rx_state_map, &ue_ip);
        if (!st)
            return XDP_PASS;
    }

    // ---- Refill (D5/D6) ----
    // Snapshot once; another CPU may update the entry concurrently.
    __u64 last   = *(volatile __u64 *)&st->last_refill_ns;
    __u64 tokens = *(volatile __u64 *)&st->tokens;
    if (tokens > cap)
        tokens = cap;                // rate lowered since last packet

    if (now > last) {                // now <= last (other CPU ahead): no refill
        __u64 elapsed = now - last;
        // Time to fill an empty bucket. cap <= 1.25e10 -> cap*1e9 <= 1.25e19 < 2^64.
        __u64 fill_ns = cap * NSEC_PER_SEC / bps;
        if (elapsed >= fill_ns) {
            tokens = cap;
            if (*(volatile __u64 *)&st->last_refill_ns == last)
                st->last_refill_ns = now;
        } else {
            // elapsed < fill_ns -> elapsed*bps < cap*1e9: no overflow.
            __u64 refill = elapsed * bps / NSEC_PER_SEC;
            if (refill) {
                // Advance only by the time actually converted to tokens
                // (ceil, so we never credit the same ns twice); the
                // remainder carries over to the next packet.
                __u64 used_ns = (refill * NSEC_PER_SEC + bps - 1) / bps;
                tokens += refill;
                if (tokens > cap)
                    tokens = cap;
                // Never move last backwards if another CPU advanced it.
                if (*(volatile __u64 *)&st->last_refill_ns == last)
                    st->last_refill_ns = last + used_ns;
            }
        }
    }

    if (tokens < pkt_len) {
        st->tokens = tokens;
        stats_rx(stats, pkt_len, 1);
        return XDP_DROP;
    }

    st->tokens = tokens - pkt_len;
    stats_rx(stats, pkt_len, 0);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
