#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_tracing.h> // fentry/fexit 매크로 사용을 위해 필수

#ifndef TC_ACT_UNSPEC
#define TC_ACT_UNSPEC (-1)
#endif
#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif
#ifndef LIBBPF_PIN_BY_NAME
#define LIBBPF_PIN_BY_NAME 1
#endif

// 1. 기존 고속 패킷 텔레메트리 Ring Buffer
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
//    __uint(pinning, LIBBPF_PIN_BY_NAME); 
} telemetry_rb SEC(".maps");

// 2. [성능 최적화 센서] TCP 재전송 원자적 카운터 (Per-CPU Array)
// 코어 간 Lock 경합 없이 커널 내부에서 극초고속으로 숫자만 증가시킵니다.
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1); // 0번 인덱스에 글로벌 카운트 적치
    __type(key, __u32);
    __type(value, __u64);
//    __uint(pinning, LIBBPF_PIN_BY_NAME); // Rust에서 긁어갈 수 있도록 파일시스템 고정
} tcp_retransmit_counter SEC(".maps");

// [기능 1] 파드 인터페이스 관통 패킷 스니퍼
SEC("tc")
int vantage_telemetry_sniffer(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data     = (void *)(long)skb->data;
    struct ethhdr *eth = data;

    // 헤더 파싱 실패 시 패킷을 드롭하지 않고 그냥 통과시킴
    if ((void *)(eth + 1) > data_end) return TC_ACT_UNSPEC;

    // Ring Buffer 이벤트 할당
    struct telemetry_event *evt = bpf_ringbuf_reserve(&telemetry_rb, sizeof(*evt), 0);
    if (!evt) return TC_ACT_UNSPEC;

    // 1. 기본 정보 세팅 (모든 패킷 공통)
    evt->tenant_id = 0; // 기본값 (Non-IPv4)
    evt->pkt_len = skb->len;
    evt->target_bps = 0;
    evt->delay_ns = 0;
    evt->timestamp_ns = bpf_ktime_get_ns();

    // 2. IPv4인 경우에만 IP 주소(Tenant 식별자) 추출
    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) <= data_end) {
            // Source IP 주소를 정수형으로 저장
            evt->tenant_id = ip->saddr;
        }
    }

    // 데이터 전송 및 패킷 무사 통과
    bpf_ringbuf_submit(evt, 0);
    return TC_ACT_UNSPEC; 
}

// [기능 2] [fentry 도입] 커널 내부 TCP 재전송 함수 감시망
// 패킷 단위 연산이 아니므로 5G 라인레이트 부하가 0에 수렴합니다.
SEC("fentry/tcp_retransmit_skb")
int BPF_PROG(vantage_tcp_retransmit, struct sock *sk, struct sk_buff *skb) {
    __u32 key = 0;
    __u64 *count;

    count = bpf_map_lookup_elem(&tcp_retransmit_counter, &key);
    if (count) {
        *count += 1; // 커널 메모리 직접 가산
    }
    return 0;
}

char _license[] SEC("license") = "GPL";
