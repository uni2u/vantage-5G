// Vantage-5G v0.2 CLI
// Toy-project scope: administrator manually sets per-UE RX/TX bandwidth
// limits enforced by XDP (RX policer) and tc-bpf EDT (TX pacer) attached
// to the service-node N6-facing NIC.

use std::mem::size_of;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use lazy_static::lazy_static;
use libbpf_rs::{MapFlags, MapHandle, ObjectBuilder};
use prometheus::{opts, register_counter_vec, register_gauge_vec, CounterVec, GaugeVec};

// ---------- Pinned artifact paths ----------
const BPF_PIN_DIR: &str = "/sys/fs/bpf/vantage";

const OBJ_RX: &str = "vantage_rx_policer.o";
const OBJ_TX: &str = "vantage_tx_pacer.o";

const PROG_RX_NAME: &str = "vantage_rx_policer";
const PROG_TX_NAME: &str = "vantage_tx_pacer";

const MAP_POLICY: &str = "ue_policy_map";
const MAP_STATS:  &str = "ue_stats_map";
const MAP_RXST:   &str = "rx_state_map";
const MAP_TXTS:   &str = "tx_tstamp_map";

// ---------- Wire structs (must match the .c files exactly) ----------
#[repr(C)]
#[derive(Copy, Clone, Debug, Default)]
struct UePolicy {
    rx_bps: u64,
    tx_bps: u64,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, Default)]
struct UeStats {
    rx_bytes:   u64,
    rx_packets: u64,
    rx_drops:   u64,
    tx_bytes:   u64,
    tx_packets: u64,
    tx_drops:   u64,
}

fn as_bytes<T: Copy>(v: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts(v as *const T as *const u8, size_of::<T>()) }
}

fn from_bytes<T: Copy + Default>(b: &[u8]) -> T {
    assert!(b.len() >= size_of::<T>());
    let mut out = T::default();
    unsafe {
        std::ptr::copy_nonoverlapping(b.as_ptr(), &mut out as *mut T as *mut u8, size_of::<T>());
    }
    out
}

fn ue_ip_key(ip: Ipv4Addr) -> [u8; 4] {
    // Map keys are stored in network byte order (matches saddr/daddr in BPF).
    ip.octets()
}

// ---------- Prometheus metrics ----------
lazy_static! {
    static ref M_RX_BYTES: CounterVec = register_counter_vec!(
        opts!("vantage_ue_rx_bytes_total", "Per-UE uplink bytes admitted by RX policer"),
        &["ue_ip"]
    ).unwrap();
    static ref M_RX_PACKETS: CounterVec = register_counter_vec!(
        opts!("vantage_ue_rx_packets_total", "Per-UE uplink packets admitted by RX policer"),
        &["ue_ip"]
    ).unwrap();
    static ref M_RX_DROPS: CounterVec = register_counter_vec!(
        opts!("vantage_ue_rx_drops_total", "Per-UE uplink packets dropped by RX policer"),
        &["ue_ip"]
    ).unwrap();
    static ref M_TX_BYTES: CounterVec = register_counter_vec!(
        opts!("vantage_ue_tx_bytes_total", "Per-UE downlink bytes paced by TX pacer"),
        &["ue_ip"]
    ).unwrap();
    static ref M_TX_PACKETS: CounterVec = register_counter_vec!(
        opts!("vantage_ue_tx_packets_total", "Per-UE downlink packets paced by TX pacer"),
        &["ue_ip"]
    ).unwrap();
    static ref M_TX_DROPS: CounterVec = register_counter_vec!(
        opts!("vantage_ue_tx_drops_total", "Per-UE downlink packets dropped (killswitch)"),
        &["ue_ip"]
    ).unwrap();
    static ref M_POLICY_RX: GaugeVec = register_gauge_vec!(
        opts!("vantage_ue_policy_rx_bps", "Configured per-UE RX bandwidth (bps, 0=uncapped)"),
        &["ue_ip"]
    ).unwrap();
    static ref M_POLICY_TX: GaugeVec = register_gauge_vec!(
        opts!("vantage_ue_policy_tx_bps", "Configured per-UE TX bandwidth (bps, 0=killswitch)"),
        &["ue_ip"]
    ).unwrap();
}

