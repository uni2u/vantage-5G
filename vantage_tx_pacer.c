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

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);                 // UE IPv4 (network byte order)
    __type(value, struct ue_policy);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_policy_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);                 // UE IPv4
    __type(value, __u64);               // last scheduled skb->tstamp
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tx_tstamp_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, struct ue_stats);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ue_stats_map SEC(".maps");

static __always_inline void stats_tx(struct ue_stats *s, __u32 len, int dropped)
{
    if (dropped) {
        __sync_fetch_and_add(&s->tx_drops, 1);
    } else {
        __sync_fetch_and_add(&s->tx_bytes, len);
        __sync_fetch_and_add(&s->tx_packets, 1);
    }
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

    struct ue_stats *stats = bpf_map_lookup_elem(&ue_stats_map, &ue_ip);
    if (!stats) {
        struct ue_stats init = {};
        bpf_map_update_elem(&ue_stats_map, &ue_ip, &init, BPF_ANY);
        stats = bpf_map_lookup_elem(&ue_stats_map, &ue_ip);
    }

    // Killswitch: explicit tx_bps=0 means "block downlink for this UE".
    if (pol->tx_bps == 0) {
        if (stats)
            stats_tx(stats, skb->len, 1);
        return TC_ACT_SHOT;
    }

    // EDT pacing: delay_ns = pkt_len * 8 * 1e9 / tx_bps
    __u64 delay_ns = ((__u64)skb->len * 8000000000ULL) / pol->tx_bps;
    __u64 now = bpf_ktime_get_ns();
    __u64 next = now;

    __u64 *last = bpf_map_lookup_elem(&tx_tstamp_map, &ue_ip);
    if (last) {
        if (*last > now)
            next = *last;
    } else {
        bpf_map_update_elem(&tx_tstamp_map, &ue_ip, &now, BPF_ANY);
        last = bpf_map_lookup_elem(&tx_tstamp_map, &ue_ip);
        if (!last)
            return TC_ACT_OK;
    }

    next += delay_ns;
    *last = next;
    skb->tstamp = next;

    if (stats)
        stats_tx(stats, skb->len, 0);

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
