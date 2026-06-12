#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef TC_ACT_UNSPEC
#define TC_ACT_UNSPEC (-1)
#endif
#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif

// 🚨 [신규 주입] 맵 고정용 상수
#ifndef LIBBPF_PIN_BY_NAME
#define LIBBPF_PIN_BY_NAME 1
#endif

struct telemetry_event {
    __u32 tenant_id;
    __u32 pkt_len;
    __u64 target_bps;
    __u64 delay_ns;
    __u64 timestamp_ns;
};

// 🚨 [핵심 교정] Rust와 통신하기 위해 맵을 전역 파일시스템에 고정(Pinning)합니다.
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME); 
} telemetry_rb SEC(".maps");

SEC("tc")
int vantage_telemetry_sniffer(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_UNSPEC;

    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end) return TC_ACT_UNSPEC;

        struct telemetry_event *evt = bpf_ringbuf_reserve(&telemetry_rb, sizeof(*evt), 0);
        if (evt) {
            evt->tenant_id = ip->saddr;
            evt->pkt_len = skb->len;
            evt->target_bps = 0;
            evt->delay_ns = 0;
            evt->timestamp_ns = bpf_ktime_get_ns();
            bpf_ringbuf_submit(evt, 0);
        }
    }
    return TC_ACT_UNSPEC; 
}
char _license[] SEC("license") = "GPL";
