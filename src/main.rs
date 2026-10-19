// Vantage-5G v0.2 CLI
// Toy-project scope: administrator manually sets per-UE RX/TX bandwidth
// limits enforced by XDP (RX policer) and tc-bpf EDT (TX pacer) attached
// to the service-node N6-facing NIC.

use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::mem::size_of;
use std::net::Ipv4Addr;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use lazy_static::lazy_static;
use libbpf_rs::{AsRawLibbpf, ErrorKind, MapFlags, MapHandle, ObjectBuilder, OpenObject};
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

// Kernel prog names are truncated to BPF_OBJ_NAME_LEN-1 = 15 chars.
const KNAME_RX: &str = "vantage_rx_poli";
const KNAME_TX: &str = "vantage_tx_pace";
// setup.sh attaches the TX pacer at egress pref 1 handle 1; setup.sh before
// the pref fix used `tc filter add` without pref (auto pref 49152, handle 1).
const TC_SLOTS: [(u32, u32); 2] = [(1, 1), (49152, 1)];

// Upper bound for --rx-mbps/--tx-mbps (D11): 400 Gbps, the fastest single
// Ethernet port in common use, so anything above is a typo. It matches the
// datapath's RX clamp exactly: 4e11 bit/s / 8 = 5e10 B/s = RX_BYTES_PER_SEC_MAX
// (vantage_rx_policer.c), so no accepted value is silently clamped. RX
// arithmetic at that bound: cap = bps/4 <= 1.25e10 B, fill_ns = cap*1e9/bps
// (cap*1e9 <= 1.25e19 < 2^64), and refill = elapsed*bps/1e9 only runs for
// elapsed < fill_ns, so elapsed*bps < cap*1e9 < 2^64.
//   - TX delay (skb->len * 8e9 / tx_bps) does not depend on tx_bps for
//     overflow; at 400 Gbps a 64 B frame still gets a 1 ns slot.
const MAX_MBPS: u64 = 400_000;

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
    // Exact length: a size change on the C side must fail loudly here instead
    // of silently decoding only the leading fields.
    assert_eq!(b.len(), size_of::<T>(), "map value size != size_of::<{}>()", std::any::type_name::<T>());
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
        opts!("vantage_ue_tx_drops_total", "Per-UE downlink packets dropped (killswitch or EDT horizon > 2 s)"),
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

    /// Remove all Vantage pins. Refuses while a Vantage program is still
    /// attached to an interface in this network namespace (run detach.sh first).
    Unload,

    /// Set per-UE RX/TX bandwidth limits (in Mbps, 0..=400000).
    /// rx_mbps=0 means "RX uncapped", tx_mbps=0 means "block DL".
    Set {
        #[arg(long)] ue_ip: Ipv4Addr,
        #[arg(long, value_parser = clap::value_parser!(u64).range(0..=MAX_MBPS))] rx_mbps: u64,
        #[arg(long, value_parser = clap::value_parser!(u64).range(0..=MAX_MBPS))] tx_mbps: u64,
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

const UPGRADE_HINT: &str = "upgrade procedure (map definitions changed in the .o):\n      \
     sudo ./detach.sh <iface>; sudo ./target/release/vantage-5G unload;\n      \
     sudo ./target/release/vantage-5G load; sudo ./setup.sh <iface>\n    \
     (policies are lost: re-run `set` for every UE afterwards)";

fn cmd_unload() -> Result<()> {
    let root = Path::new(BPF_PIN_DIR);
    if !root.exists() {
        println!("[i] Nothing to remove ({} does not exist)", BPF_PIN_DIR);
        return Ok(());
    }
    // bpffs unlink/rmdir succeed even while programs are still attached; an
    // attached program then keeps running with its (now unpinned) maps, which
    // the CLI can no longer reach, and the next `load` creates fresh maps that
    // the running program never reads. So refuse while anything is attached.
    // bpf_tc_query on an iface without clsact makes libbpf print the kernel
    // extack ("Parent Qdisc doesn't exists") for every interface; silence
    // libbpf while probing and restore its printer afterwards.
    let prev = libbpf_rs::set_print(None);
    let attached = vantage_attachments();
    libbpf_rs::set_print(prev);
    let attached = attached?;
    if !attached.is_empty() {
        eprintln!("[-] Vantage programs are still attached:");
        for a in &attached {
            eprintln!("      {}", a);
        }
        let mut ifs: Vec<&str> = attached.iter().map(|a| a.ifname.as_str()).collect();
        ifs.dedup();
        for i in ifs {
            eprintln!("    run: sudo ./detach.sh {}", i);
        }
        bail!("refusing to unload while attached (pins left untouched)");
    }
    // Remove file pins first, then the directory.
    let mut failed = Vec::new();
    for entry in std::fs::read_dir(root)? {
        let p = entry?.path();
        if let Err(e) = std::fs::remove_file(&p) {
            failed.push(format!("{}: {}", p.display(), e));
        }
    }
    if let Err(e) = std::fs::remove_dir(root) {
        failed.push(format!("{}: {}", root.display(), e));
    }
    if !failed.is_empty() {
        bail!("could not remove: {}", failed.join("; "));
    }
    println!("[+] Vantage-5G pins removed.");
    Ok(())
}

// ---------- attach detection (unload guard, D14) ----------
struct Attachment {
    ifname: String,
    hook:   String,
    id:     u32,
    name:   String,
}

impl std::fmt::Display for Attachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {} prog id {} ({})", self.ifname, self.hook, self.id, self.name)
    }
}