// ---------- CLI ----------
#[derive(Parser)]
#[command(name = "vantage-5G", version, about = "Vantage-5G per-UE RX/TX bandwidth control")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Load & pin the RX/TX BPF objects (idempotent). Programs remain in the
    /// kernel after this command exits; use setup.sh to attach them to an iface.
    Load,

    /// Remove all Vantage pins (detaches nothing; run detach.sh first if attached).
    Unload,

    /// Set per-UE RX/TX bandwidth limits (in Mbps). tx_mbps=0 means "block DL".
    Set {
        #[arg(long)] ue_ip: Ipv4Addr,
        #[arg(long)] rx_mbps: u64,
        #[arg(long)] tx_mbps: u64,
    },

    /// Clear the policy for a UE (drop from map; traffic bypasses shaping).
    Reset {
        #[arg(long)] ue_ip: Ipv4Addr,
    },

    /// Print every UE currently in the policy map.
    List,

    /// Print RX/TX counters for one UE (or all UEs when --ue-ip is omitted).
    Stats {
        #[arg(long)] ue_ip: Option<Ipv4Addr>,
    },

    /// Run the Prometheus exporter (foreground). Scrapes pinned stats maps.
    Monitor {
        #[arg(long, default_value_t = 9090)] port: u16,
        #[arg(long, default_value_t = 1000)] scrape_ms: u64,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Load                                => cmd_load(),
        Cmd::Unload                              => cmd_unload(),
        Cmd::Set { ue_ip, rx_mbps, tx_mbps }     => cmd_set(ue_ip, rx_mbps, tx_mbps),
        Cmd::Reset { ue_ip }                     => cmd_reset(ue_ip),
        Cmd::List                                => cmd_list(),
        Cmd::Stats { ue_ip }                     => cmd_stats(ue_ip),
        Cmd::Monitor { port, scrape_ms }         => cmd_monitor(port, scrape_ms),
    }
}

// ---------- load / unload ----------
fn cmd_load() -> Result<()> {
    ensure_pin_dir()?;
    load_and_pin(OBJ_RX, PROG_RX_NAME)?;
    load_and_pin(OBJ_TX, PROG_TX_NAME)?;
    println!("[+] Vantage-5G loaded. Pins under {}", BPF_PIN_DIR);
    println!("    Attach with: sudo ./setup.sh <iface>");
    Ok(())
}

fn cmd_unload() -> Result<()> {
    let root = Path::new(BPF_PIN_DIR);
    if !root.exists() {
        println!("[i] Nothing to remove ({} does not exist)", BPF_PIN_DIR);
        return Ok(());
    }
    // Remove file pins first, then the directory. Detachment (XDP/tc) must
    // already have been undone; otherwise the kernel keeps the objects alive
    // and the .rmdir will just fail harmlessly.
    for entry in std::fs::read_dir(root)? {
        let p = entry?.path();
        let _ = std::fs::remove_file(&p);
    }
    let _ = std::fs::remove_dir(root);
    println!("[+] Vantage-5G pins removed.");
    Ok(())
}

fn ensure_pin_dir() -> Result<()> {
    std::fs::create_dir_all(BPF_PIN_DIR)
        .with_context(|| format!("mkdir {}", BPF_PIN_DIR))
}

