// SPDX-License-Identifier: GPL-2.0
//
// vantage_tx_pacer.c
// Vantage-5G TX (Downlink) bandwidth pacer.
//
// Attach: tc-bpf egress on the service-node N6-facing NIC (clsact qdisc).
// Requires the interface root qdisc to be `fq` so skb->tstamp is honored.
// Direction: Service -> UE (packet dst IP = UE IP).
// Mechanism: per-UE EDT — stamp future departure time on each skb.
// Killswitch: tx_bps == 0 -> TC_ACT_SHOT (explicit block).

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef TC_ACT_OK
#define TC_ACT_OK   0
#endif
#ifndef TC_ACT_SHOT
#define TC_ACT_SHOT 2
#endif
#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif

// Must match struct in vantage_rx_policer.c
struct ue_policy {
    __u64 rx_bps;
    __u64 tx_bps;   // 0 = killswitch (drop), non-zero = pace
};

struct ue_stats {
    __u64 rx_bytes;
    __u64 rx_packets;
    __u64 rx_drops;
    __u64 tx_bytes;
    __u64 tx_packets;
    __u64 tx_drops;
};

// Must match vantage_rx_policer.c exactly (shared pinned map). Stays HASH:
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
    __type(key, __u32);                 // UE IPv4
    __type(value, __u64);               // last scheduled skb->tstamp
    __uint(max_entries, 16384);  // D25: >= 2*128*nCPU (pre-6.16 LRU local free lists)
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tx_tstamp_map SEC(".maps");

// Must match vantage_rx_policer.c exactly (shared pinned map).
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);   // D7
    __type(key, __u32);
    __type(value, struct ue_stats);
    __uint(max_entries, 16384);  // D25: >= 2*128*nCPU (pre-6.16 LRU local free lists)
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_stats_map SEC(".maps");

// D4: maximum distance of a departure time into the future. Well below the
// fq default horizon (10 s) so fq never drops a packet whose slot we already
// consumed, and short enough that an overload (e.g. UDP above cap) or a
// rate increase via `set` recovers within 2 s. Same value as Cilium's
// bandwidth manager drop horizon.
#define TX_HORIZON_NS 2000000000ULL

// D16: count wire segments, not skbs. A GSO/TSO skb (up to 64KB) leaves the
// NIC as gso_segs frames; non-GSO skbs report 0.
static __always_inline __u32 skb_segs(struct __sk_buff *skb)
{
    __u32 segs = skb->gso_segs;
    return segs ? segs : 1;
}

static __always_inline void stats_tx(struct ue_stats *s, __u32 len, __u32 segs,
                                     int dropped)
{
    if (!s)
        return;
    if (dropped) {
        __sync_fetch_and_add(&s->tx_drops, segs);
    } else {
        __sync_fetch_and_add(&s->tx_bytes, len);
        __sync_fetch_and_add(&s->tx_packets, segs);
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

SEC("tc")
int vantage_tx_pacer(struct __sk_buff *skb)
{
    void *data     = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return TC_ACT_OK;

    __u32 ue_ip = ip->daddr;    // DL: destination is the UE

    struct ue_policy *pol = bpf_map_lookup_elem(&ue_policy_map, &ue_ip);
    if (!pol)
        return TC_ACT_OK;         // no policy: bypass

    struct ue_stats *stats = get_stats(&ue_ip);
    __u32 len  = skb->len;        // L2 included (same unit as XDP data_end-data)
    __u32 segs = skb_segs(skb);

    // Killswitch: explicit tx_bps=0 means "block downlink for this UE".
    __u64 tx_bps = pol->tx_bps;
    if (tx_bps == 0) {
        stats_tx(stats, len, segs, 1);
        return TC_ACT_SHOT;
    }

    // EDT pacing: delay_ns = len[bytes] * 8[bits/byte] * 1e9[ns/s] / tx_bps.
    // GSO skb <= 64KB -> 5.2e14. len is clamped to 16MB so the product
    // stays < 1.35e17 even for a bogus len (2^32 * 8e9 would wrap u64).
    __u64 l = len;
    if (l > (1ULL << 24))         // 16 MB: far above any GSO/BIG TCP skb
        l = 1ULL << 24;
    __u64 delay_ns = (l * 8000000000ULL) / tx_bps;
    __u64 now = bpf_ktime_get_ns();

    __u64 *last = bpf_map_lookup_elem(&tx_tstamp_map, &ue_ip);
    if (!last) {
        __u64 init = now;
        bpf_map_update_elem(&tx_tstamp_map, &ue_ip, &init, BPF_NOEXIST);  // D9
        last = bpf_map_lookup_elem(&tx_tstamp_map, &ue_ip);
        if (!last)
            return TC_ACT_OK;
    }

    __u64 prev = *(volatile __u64 *)last;
    __u64 next = prev > now ? prev : now;

    // D4: refuse to schedule beyond the horizon. Drop here (counted) and do
    // NOT advance *last, so the timeline never runs away from `now`.
    if (next + delay_ns - now > TX_HORIZON_NS) {
        stats_tx(stats, len, segs, 1);
        return TC_ACT_SHOT;
    }

    next += delay_ns;
    *last = next;
    skb->tstamp = next;

    stats_tx(stats, len, segs, 0);
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
