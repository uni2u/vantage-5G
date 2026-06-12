#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef TC_ACT_UNSPEC
#define TC_ACT_UNSPEC (-1)
#endif

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif

// Rust 관제탑과 통신할 구조체 (변경 없음)
struct telemetry_event {
    __u32 tenant_id;    // 🚨 [의존성 제거] Cilium ID 대신 파드의 Source IP(정수)를 삽입합니다.
    __u32 pkt_len;
    __u64 target_bps;   // V2 미사용
    __u64 delay_ns;     // V2 미사용
    __u64 timestamp_ns;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
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

        // 외부 맵(Cilium) 조회 없이 즉시 Ring Buffer로 직행 (Zero-Dependency)
        struct telemetry_event *evt = bpf_ringbuf_reserve(&telemetry_rb, sizeof(*evt), 0);
        if (evt) {
            evt->tenant_id = ip->saddr; // IP 주소를 그대로 전달
            evt->pkt_len = skb->len;
            evt->target_bps = 0;
            evt->delay_ns = 0;
            evt->timestamp_ns = bpf_ktime_get_ns();
            bpf_ringbuf_submit(evt, 0);
        }
    }

    // 통제는 Cilium에게 맡기고, 우리는 유령처럼 관측만 한 뒤 통과시킵니다.
    return TC_ACT_UNSPEC; 
}

char _license[] SEC("license") = "GPL";
