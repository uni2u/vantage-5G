#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef BPF_F_NO_PREALLOC
#define BPF_F_NO_PREALLOC 1
#endif
#ifndef BPF_F_RDONLY_PROG
#define BPF_F_RDONLY_PROG 128
#endif
#ifndef LIBBPF_PIN_BY_NAME
#define LIBBPF_PIN_BY_NAME 1
#endif

struct cilium_ipcache_key {
    __u32 prefixlen;
    __u8  pad_family[4];
    __u8  ip_address[16];
} __attribute__((packed));

struct cilium_ipcache_value {
    __u32 identity;
    __u32 tunnel_endpoint;
    __u8  key_flags_cluster[4];
    __u32 pad1;
    __u64 pad2;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __uint(key_size, sizeof(struct cilium_ipcache_key));
    __uint(value_size, sizeof(struct cilium_ipcache_value));
    __uint(max_entries, 512000);
    __uint(map_flags, BPF_F_NO_PREALLOC | BPF_F_RDONLY_PROG);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} cilium_ipcache_v2 SEC(".maps");


SEC("tc_ingress")
int vantage_tc_filter(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;

    if (eth->h_proto != bpf_htons(ETH_P_IP)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;

    struct cilium_ipcache_key key = {};
    key.prefixlen = 64;
    key.pad_family[3] = 1;
    // 목적지 IP를 기준으로 룩업
    __builtin_memcpy(&key.ip_address, &ip->daddr, sizeof(ip->daddr));

    struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_v2, &key);
    
    // [스나이퍼 모드] 룩업에 성공했고, 그 Identity가 정확히 5001번일 때만 출력!
    if (val && val->identity == 5001) {
        bpf_printk("[Vantage-5G] CRITICAL HIT! Tenant 5001 Packet Detected! IP: %pI4\n", &ip->daddr);
        
        // 향후 이곳에 tc-bpf EDT 페이싱(QoS 큐잉) 로직이 삽입됩니다.
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