/// Program id of a bpffs pin, or None if the pin does not exist.
fn pinned_prog_id(path: &Path) -> Result<Option<u32>> {
    if !path.exists() {
        return Ok(None);
    }
    let c = CString::new(path.as_os_str().as_encoded_bytes())?;
    let fd = unsafe { libbpf_sys::bpf_obj_get(c.as_ptr()) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("open pin {}", path.display()));
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let id = libbpf_rs::Program::get_id_by_fd(fd.as_fd())
        .with_context(|| format!("prog id of {}", path.display()))?;
    Ok(Some(id))
}

/// Kernel name of BPF prog `id` ("" if it cannot be read).
fn prog_name_by_id(id: u32) -> String {
    let Ok(fd) = libbpf_rs::Program::get_fd_by_id(id) else { return String::new() };
    let mut info = libbpf_sys::bpf_prog_info::default();
    let mut len = size_of::<libbpf_sys::bpf_prog_info>() as u32;
    let ret = unsafe { libbpf_sys::bpf_prog_get_info_by_fd(fd.as_raw_fd(), &mut info, &mut len) };
    if ret != 0 {
        return String::new();
    }
    unsafe { CStr::from_ptr(info.name.as_ptr()) }.to_string_lossy().into_owned()
}

/// Every Vantage program attached (XDP any mode, tc egress at the setup.sh
/// slots) to an interface of the current network namespace. A program counts
/// as Vantage if its id is a pinned program's id, or its kernel name is a
/// Vantage name (an instance left attached from an earlier `load`).
/// Uses the kernel netlink API via libbpf (bpf_xdp_query / bpf_tc_query), so
/// it does not depend on iproute2/bpftool output formats.
fn vantage_attachments() -> Result<Vec<Attachment>> {
    let mut pinned = HashSet::new();
    for p in [PROG_RX_NAME, PROG_TX_NAME] {
        if let Some(id) = pinned_prog_id(&pin_path(p))? {
            pinned.insert(id);
        }
    }
    let classify = |id: u32| -> Option<String> {
        let name = prog_name_by_id(id);
        if pinned.contains(&id) || name.starts_with(KNAME_RX) || name.starts_with(KNAME_TX) {
            Some(if name.is_empty() { "?".into() } else { name })
        } else {
            None
        }
    };

    let mut out = Vec::new();
    let mut ifaces: Vec<(String, i32)> = Vec::new();
    for e in std::fs::read_dir("/sys/class/net").context("list /sys/class/net")? {
        let e = e?;
        let ifname = e.file_name().to_string_lossy().into_owned();
        let Ok(s) = std::fs::read_to_string(e.path().join("ifindex")) else { continue };
        let Ok(ifindex) = s.trim().parse::<i32>() else { continue };
        ifaces.push((ifname, ifindex));
    }
    ifaces.sort();

    for (ifname, ifindex) in ifaces {
        // XDP: one query returns the id in every mode slot.
        let mut q = libbpf_sys::bpf_xdp_query_opts {
            sz: size_of::<libbpf_sys::bpf_xdp_query_opts>() as _,
            ..Default::default()
        };
        let ret = unsafe { libbpf_sys::bpf_xdp_query(ifindex, 0, &mut q) };
        if ret < 0 {
            // Interface vanished mid-scan is fine; anything else (EPERM)
            // means we cannot prove nothing is attached.
            if -ret != libc_errno::ENOENT && -ret != libc_errno::ENODEV {
                return Err(std::io::Error::from_raw_os_error(-ret))
                    .with_context(|| format!("query XDP on {}", ifname));
            }
        } else {
            for (hook, id) in [("xdpgeneric", q.skb_prog_id), ("xdp(native)", q.drv_prog_id),
                               ("xdpoffload", q.hw_prog_id)] {
                if id == 0 { continue; }
                if let Some(name) = classify(id) {
                    out.push(Attachment { ifname: ifname.clone(), hook: hook.into(), id, name });
                }
            }
        }
        // tc egress at the slots setup.sh uses (current and pre-fix auto pref).
        for (prio, handle) in TC_SLOTS {
            let hook = libbpf_sys::bpf_tc_hook {
                sz: size_of::<libbpf_sys::bpf_tc_hook>() as _,
                ifindex,
                attach_point: libbpf_sys::BPF_TC_EGRESS,
                ..Default::default()
            };
            let mut opts = libbpf_sys::bpf_tc_opts {
                sz: size_of::<libbpf_sys::bpf_tc_opts>() as _,
                handle,
                priority: prio,
                ..Default::default()
            };
            let ret = unsafe { libbpf_sys::bpf_tc_query(&hook, &mut opts) };
            if ret < 0 {
                // ENOENT: no such filter; EINVAL: no clsact qdisc on this iface.
                match -ret {
                    libc_errno::ENOENT | libc_errno::EINVAL | libc_errno::ENODEV => continue,
                    e => return Err(std::io::Error::from_raw_os_error(e))
                        .with_context(|| format!("query tc egress on {}", ifname)),
                }
            }
            if let Some(name) = classify(opts.prog_id) {
                out.push(Attachment {
                    ifname: ifname.clone(),
                    hook: format!("tc egress pref {} handle {}", prio, handle),
                    id: opts.prog_id,
                    name,
                });
            }
        }
    }
    Ok(out)
}

