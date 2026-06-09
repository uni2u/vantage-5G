#include "vmlinux.h"
#include <bpf/bpf_helpers.h>

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, __u32);	//device IP
	__type(value, __u64);	//bandwidth
	__uint(max_entries, 256);
} vantage_qos_map SEC(".maps") ;

SEC("tc/egress")
int enforce_vantage_qos(struct __sk_buff *skb) {
	void *data_end = (void *)(long)skb->data_end;
	void *data = (void *)(long)skb->data;

	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end) return 0;
	if (eth->h_proto != 0x0008) return 0;

	struct iphdr *iph = (void *)(eth + 1);
	if ((void *)(iph + 1) > data_end) return 0;

	__u32 dest_ip = iph->daddr;
	__u64 *max_bps = bpf_map_lookup_elem(&vantage_qos_map, &dest_ip);

	if (max_bps && *max_bps > 0) {
		__u64 now = bpf_ktime_get_ns();
		skb->tstamp = now + 1000000;
	}
	return 0;
}

char _license[] SEC("license") = "GPL";
