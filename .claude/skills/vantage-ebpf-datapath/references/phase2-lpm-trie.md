# Phase 2 — LPM_TRIE 5-tuple 정책 키

README 로드맵: `ue_policy_map`을 `(ue_ip, svc_ip, port, proto)` 키의 `BPF_MAP_TYPE_LPM_TRIE`로 교체, 최장 일치 의미론.

## 키 레이아웃 규칙
- LPM_TRIE 키는 반드시 `__u32 prefixlen`으로 시작하고, 이후 데이터는 **매칭 우선순위 순서(상위 비트부터)**로 배치한다. prefixlen은 그 뒤 데이터 비트 수를 센다.
- 최장 일치가 의미 있으려면 "덜 구체적인" 필드가 앞에 와야 한다. 권장 순서: `ue_ip(32) | svc_ip(32) | proto(8) | port(16)` → UE 단위 정책(prefixlen=32)과 UE+서비스 정책(64), 완전 5-tuple(88)이 공존한다.
- 모든 필드는 **네트워크 바이트 순서**로 저장(trie는 바이트열 비트 비교). `port`는 `tcph->dest`/`udph->dest`를 변환 없이 그대로 사용.
- `__attribute__((packed))`로 패딩을 없애고, Rust 쪽은 `#[repr(C, packed)]` + 동일 순서. `contract_check.py`는 packed 속성을 검사하지 않으므로 리뷰에서 수동 확인.
- 맵 정의에 `__uint(map_flags, BPF_F_NO_PREALLOC)` 필수(LPM_TRIE 요구사항).

## 방향별 필드 매핑
| 프로그램 | ue_ip | svc_ip | port |
|---|---|---|---|
| RX (XDP, UL) | `ip->saddr` | `ip->daddr` | L4 `dest` |
| TX (tc, DL) | `ip->daddr` | `ip->saddr` | L4 `source` |

DL에서는 서비스 포트가 source 쪽이라는 점을 놓치기 쉽다.

## 상태 맵
`rx_state_map`/`tx_tstamp_map`은 정책 단위(매칭된 trie 엔트리)별 상태여야 한다. lookup 결과의 엔트리 식별자(예: 값에 `policy_id` 필드 추가)로 상태 맵을 키잉한다 — 그렇지 않으면 같은 UE의 다른 정책이 버킷을 공유한다.

## 파싱
- IP options: `ihl*4` 오프셋으로 L4 헤더를 찾고 경계 재검사.
- 프래그먼트(`frag_off & 0x1FFF != 0`)에는 L4 헤더가 없다 → UE 단위(prefixlen 32) 정책으로 폴백.
- TCP/UDP 이외 proto는 port=0으로 키를 만든다.

## 마이그레이션
맵 type이 바뀌므로 기존 핀(`/sys/fs/bpf/vantage/ue_policy_map`)과 호환되지 않는다. 런북에 `detach.sh` → `unload` → `load` 순서를 명시하도록 testbed-engineer에게 알린다.