fn load_and_pin(obj_file: &str, prog_name: &str) -> Result<()> {
    // If the program is already pinned, treat as no-op (idempotent bootstrap).
    let prog_pin = pin_path(prog_name);
    if prog_pin.exists() {
        println!("[i] {} already pinned, skipping load.", prog_name);
        return Ok(());
    }

    let open = ObjectBuilder::default()
        .open_file(obj_file)
        .with_context(|| format!("open {}", obj_file))?;
    let mut obj = open.load()
        .with_context(|| format!("load {} (verifier/BTF check)", obj_file))?;

    // Pin all maps declared with LIBBPF_PIN_BY_NAME. libbpf handles the
    // shared-map case: the second object sees an already-pinned map and
    // re-uses it instead of creating a new one.
    for map_name in [MAP_POLICY, MAP_STATS, MAP_RXST, MAP_TXTS] {
        if let Some(m) = obj.map_mut(map_name) {
            let p = pin_path(map_name);
            if !p.exists() {
                m.pin(&p).with_context(|| format!("pin map {}", map_name))?;
            }
        }
    }

    let prog = obj.prog_mut(prog_name)
        .ok_or_else(|| anyhow!("program section {} not found in {}", prog_name, obj_file))?;
    prog.pin(&prog_pin).with_context(|| format!("pin prog {}", prog_name))?;

    println!("[+] loaded {} and pinned to {}", prog_name, prog_pin.display());
    Ok(())
}

fn pin_path(name: &str) -> PathBuf {
    PathBuf::from(BPF_PIN_DIR).join(name)
}

// ---------- map helpers ----------
fn open_policy_map() -> Result<MapHandle> {
    MapHandle::from_pinned_path(pin_path(MAP_POLICY))
        .context("open pinned ue_policy_map (run `vantage-5G load` first)")
}
fn open_stats_map() -> Result<MapHandle> {
    MapHandle::from_pinned_path(pin_path(MAP_STATS))
        .context("open pinned ue_stats_map (run `vantage-5G load` first)")
}

// ---------- set / reset ----------
fn cmd_set(ue_ip: Ipv4Addr, rx_mbps: u64, tx_mbps: u64) -> Result<()> {
    let map = open_policy_map()?;
    let key = ue_ip_key(ue_ip);
    let val = UePolicy {
        rx_bps: rx_mbps.saturating_mul(1_000_000),
        tx_bps: tx_mbps.saturating_mul(1_000_000),
    };
    map.update(&key, as_bytes(&val), MapFlags::ANY)
        .with_context(|| format!("update ue_policy_map for {}", ue_ip))?;
    println!("[+] policy set: UE {} rx={} Mbps tx={} Mbps{}",
             ue_ip, rx_mbps, tx_mbps,
             if tx_mbps == 0 { "  (killswitch: DL blocked)" } else { "" });
    Ok(())
}

fn cmd_reset(ue_ip: Ipv4Addr) -> Result<()> {
    let map = open_policy_map()?;
    let key = ue_ip_key(ue_ip);
    match map.delete(&key) {
        Ok(_)  => println!("[+] policy cleared for UE {}", ue_ip),
        Err(e) => println!("[i] no policy for UE {} ({})", ue_ip, e),
    }
    Ok(())
}

// ---------- list / stats ----------
fn cmd_list() -> Result<()> {
    let map = open_policy_map()?;
    println!("{:<16}  {:>12}  {:>12}", "UE_IP", "RX_Mbps", "TX_Mbps");
    let mut n = 0usize;
    for key in map.keys() {
        let val_bytes = map.lookup(&key, MapFlags::empty())?
            .ok_or_else(|| anyhow!("policy entry vanished mid-scan"))?;
        let pol: UePolicy = from_bytes(&val_bytes);
        let ip = key_to_ip(&key)?;
        let killswitch = if pol.tx_bps == 0 { "  (killswitch)" } else { "" };
        println!("{:<16}  {:>12}  {:>12}{}",
                 ip, pol.rx_bps / 1_000_000, pol.tx_bps / 1_000_000, killswitch);
        n += 1;
    }
    if n == 0 {
        println!("(no policies configured)");
    }
    Ok(())
}