// errno values used above (Linux, all architectures we build for).
mod libc_errno {
    pub const ENOENT: i32 = 2;
    pub const ENODEV: i32 = 19;
    pub const EINVAL: i32 = 22;
}

fn ensure_pin_dir() -> Result<()> {
    std::fs::create_dir_all(BPF_PIN_DIR)
        .with_context(|| format!("mkdir {}", BPF_PIN_DIR))
}

/// Compare every map of `open` that already has a pin under BPF_PIN_DIR with
/// that pin's definition, the same fields libbpf's map_is_reuse_compat()
/// checks. Returns one line per mismatch.
fn pinned_map_mismatches(open: &OpenObject) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for m in open.maps_iter() {
        let name = m.name()?.to_string();
        let pin = pin_path(&name);
        if !pin.exists() {
            continue;
        }
        let have = MapHandle::from_pinned_path(&pin)
            .with_context(|| format!("open pinned {}", pin.display()))?
            .info()
            .with_context(|| format!("info of pinned {}", pin.display()))?
            .info;
        let raw = m.as_libbpf_object().as_ptr();
        let (ty, ks, vs, me, fl) = unsafe {
            (libbpf_sys::bpf_map__type(raw), libbpf_sys::bpf_map__key_size(raw),
             libbpf_sys::bpf_map__value_size(raw), libbpf_sys::bpf_map__max_entries(raw),
             libbpf_sys::bpf_map__map_flags(raw))
        };
        let mut diff = Vec::new();
        if have.type_ != ty         { diff.push(format!("type {:?} -> {:?}", libbpf_rs::MapType::from(have.type_), libbpf_rs::MapType::from(ty))); }
        if have.key_size != ks    { diff.push(format!("key_size {} -> {}", have.key_size, ks)); }
        if have.value_size != vs  { diff.push(format!("value_size {} -> {}", have.value_size, vs)); }
        if have.max_entries != me { diff.push(format!("max_entries {} -> {}", have.max_entries, me)); }
        if have.map_flags != fl   { diff.push(format!("map_flags {:#x} -> {:#x}", have.map_flags, fl)); }
        if !diff.is_empty() {
            out.push(format!("{} (pinned -> .o): {}", name, diff.join(", ")));
        }
    }
    Ok(out)
}

