#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef TC_ACT_UNSPEC
#define TC_ACT_UNSPEC (-1)
#endif

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif

// 1. Cilium IP Cache 맵 (테넌트 ID 조회용)
struct cilium_ipcache_key {
    union {
        __u32 ip_address;
        __u32 pad[4];
    };
    __u32 pad_family[4];
    __u8 prefixlen;
};
struct cilium_ipcache_value {
    __u32 identity;
    __u32 encrypt_key;
    __u8 flags;
    __u8 pad[3];
    __u16 tunnel_endpoint;
    __u8 node_mac[6];
};
struct {
    __type(key, struct cilium_ipcache_key);
    __type(value, struct cilium_ipcache_value);
    __uint(max_entries, 512000);
} cilium_ipcache_ SEC(".maps");

// 2. 텔레메트리 Ring Buffer (기존 유지)
struct telemetry_event {
    __u32 tenant_id;
    __u32 pkt_len;
    __u64 target_bps;   // V2에서는 미사용 (0 처리)
    __u64 delay_ns;     // V2에서는 미사용 (0 처리)
    __u64 timestamp_ns;
};
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} telemetry_rb SEC(".maps");

// 🚨 [핵심] 어느 방향(ingress/egress)에 붙여도 동작하도록 범용 섹션 적용
SEC("tc")
int vantage_telemetry_sniffer(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_UNSPEC;

    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end) return TC_ACT_UNSPEC;

        // 목적지 IP 추출 및 LPM 키 생성
        struct cilium_ipcache_key key = {};
        key.prefixlen = 64;
        key.pad_family[3] = 1;
        __builtin_memcpy(&key.ip_address, &ip->saddr, sizeof(ip->saddr));

        struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_, &key);
        if (val) {
            // 패킷 데이터를 Ring Buffer로 복제 (복사)
            struct telemetry_event *evt = bpf_ringbuf_reserve(&telemetry_rb, sizeof(*evt), 0);
            if (evt) {
                evt->tenant_id = val->identity;
                evt->pkt_len = skb->len;
                evt->target_bps = 0; // K8s/Cilium에 제어를 위임했으므로 0으로 기록
                evt->delay_ns = 0;   
                evt->timestamp_ns = bpf_ktime_get_ns();
                bpf_ringbuf_submit(evt, 0);
            }
        }
    }

    // 🚨 [유령 센서 로직] 패킷에 개입하지 않고 다음 필터(Cilium)로 무조건 패스
    // TC_ACT_OK가 아닌 TC_ACT_UNSPEC(-1)을 반환하여 서열 싸움을 원천 차단합니다.
    return TC_ACT_UNSPEC; 
}

char _license[] SEC("license") = "GPL";
