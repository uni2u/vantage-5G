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

// --- [Phase 2: Cilium v2 맵] ---
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

// --- [Phase 3: EDT 상태 저장 맵] ---
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tenant_tstamp_map SEC(".maps");

// --- [Phase 4: 동적 대역폭 설정 맵 (NEW)] ---
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);   // Identity (5001)
    __type(value, __u64); // Target Bandwidth in bps
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tenant_bw_map SEC(".maps");

SEC("tc_egress")
int vantage_dynamic_pacing(struct __sk_buff *skb) {
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
    __builtin_memcpy(&key.ip_address, &ip->daddr, sizeof(ip->daddr));

    struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_v2, &key);
    
    if (val && val->identity == 5001) {
        __u32 tenant_id = val->identity;
        __u64 target_bps = 10000000; // 기본 안전망: 10Mbps
        
        // 1. 제어 평면(Rust)에서 주입한 동적 대역폭 설정 읽기
        __u64 *bw_ptr = bpf_map_lookup_elem(&tenant_bw_map, &tenant_id);
        if (bw_ptr) {
            if (*bw_ptr == 0) {
                // [SDN 킬 스위치 발동] 대역폭이 0이면 즉각 하드웨어 드롭
                bpf_printk("[Vantage-5G] Tenant %d BLOCKED by Control Plane.\n", tenant_id);
                return TC_ACT_SHOT; 
            }
            target_bps = *bw_ptr;
        }

        // 2. 동적 딜레이 방정식 (0 나누기 방지됨)
        __u64 delay_ns = ((__u64)skb->len * 8000000000ULL) / target_bps;

        // 3. 타임스탬프 계산 및 각인
        __u64 now = bpf_ktime_get_ns();
        __u64 next_tstamp = now;
        __u64 *last_tstamp = bpf_map_lookup_elem(&tenant_tstamp_map, &tenant_id);

        if (last_tstamp) {
            if (*last_tstamp > now) next_tstamp = *last_tstamp;
        } else {
            bpf_map_update_elem(&tenant_tstamp_map, &tenant_id, &now, BPF_ANY);
            last_tstamp = bpf_map_lookup_elem(&tenant_tstamp_map, &tenant_id);
            if (!last_tstamp) return TC_ACT_OK;
        }

        next_tstamp += delay_ns;
        *last_tstamp = next_tstamp;
        skb->tstamp = next_tstamp;

        bpf_printk("[Vantage-5G] T:%d | BPS:%llu | Delay:%llu ns\n", tenant_id, target_bps, delay_ns);
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
