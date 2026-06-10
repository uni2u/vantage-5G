#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// --- [공통] 맵 규격 동기화 매크로 ---
#ifndef BPF_F_NO_PREALLOC
#define BPF_F_NO_PREALLOC 1
#endif
#ifndef BPF_F_RDONLY_PROG
#define BPF_F_RDONLY_PROG 128
#endif
#ifndef LIBBPF_PIN_BY_NAME
#define LIBBPF_PIN_BY_NAME 1
#endif

// --- [Phase 2] Cilium 가입자 식별 구조체 및 맵 ---
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

// --- [Phase 3] EDT 상태 저장용 맵 ---
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tenant_tstamp_map SEC(".maps");

// --- [Phase 4] 동적 대역폭 설정 맵 ---
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} tenant_bw_map SEC(".maps");

// --- [Phase 5] BPF Ring Buffer 텔레메트리 이벤트 구조체 및 맵 ---
struct telemetry_event {
    __u32 tenant_id;
    __u32 pkt_len;
    __u64 target_bps;
    __u64 delay_ns;
    __u64 timestamp_ns;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024); // 256KB 버퍼
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} telemetry_rb SEC(".maps");

// --- 메인 로직 ---
SEC("tc_egress")
int vantage_telemetry_pacing(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;

    // 1. 패킷 헤더 파싱
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(ETH_P_IP)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;

    // 2. 목적지 IP 기반 테넌트 식별
    struct cilium_ipcache_key key = {};
    key.prefixlen = 64;
    key.pad_family[3] = 1;

    // [수정 전] __builtin_memcpy(&key.ip_address, &ip->daddr, sizeof(ip->daddr));
    // [수정 후] 타겟을 daddr에서 saddr(소스 IP)로 변경
    __builtin_memcpy(&key.ip_address, &ip->saddr, sizeof(ip->saddr));

    struct cilium_ipcache_value *val = bpf_map_lookup_elem(&cilium_ipcache_v2, &key);
    
    // 식별 성공 시 통제 로직 개입
    if (val) {
        __u32 tenant_id = val->identity;
        __u64 *bw_ptr = bpf_map_lookup_elem(&tenant_bw_map, &tenant_id);
        
        if (bw_ptr) {
            if (*bw_ptr == 0) return TC_ACT_SHOT; // 킬 스위치 (즉각 폐기)

            __u64 target_bps = *bw_ptr;
            // 3. 동적 딜레이 산출
            __u64 delay_ns = ((__u64)skb->len * 8000000000ULL) / target_bps;

            // 4. EDT 타임스탬프 스케줄링
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

            // 5. [핵심] Ring Buffer로 바이너리 이벤트 비동기 투척
            struct telemetry_event *evt;
            evt = bpf_ringbuf_reserve(&telemetry_rb, sizeof(*evt), 0);
            if (evt) {
                evt->tenant_id = tenant_id;
                evt->pkt_len = skb->len;
                evt->target_bps = target_bps;
                evt->delay_ns = delay_ns;
                evt->timestamp_ns = now;
                bpf_ringbuf_submit(evt, 0); 
            }
        }
    }
    return TC_ACT_OK;
}
char _license[] SEC("license") = "GPL";
