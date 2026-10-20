# Grafana dashboard — `vantage-5g.json`

Per-UE view of the Vantage-5G exporter (`vantage-5G monitor`, README §7): realized UL/DL
throughput against the configured cap, the ±10 % verdict band of README §8, drops, packet
rate and the policy table (killswitch shown explicitly). It uses only the eight series
listed in README §7; no exporter change is needed.

Checked with Grafana 11.2.0 and Prometheus 2.54.1 (`testbed/grafana`): the dashboard is
provisioned and every panel query returns without error, and the policy-table
transformations were run with `@grafana/data` 11.2.0 outside a browser. Rendering in the
Grafana UI has not been checked yet (VERIFY-L4). `schemaVersion` is 39, so Grafana 10.4+ is
expected to load it — not tested.

## 1. Let Prometheus scrape the exporter

The exporter serves `http://<bind>:<port>/metrics` (default port 9090). With the systemd
units (README §5a) the example env file binds **127.0.0.1**, so a Prometheus on another
host cannot reach it. For remote scraping, bind the management-network address, never the
N6 side where UE traffic arrives:

In `/etc/vantage-5g/vantage-5g.env` (an env file, not a shell command):

```ini
MONITOR_ARGS=--bind 192.0.2.10 --port 9090
```

Then, in a shell:

```bash
sudo systemctl restart vantage-5g-monitor
# allow only the Prometheus host, e.g. with ufw:
sudo ufw allow from 192.0.2.50 to 192.0.2.10 port 9090 proto tcp
```

(Running the CLI by hand: `monitor` without `--bind` listens on 0.0.0.0 — restrict it with
a firewall the same way.) A Prometheus on the Vantage node itself can keep 127.0.0.1.

`prometheus.yml`:

```yaml
scrape_configs:
  - job_name: vantage-5g
    scrape_interval: 5s          # 1s for short iperf3 measurements
    static_configs:
      - targets: ["192.0.2.10:9090"]
```

The *Exporter scrape* panel queries `up{job="vantage-5g", ...}` so that other targets (e.g.
node_exporter) do not turn it red. **If you change `job_name`, change `job="vantage-5g"` in
that panel's query too**, or it shows *No data*. The other panels select on
`vantage_ue_*` series and do not depend on the job name.