fn cmd_stats(filter: Option<Ipv4Addr>) -> Result<()> {
    let map = open_stats_map()?;
    println!("{:<16}  {:>14}  {:>10}  {:>10}  {:>14}  {:>10}  {:>10}",
             "UE_IP", "RX_BYTES", "RX_PKTS", "RX_DROPS", "TX_BYTES", "TX_PKTS", "TX_DROPS");
    let mut n = 0usize;
    for key in map.keys() {
        let ip = key_to_ip(&key)?;
        if let Some(f) = filter { if f != ip { continue; } }
        let val_bytes = map.lookup(&key, MapFlags::empty())?
            .ok_or_else(|| anyhow!("stats entry vanished mid-scan"))?;
        let s: UeStats = from_bytes(&val_bytes);
        println!("{:<16}  {:>14}  {:>10}  {:>10}  {:>14}  {:>10}  {:>10}",
                 ip, s.rx_bytes, s.rx_packets, s.rx_drops,
                 s.tx_bytes, s.tx_packets, s.tx_drops);
        n += 1;
    }
    if n == 0 {
        println!("(no stats yet — is traffic flowing and the interface attached?)");
    }
    Ok(())
}

fn key_to_ip(k: &[u8]) -> Result<Ipv4Addr> {
    if k.len() < 4 { bail!("short key: {} bytes", k.len()); }
    Ok(Ipv4Addr::new(k[0], k[1], k[2], k[3]))
}

// ---------- monitor (Prometheus exporter) ----------
fn cmd_monitor(port: u16, scrape_ms: u64) -> Result<()> {
    let policy = open_policy_map()?;
    let stats  = open_stats_map()?;

    let bind: std::net::SocketAddr = format!("0.0.0.0:{}", port).parse()?;
    prometheus_exporter::start(bind)
        .with_context(|| format!("start Prometheus exporter on {}", bind))?;
    println!("[+] Prometheus exporter listening on http://0.0.0.0:{}/metrics", port);
    println!("    scraping BPF maps every {} ms.  Ctrl-C to stop.", scrape_ms);

    loop {
        scrape_policy_into_gauges(&policy)?;
        scrape_stats_into_counters(&stats)?;
        thread::sleep(Duration::from_millis(scrape_ms));
    }
}

fn scrape_policy_into_gauges(map: &MapHandle) -> Result<()> {
    for key in map.keys() {
        let ip = key_to_ip(&key)?;
        let val_bytes = match map.lookup(&key, MapFlags::empty())? {
            Some(v) => v, None => continue,
        };
        let pol: UePolicy = from_bytes(&val_bytes);
        let ip_str = ip.to_string();
        M_POLICY_RX.with_label_values(&[&ip_str]).set(pol.rx_bps as f64);
        M_POLICY_TX.with_label_values(&[&ip_str]).set(pol.tx_bps as f64);
    }
    Ok(())
}

fn scrape_stats_into_counters(map: &MapHandle) -> Result<()> {
    // Counters are monotonic; we mirror BPF absolute values as reset-only-on-restart.
    for key in map.keys() {
        let ip = key_to_ip(&key)?;
        let val_bytes = match map.lookup(&key, MapFlags::empty())? {
            Some(v) => v, None => continue,
        };
        let s: UeStats = from_bytes(&val_bytes);
        let ip_str = ip.to_string();
        set_counter(&M_RX_BYTES,   &ip_str, s.rx_bytes);
        set_counter(&M_RX_PACKETS, &ip_str, s.rx_packets);
        set_counter(&M_RX_DROPS,   &ip_str, s.rx_drops);
        set_counter(&M_TX_BYTES,   &ip_str, s.tx_bytes);
        set_counter(&M_TX_PACKETS, &ip_str, s.tx_packets);
        set_counter(&M_TX_DROPS,   &ip_str, s.tx_drops);
    }
    Ok(())
}

fn set_counter(cv: &CounterVec, label: &str, value: u64) {
    let c = cv.with_label_values(&[label]);
    let cur = c.get();
    let want = value as f64;
    if want > cur {
        c.inc_by(want - cur);
    }
    // want < cur happens only when the BPF map was reset (unload/reload);
    // in that case we accept the discrepancy for this scrape and re-align
    // on the next tick when the BPF counter grows past `cur`.
}
