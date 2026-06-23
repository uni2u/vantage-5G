#!/bin/bash
set -e

echo "=== 1. 타겟 파드 및 동적 lxc 인터페이스 자동 검출 ==="
# 접두사를 통해 현재 살아있는 iperf-server 파드 명칭을 자율 포획합니다.
POD_NAME=$(kubectl get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep iperf-server | head -n 1)
POD_IP=$(kubectl get pod $POD_NAME -o jsonpath='{.status.podIP}')
echo "[+] 타겟 파드 명칭: $POD_NAME ($POD_IP)"

# 파드 내부 eth0의 iflink 번호를 낚아챕니다.
IFLINK=$(kubectl exec $POD_NAME -- cat /sys/class/net/eth0/iflink)
# 호스트 커널에서 해당 iflink 번호와 매핑된 진짜 lxc 장치명을 역추적합니다.
TARGET_DEV=$(ip link | grep "^${IFLINK}:" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
echo "[+] 매핑된 커널 가상 인터페이스: $TARGET_DEV"

echo "=== 2. 데이터 평면 관측망(tc filter) 초기화 및 재용접 ==="
sudo tc qdisc del dev $TARGET_DEV clsact 2>/dev/null || true
sudo tc qdisc add dev $TARGET_DEV clsact
sudo tc filter add dev $TARGET_DEV ingress prio 1 bpf pinned /sys/fs/bpf/vantage/vantage_telemetry_sniffer da
sudo tc filter add dev $TARGET_DEV egress prio 1 bpf pinned /sys/fs/bpf/vantage/vantage_telemetry_sniffer da
echo "[+] eBPF 패킷 스니퍼 용접 완료."

echo "=== 3. 파드 내부 iperf3 서버 소켓 백그라운드 영속 가동 ==="
sudo killall iperf3 2>/dev/null || true
kubectl exec $POD_NAME -- sh -c "while true; do iperf3 -s; done" > /dev/null 2>&1 &
echo "[+] iperf3 무한 루프 데몬 가동 완료."
echo "================================================="
echo "🚀 모든 인프라가 재정렬되었습니다. 즉시 실험을 진행하십시오."