Pick the dashboard's **rate window** at least 3 x the scrape interval. The default 15 s
assumes a scrape interval of **5 s or less**; with a slower scrape choose a longer window or
`$__rate_interval` (Grafana's max(4 x scrape interval, step + scrape interval); set the data
source's *Scrape interval* to match Prometheus). With a 1 s scrape the 5 s window of the
README §7 PromQL works. A window shorter than two scrapes shows no data.
`monitor --scrape-ms` (BPF map read period, default 1000 ms) should not be slower than the
Prometheus scrape interval.

## 2. Import

- **UI:** Dashboards → New → Import → upload `vantage-5g.json`, then pick your Prometheus
  data source in the *Prometheus* drop-down at the top of the dashboard (the `DS_PROMETHEUS`
  variable; every panel uses it).
- **Provisioning:** point a file provider at this directory (only `*.json` is read):

  ```yaml
  # /etc/grafana/provisioning/dashboards/vantage.yml
  apiVersion: 1
  providers:
    - name: vantage
      folder: Vantage-5G
      type: file
      options: {path: /path/to/vantage-5G/dashboards}
  ```

  The `DS_PROMETHEUS` variable then defaults to the default Prometheus data source.

Dashboard uid: `vantage-5g`.

## 3. Variables

| Variable | Meaning |
|---|---|
| Prometheus (`DS_PROMETHEUS`) | data source |
| Exporter (`instance`) | exporter target(s), multi-select, from any `vantage_ue_*` series (an exporter with no UE series is not listed; *All* still includes it in *Exporter scrape*) |
| UE (`ue_ip`) | UE IPv4(s), multi-select |
| rate window (`rate_window`) | `rate()` range: 5s / 10s / 15s (default, needs scrape ≤ 5 s) / 30s / 1m / 5m / `$__rate_interval` |

## 4. Panels and PromQL

`SEL` = `instance=~"$instance", ue_ip=~"$ue_ip"`, `W` = `$rate_window`.

| Panel | PromQL |
|---|---|
| UEs with a policy | `count(vantage_ue_policy_tx_bps{SEL}) or vector(0)` |
| Killswitch UEs (TX cap 0) | `count(vantage_ue_policy_tx_bps{SEL} == 0) or vector(0)` |
| UEs with counters but no policy | `count(max by (instance, ue_ip) (vantage_ue_tx_bytes_total{SEL}) unless on (instance, ue_ip) vantage_ue_policy_tx_bps) or vector(0)` |
| Exporter scrape | `min(up{job="vantage-5g", instance=~"$instance"})` |
| DL throughput vs cap | `rate(vantage_ue_tx_bytes_total{SEL}[W]) * 8`, cap `vantage_ue_policy_tx_bps{SEL} > 0` (dashed) |
| UL throughput vs cap | `rate(vantage_ue_rx_bytes_total{SEL}[W]) * 8`, cap `vantage_ue_policy_rx_bps{SEL} > 0` (dashed) |
| DL realized / TX cap (%) | `100 * rate(vantage_ue_tx_bytes_total{SEL}[W]) * 8 / on (instance, ue_ip) (vantage_ue_policy_tx_bps > 0)` |
| UL realized / RX cap (%) | `100 * rate(vantage_ue_rx_bytes_total{SEL}[W]) * 8 / on (instance, ue_ip) (vantage_ue_policy_rx_bps > 0)` |
| DL drops/s | `rate(vantage_ue_tx_drops_total{SEL}[W])` |
| UL drops/s | `rate(vantage_ue_rx_drops_total{SEL}[W])` |
| UL drop ratio | `rate(rx_drops[W]) / (rate(rx_packets[W]) + rate(rx_drops[W]))` |
| Packet rate | `rate(vantage_ue_rx_packets_total{SEL}[W])`, `rate(vantage_ue_tx_packets_total{SEL}[W])` |
| Policy table | instant `vantage_ue_policy_{rx,tx}_bps`, current UL/DL rate, both ratios, DL drops/s, each `max by (instance, ue_ip)`, merged on (`ue_ip`, `instance`): one row per UE per exporter |

Annotation *Counter reset*: `resets(vantage_ue_{tx,rx}_bytes_total[1m]) > 0` per UE.

## 5. Reading it

- **Units.** Byte counters and caps are L2 frame bytes (Ethernet header included; contract
  X3 option B), so a saturated UE sits at ≈ 100 % of its cap; iperf3 goodput is a few %
  lower. The 90 % / 110 % lines are the README §8 ±10 % band. The ratio is only meaningful
  while the UE offers more than its cap.
- **Killswitch** (`tx_bps = 0`): excluded from the DL cap line and the DL ratio (no division
  by 0); shown in the *Killswitch UEs* stat and as `KILLSWITCH` in the policy table. All its
  DL packets appear in *DL drops/s*. `rx_bps = 0` means *uncapped* (shown as `uncapped`, no
  UL ratio).
- **DL drops** are killswitch drops plus the EDT horizon (> 2 s ahead, i.e. DL offered far
  above the cap, a UDP flood). A capped TCP flow normally shows ~0.
- **Counter resets.** Counters restart from 0 after `unload → load` (new maps), an LRU
  eviction, or a monitor restart. `rate()`/`increase()` handle it; the annotation marks it.
  The annotation uses `resets(...[1m])`, so a restart after a gap longer than about 1 min
  (e.g. a 2 min stop for maintenance) is not marked; `rate()` is not affected.
  `monitor` re-opens the pins every scrape, so it needs no restart after a reload.
- **Disappearing series.** `reset` removes the UE's policy gauges: it leaves the policy
  table and the cap/ratio panels. Its counters stay (frozen: unshaped UEs are not counted)
  and are listed by *UEs with counters but no policy* — that UE is **not** shaped. An LRU
  eviction from `ue_stats_map` removes the counter series. After `unload` every Vantage
  series disappears while `up` stays 1.
- **Several Vantage nodes.** Two nodes can carry the same UE IP (Open5GS's default pool is
  10.45.0.0/16 on every UPF). The policy table has one row per (UE, exporter) with an
  *exporter* column. Time-series legends show only `ue_ip` (the series stay separate but
  share a name) — select one *Exporter* to tell them apart.
- **Packets.** UL counts frames admitted by XDP (xdpgeneric: after GRO), DL counts wire
  segments; the two are not comparable.

## 6. Local test

`testbed/grafana/docker-compose.yml` runs Prometheus (127.0.0.1:19091) and Grafana
(127.0.0.1:13000, admin / `vantage`) on Docker Desktop with this directory mounted as is.
Prometheus scrapes `host.docker.internal:19090`, e.g. the L2 VM's exporter through a
VirtualBox NAT forward:

```bash
VBoxManage controlvm vantage-svc natpf1 "vtprom,tcp,127.0.0.1,19090,,9090"
# in the VM (test only): sudo ./target/release/vantage-5G monitor --bind 0.0.0.0
docker compose -f testbed/grafana/docker-compose.yml up -d
# ...
docker compose -f testbed/grafana/docker-compose.yml down -v
VBoxManage controlvm vantage-svc natpf1 delete vtprom
```