fn load_and_pin(obj_file: &str, prog_name: &str) -> Result<()> {
    // All maps in both objects are declared LIBBPF_PIN_BY_NAME. With
    // pin_root_path set, libbpf computes each map's pin path at open time
    // as <BPF_PIN_DIR>/<map name>, and during load() either re-uses an
    // already-pinned map at that path (the shared ue_policy_map/ue_stats_map
    // for the second object) or creates the map and pins it there. No manual
    // bpf_map__pin() is needed; pinning to a different path would fail with
    // -EINVAL ("already has pin path ... different from ...").
    let open = ObjectBuilder::default()
        .pin_root_path(BPF_PIN_DIR)
        .with_context(|| format!("pin_root_path {}", BPF_PIN_DIR))?
        .open_file(obj_file)
        .with_context(|| format!("open {}", obj_file))?;

    // A pinned map whose definition differs from the .o (e.g. HASH -> LRU_HASH)
    // makes libbpf fail with "couldn't reuse pinned map ... parameter
    // mismatch" / EINVAL. Detect it up front and say what to do. This also
    // runs when the program is already pinned, so loading a rebuilt .o with
    // changed maps is not silently skipped.
    let mism = pinned_map_mismatches(&open)?;
    if !mism.is_empty() {
        eprintln!("[-] {}: pinned maps under {} do not match the object:", obj_file, BPF_PIN_DIR);
        for l in &mism {
            eprintln!("      {}", l);
        }
        eprintln!("    {}", UPGRADE_HINT);
        bail!("pinned map definition mismatch for {}", obj_file);
    }

    // If the program is already pinned, treat as no-op (idempotent bootstrap).
    let prog_pin = pin_path(prog_name);
    if prog_pin.exists() {
        println!("[i] {} already pinned, skipping load.", prog_name);
        return Ok(());
    }

    let mut obj = match open.load() {
        Ok(o) => o,
        Err(e) => {
            let hint = match e.kind() {
                ErrorKind::InvalidInput => format!(
                    "load {}: EINVAL. Either the verifier rejected a program (see the libbpf log \
                     above) or a pinned map under {} could not be reused (\"parameter mismatch\" \
                     above); for the latter: {}", obj_file, BPF_PIN_DIR, UPGRADE_HINT),
                ErrorKind::PermissionDenied => format!(
                    "load {}: permission denied (needs root / CAP_BPF+CAP_NET_ADMIN), or the \
                     verifier rejected a program (EACCES, see the libbpf log above)", obj_file),
                _ => format!("load {} (see the libbpf log above)", obj_file),
            };
            return Err(anyhow::Error::new(e).context(hint));
        }
    };

    // Sanity check: every map this object declares must now be pinned under
    // BPF_PIN_DIR (catches a map that lost its LIBBPF_PIN_BY_NAME attribute).
    for map_name in [MAP_POLICY, MAP_STATS, MAP_RXST, MAP_TXTS] {
        if let Some(m) = obj.map(map_name) {
            let want = pin_path(map_name);
            let got = m.get_pin_path().map(PathBuf::from);
            if !m.is_pinned() || got.as_deref() != Some(want.as_path()) {
                bail!("map {} not pinned at {} (pin path: {:?}); is it LIBBPF_PIN_BY_NAME?",
                      map_name, want.display(), got);
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
fn open_map(name: &str) -> Result<MapHandle> {
    MapHandle::from_pinned_path(pin_path(name))
        .with_context(|| format!("open pinned {} (run `vantage-5G load` first; needs root)", name))
}
fn open_policy_map() -> Result<MapHandle> { open_map(MAP_POLICY) }
fn open_stats_map()  -> Result<MapHandle> { open_map(MAP_STATS) }

/// Delete `key`; Ok(true) if deleted, Ok(false) if it was not there (ENOENT),
/// Err for anything else (EPERM, ...).
fn delete_key(map: &MapHandle, key: &[u8]) -> Result<bool> {
    match map.delete(key) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(false),
        Err(e) => Err(anyhow::Error::new(e)).with_context(|| format!("delete from {}", map.name())),
    }
}

/// Drop the per-UE datapath state (RX token bucket, TX EDT slot) so the next
/// packet re-initialises it under the current policy (D7). A stale future
/// tx_tstamp would otherwise keep DL stalled after reset/set.
fn clear_ue_state(key: &[u8]) -> Result<()> {
    for name in [MAP_RXST, MAP_TXTS] {
        let m = open_map(name)?;
        delete_key(&m, key)?;
    }
    Ok(())
}

// ---------- set / reset ----------
fn cmd_set(ue_ip: Ipv4Addr, rx_mbps: u64, tx_mbps: u64) -> Result<()> {
    let map = open_policy_map()?;
    let key = ue_ip_key(ue_ip);
    // clap bounds both values to 0..=MAX_MBPS, so the products fit easily.
    let val = UePolicy {
        rx_bps: rx_mbps * 1_000_000,
        tx_bps: tx_mbps * 1_000_000,
    };
    // D26: re-applying the same policy (periodic reconcile, boot scripts)
    // must not refill the RX bucket or forget the TX backlog each time.
    let unchanged = match map.lookup(&key, MapFlags::empty())
        .with_context(|| format!("lookup ue_policy_map for {}", ue_ip))?
    {
        Some(b) => {
            let old: UePolicy = from_bytes(&b);
            old.rx_bps == val.rx_bps && old.tx_bps == val.tx_bps
        }
        None => false,
    };
    map.update(&key, as_bytes(&val), MapFlags::ANY)
        .with_context(|| format!("update ue_policy_map for {}", ue_ip))?;
    if !unchanged {
        // Policy first, then state: a packet racing in between re-creates the
        // state under the new policy.
        clear_ue_state(&key)
            .with_context(|| format!("policy for {} WAS updated, but clearing its rx/tx state failed", ue_ip))?;
    }
    println!("[+] policy set: UE {} rx={} Mbps tx={} Mbps{}{}",
             ue_ip, rx_mbps, tx_mbps,
             if tx_mbps == 0 { "  (killswitch: DL blocked)" } else { "" },
             if unchanged { "  (unchanged; rx/tx state kept)" } else { "" });
    Ok(())
}

fn cmd_reset(ue_ip: Ipv4Addr) -> Result<()> {
    let map = open_policy_map()?;
    let key = ue_ip_key(ue_ip);
    let existed = delete_key(&map, &key)
        .with_context(|| format!("reset policy for {}", ue_ip))?;
    clear_ue_state(&key)
        .with_context(|| format!("clear rx/tx state for {}", ue_ip))?;
    if existed {
        println!("[+] policy cleared for UE {}", ue_ip);
    } else {
        println!("[i] no policy for UE {} (nothing to clear)", ue_ip);
    }
    Ok(())
}

// ---------- list / stats ----------
fn cmd_list() -> Result<()> {
    let map = open_policy_map()?;
    println!("{:<16}  {:>12}  {:>12}", "UE_IP", "RX_Mbps", "TX_Mbps");
    let mut n = 0usize;
    for key in map.keys() {
        let val_bytes = match map.lookup(&key, MapFlags::empty())? {
            Some(v) => v, None => continue,   // deleted mid-scan
        };
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
        let val_bytes = match map.lookup(&key, MapFlags::empty())? {
            Some(v) => v, None => continue,   // LRU-evicted mid-scan
        };
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
    if k.len() != 4 { bail!("bad key length: {} bytes (expected 4)", k.len()); }
    Ok(Ipv4Addr::new(k[0], k[1], k[2], k[3]))
}

// ---------- monitor (Prometheus exporter) ----------
//
// The pinned maps are re-opened on every scrape (D8): after
// detach -> unload -> load -> setup the pins point at new maps, and a FD
// opened at start-up would keep reading the old, now-dead map forever. A map
// id change is logged and all series are re-based on the new map. Errors
// (maps not loaded yet, unloaded, EPERM, ...) are logged once per distinct
// message and retried on the next tick; monitor never exits on them.

#[derive(Default)]
struct MonitorState {
    policy_id:     Option<u32>,
    stats_id:      Option<u32>,
    policy_labels: HashSet<String>,
    stats_labels:  HashSet<String>,
    last_err:      Option<String>,
}

fn all_counters() -> [&'static CounterVec; 6] {
    [&M_RX_BYTES, &M_RX_PACKETS, &M_RX_DROPS, &M_TX_BYTES, &M_TX_PACKETS, &M_TX_DROPS]
}

fn cmd_monitor(port: u16, scrape_ms: u64) -> Result<()> {
    let bind: std::net::SocketAddr = format!("0.0.0.0:{}", port).parse()?;
    prometheus_exporter::start(bind)
        .with_context(|| format!("start Prometheus exporter on {}", bind))?;
    println!("[+] Prometheus exporter listening on http://0.0.0.0:{}/metrics", port);
    println!("    scraping BPF maps every {} ms (pins re-opened each scrape).  Ctrl-C to stop.", scrape_ms);

    let mut st = MonitorState::default();
    loop {
        match scrape_once(&mut st) {
            Ok(()) => {
                if st.last_err.take().is_some() {
                    println!("[+] scraping recovered");
                }
            }
            Err(e) => {
                let msg = format!("{:#}", e);
                if st.last_err.as_deref() != Some(msg.as_str()) {
                    eprintln!("[!] scrape failed (will retry every {} ms): {}", scrape_ms, msg);
                    st.last_err = Some(msg);
                }
            }
        }
        thread::sleep(Duration::from_millis(scrape_ms));
    }
}

fn scrape_once(st: &mut MonitorState) -> Result<()> {
    // Policy gauges.
    match open_policy_map() {
        Ok(policy) => {
            let id = policy.info()?.info.id;
            if st.policy_id.is_some_and(|old| old != id) {
                println!("[i] {} changed (map id {} -> {}): policy gauges re-read",
                         MAP_POLICY, st.policy_id.unwrap(), id);
            }
            st.policy_id = Some(id);
            scrape_policy_into_gauges(&policy, &mut st.policy_labels)?;
        }
        Err(e) => {
            forget_if_unloaded(&e, st);
            return Err(e);
        }
    }
    // Stats counters.
    match open_stats_map() {
        Ok(stats) => {
            let id = stats.info()?.info.id;
            if let Some(old) = st.stats_id.filter(|old| *old != id) {
                // New map instance: its counters start from 0. Drop every
                // series so the exported values become the new absolute ones
                // (Prometheus treats the drop as a counter reset).
                println!("[i] {} changed (map id {} -> {}): counters re-based", MAP_STATS, old, id);
                for c in all_counters() { c.reset(); }
                st.stats_labels.clear();
            }
            st.stats_id = Some(id);
            scrape_stats_into_counters(&stats, &mut st.stats_labels)?;
        }
        Err(e) => {
            forget_if_unloaded(&e, st);
            return Err(e);
        }
    }
    Ok(())
}

/// Pins gone (unload) -> the state they described is gone too; drop all
/// series instead of exporting stale policy/counters forever. Any other
/// open error (EPERM, ...) keeps the last values.
fn forget_if_unloaded(e: &anyhow::Error, st: &mut MonitorState) {
    let gone = e.chain().any(|c| {
        c.downcast_ref::<libbpf_rs::Error>().is_some_and(|le| le.kind() == ErrorKind::NotFound)
    });
    if gone {
        M_POLICY_RX.reset();
        M_POLICY_TX.reset();
        for c in all_counters() { c.reset(); }
        st.policy_labels.clear();
        st.stats_labels.clear();
        st.policy_id = None;
        st.stats_id = None;
    }
}

fn scrape_policy_into_gauges(map: &MapHandle, labels: &mut HashSet<String>) -> Result<()> {
    let mut seen = HashSet::new();
    for key in map.keys() {
        let Ok(ip) = key_to_ip(&key) else { continue };
        let val_bytes = match map.lookup(&key, MapFlags::empty())? {
            Some(v) => v, None => continue,
        };
        let pol: UePolicy = from_bytes(&val_bytes);
        let ip_str = ip.to_string();
        M_POLICY_RX.with_label_values(&[&ip_str]).set(pol.rx_bps as f64);
        M_POLICY_TX.with_label_values(&[&ip_str]).set(pol.tx_bps as f64);
        seen.insert(ip_str);
    }
    // `reset` removed the policy: drop its gauges (D10), otherwise the last
    // configured rate stays on dashboards while the UE is actually uncapped.
    for gone in labels.difference(&seen) {
        let _ = M_POLICY_RX.remove_label_values(&[gone]);
        let _ = M_POLICY_TX.remove_label_values(&[gone]);
    }
    *labels = seen;
    Ok(())
}

fn scrape_stats_into_counters(map: &MapHandle, labels: &mut HashSet<String>) -> Result<()> {
    let mut seen = HashSet::new();
    for key in map.keys() {
        let Ok(ip) = key_to_ip(&key) else { continue };
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
        seen.insert(ip_str);
    }
    // ue_stats_map is LRU: an evicted UE's series is dropped rather than
    // frozen at its last value.
    for gone in labels.difference(&seen) {
        for c in all_counters() { let _ = c.remove_label_values(&[gone]); }
    }
    *labels = seen;
    Ok(())
}

/// Export the BPF absolute value. If it went down (entry re-created, e.g.
/// after LRU eviction), reset the series and start from the new value;
/// Prometheus rate()/increase() treat the decrease as a counter reset.
fn set_counter(cv: &CounterVec, label: &str, value: u64) {
    let c = cv.with_label_values(&[label]);
    let want = value as f64;
    if want < c.get() {
        c.reset();
    }
    let cur = c.get();
    if want > cur {
        c.inc_by(want - cur);
    }
}
