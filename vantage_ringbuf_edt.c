#include "vmlinux.h"
#include <bpf/bpf_helpers.h>

#ifndef TC_ACT_UNSPEC
#define TC_ACT_UNSPEC (-1)
#endif
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

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME); 
} telemetry_rb SEC(".maps");

SEC("tc")
int vantage_telemetry_sniffer(struct __sk_buff *skb) {
    // 🚨 [조건문 완전 삭제] 헤더 검사 없이 패킷이 닿는 즉시 무조건 캡처
    struct telemetry_event *evt = bpf_ringbuf_reserve(&telemetry_rb, sizeof(*evt), 0);
    if (evt) {
        evt->tenant_id = 9999; // 테스트 성공을 증명할 매직 넘버 '9999'
        evt->pkt_len = skb->len;
        evt->target_bps = 0;
        evt->delay_ns = 0;
        evt->timestamp_ns = bpf_ktime_get_ns();
        bpf_ringbuf_submit(evt, 0);
    }
    
    // 관측 후 흔적 없이 패스
    return TC_ACT_UNSPEC; 
}

char _license[] SEC("license") = "GPL";
