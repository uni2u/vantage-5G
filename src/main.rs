// Vantage-5G v0.2 CLI
// Toy-project scope: administrator manually sets per-UE RX/TX bandwidth
// limits enforced by XDP (RX policer) and tc-bpf EDT (TX pacer) attached
// to the service-node N6-facing NIC.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::mem::size_of;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
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
    ///
    /// Without --obj-dir the .o files are searched in: the repository root of the
    /// executable (<exe dir>/../..), the executable's directory, the current directory (last).
    Load {
        /// Directory holding vantage_rx_policer.o and vantage_tx_pacer.o (no search)
        #[arg(long, value_name = "DIR")] obj_dir: Option<PathBuf>,
    },

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

    /// Apply a policy file: one `<UE_IPv4> <rx_mbps> <tx_mbps>` per line,
    /// `#` starts a comment. The whole file is validated before anything is
    /// changed. Each UE gets `set` semantics (same values = state kept).
    /// With --replace, policies of UEs not in the file are reset.
    Apply {
        /// Policy file (`-` = stdin)
        #[arg(short = 'f', long = "file", value_name = "FILE")] file: PathBuf,
        /// Also reset every policy not listed in the file
        #[arg(long)] replace: bool,
        /// With --replace: allow a file with no policies to remove every
        /// current policy (refused otherwise, to catch an empty/truncated file)
        #[arg(long, requires = "replace")] allow_empty: bool,
    },

    /// Print the current policies in the `apply` file format (sorted by UE IP).
    Export,

    /// Print RX/TX counters for one UE (or all UEs when --ue-ip is omitted).
    Stats {
        #[arg(long)] ue_ip: Option<Ipv4Addr>,
    },

    /// Run the Prometheus exporter (foreground). Scrapes pinned stats maps.
    Monitor {
        /// Address to listen on (IPv4 or IPv6, e.g. 127.0.0.1, ::1, ::)
        #[arg(long, default_value_t = IpAddr::V4(Ipv4Addr::UNSPECIFIED))] bind: IpAddr,
        #[arg(long, default_value_t = 9090,
              value_parser = clap::value_parser!(u16).range(1..=65535))] port: u16,
        /// Milliseconds between BPF map reads
        #[arg(long, default_value_t = 1000,
              value_parser = clap::value_parser!(u64).range(100..=60000))] scrape_ms: u64,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Load { obj_dir }                    => cmd_load(obj_dir),
        Cmd::Unload                              => cmd_unload(),
        Cmd::Set { ue_ip, rx_mbps, tx_mbps }     => cmd_set(ue_ip, rx_mbps, tx_mbps),
        Cmd::Reset { ue_ip }                     => cmd_reset(ue_ip),
        Cmd::List                                => cmd_list(),
        Cmd::Apply { file, replace, allow_empty } => cmd_apply(&file, replace, allow_empty),
        Cmd::Export                              => cmd_export(),
        Cmd::Stats { ue_ip }                     => cmd_stats(ue_ip),
        Cmd::Monitor { bind, port, scrape_ms }   => cmd_monitor(bind, port, scrape_ms),
    }
}

// ---------- load / unload ----------
fn cmd_load(obj_dir: Option<PathBuf>) -> Result<()> {
    let dir = find_obj_dir(obj_dir)?;
    println!("[i] BPF objects from {}", dir.display());
    ensure_pin_dir()?;
    load_and_pin(&dir, OBJ_RX, PROG_RX_NAME)?;
    load_and_pin(&dir, OBJ_TX, PROG_TX_NAME)?;
    println!("[+] Vantage-5G loaded. Pins under {}", BPF_PIN_DIR);
    println!("    Attach with: sudo {}/setup.sh <iface>", hint_paths().1);
    Ok(())
}

/// Directory that holds both OBJ_RX and OBJ_TX (M1). An explicit --obj-dir is
/// the only candidate; otherwise: the repository root of the executable
/// (target/release/../..), the executable's own directory, and only then the
/// current directory. The cwd comes last (QA M-D1) so that a root `load` run
/// from an untrusted directory (/tmp) or an older checkout never prefers the
/// .o files found there over the ones built with this binary.
/// current_exe() is canonicalized so a symlink in e.g. /usr/local/bin resolves
/// to the real binary under <repo>/target/release.
fn find_obj_dir(explicit: Option<PathBuf>) -> Result<PathBuf> {
    let mut cands: Vec<PathBuf> = Vec::new();
    if let Some(d) = explicit {
        cands.push(d);
    } else {
        match std::env::current_exe().and_then(|p| p.canonicalize()) {
            Ok(exe) => {
                if let Some(exe_dir) = exe.parent() {
                    if let Some(root) = exe_dir.parent().and_then(Path::parent) {
                        cands.push(root.to_path_buf());
                    }
                    cands.push(exe_dir.to_path_buf());
                }
            }
            Err(e) => eprintln!("[!] cannot resolve the executable path ({}); searching the current directory only", e),
        }
        // Last resort; skipped when it is one of the directories above.
        let cwd = PathBuf::from(".");
        let cwd_abs = cwd.canonicalize().ok();
        if cwd_abs.is_none() || !cands.iter().any(|c| Some(c) == cwd_abs.as_ref()) {
            cands.push(cwd);
        }
    }
    let has_both = |d: &Path| d.join(OBJ_RX).is_file() && d.join(OBJ_TX).is_file();
    if let Some(d) = cands.iter().find(|d| has_both(d)) {
        // Absolute path for the messages; fall back to the path as given.
        return Ok(d.canonicalize().unwrap_or_else(|_| d.clone()));
    }
    eprintln!("[-] {} and {} not found together in:", OBJ_RX, OBJ_TX);
    for d in &cands {
        let shown = d.canonicalize().unwrap_or_else(|_| d.clone());
        let missing: Vec<&str> = [OBJ_RX, OBJ_TX].into_iter()
            .filter(|f| !d.join(f).is_file()).collect();
        eprintln!("      {}  (missing: {})", shown.display(), missing.join(", "));
    }
    eprintln!("    build them with `make build`, or pass --obj-dir <DIR>");
    bail!("BPF object files not found");
}

/// Paths for operator hints, based on where this binary actually is:
/// (this executable, directory holding setup.sh/detach.sh). Installed copy:
/// /usr/local/lib/vantage-5g/{vantage-5G,setup.sh,detach.sh}; repository
/// build: <repo>/target/release/vantage-5G with the scripts at <repo>.
fn hint_paths() -> (String, String) {
    let exe = std::env::current_exe().and_then(|p| p.canonicalize()).ok();
    let exe_s = exe.as_ref().map(|p| p.display().to_string())
        .unwrap_or_else(|| "vantage-5G".into());
    let scripts = exe.as_ref().and_then(|e| e.parent()).and_then(|d| {
        [Some(d), d.parent().and_then(Path::parent)].into_iter().flatten()
            .find(|c| c.join("detach.sh").is_file())
            .map(|c| c.display().to_string())
    }).unwrap_or_else(|| ".".into());
    (exe_s, scripts)
}

fn upgrade_hint() -> String {
    let (exe, sd) = hint_paths();
    format!("upgrade procedure (map definitions changed in the .o):\n      \
             with the systemd service: sudo systemctl restart {svc}\n      \
               (policies are restored from {pol})\n      \
             by hand: sudo {sd}/detach.sh <iface>; sudo {exe} unload;\n      \
               sudo {exe} load; sudo {sd}/setup.sh <iface>\n      \
               (policies are lost: `sudo {exe} apply -f <file>` or `set` for every UE afterwards)",
            svc = SERVICE_UNIT, pol = SERVICE_POLICY_FILE, sd = sd, exe = exe)
}

const SERVICE_UNIT: &str = "vantage-5g";
const SERVICE_POLICY_FILE: &str = "/etc/vantage-5g/policies.conf";

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
        let sd = hint_paths().1;
        for i in ifs {
            eprintln!("    run: sudo {}/detach.sh {}", sd, i);
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

fn load_and_pin(dir: &Path, obj_file: &str, prog_name: &str) -> Result<()> {
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
        .open_file(dir.join(obj_file))
        .with_context(|| format!("open {}", dir.join(obj_file).display()))?;

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
        eprintln!("    {}", upgrade_hint());
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
                     above); for the latter: {}", obj_file, BPF_PIN_DIR, upgrade_hint()),
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

// ---------- writer lock (set / reset / apply) ----------
//
// Writers read the policy map, decide (D26 unchanged? capacity?) and write.
// Two of them interleaving -- `systemctl reload` (apply --replace) next to an
// operator's `set` -- could re-write a value another writer just changed
// without clearing its state, or fail half-way on a full map. They serialise
// on an flock. /run (tmpfs) rather than the service's RuntimeDirectory so the
// CLI used without systemd takes the same lock.
const LOCK_PATH: &str = "/run/vantage-5g.lock";
const LOCK_WAIT: Duration = Duration::from_secs(30);

fn writer_lock() -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let f = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).open(LOCK_PATH)
        .with_context(|| format!("open lock {} (needs root)", LOCK_PATH))?;
    let start = std::time::Instant::now();
    let mut said = false;
    loop {
        match f.try_lock() {
            Ok(()) => return Ok(f),
            Err(std::fs::TryLockError::WouldBlock) => {}
            Err(std::fs::TryLockError::Error(e)) =>
                return Err(e).with_context(|| format!("lock {}", LOCK_PATH)),
        }
        if start.elapsed() >= LOCK_WAIT {
            bail!("another vantage-5G set/reset/apply still holds {} after {} s; nothing was changed",
                  LOCK_PATH, LOCK_WAIT.as_secs());
        }
        if !said {
            eprintln!("[i] waiting for {} (another set/reset/apply is running)", LOCK_PATH);
            said = true;
        }
        thread::sleep(Duration::from_millis(100));
    }
}

// ---------- set / reset ----------
fn mbps_policy(rx_mbps: u64, tx_mbps: u64) -> UePolicy {
    // Callers bound both values to 0..=MAX_MBPS, so the products fit easily.
    UePolicy { rx_bps: rx_mbps * 1_000_000, tx_bps: tx_mbps * 1_000_000 }
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
enum SetOutcome { Added, Changed, Unchanged }

/// Write the policy for `key`; `old` is its current value (None = absent).
/// D26: re-applying the same policy (periodic reconcile, boot scripts, apply)
/// must not refill the RX bucket or forget the TX backlog, so the per-UE
/// state is only cleared when the value actually changes.
fn write_policy(map: &MapHandle, ue_ip: Ipv4Addr, old: Option<UePolicy>, val: UePolicy)
    -> Result<SetOutcome>
{
    let key = ue_ip_key(ue_ip);
    let outcome = match old {
        None => SetOutcome::Added,
        Some(o) if o.rx_bps == val.rx_bps && o.tx_bps == val.tx_bps => SetOutcome::Unchanged,
        Some(_) => SetOutcome::Changed,
    };
    map.update(&key, as_bytes(&val), MapFlags::ANY)
        .with_context(|| format!("update ue_policy_map for {}", ue_ip))?;
    if outcome != SetOutcome::Unchanged {
        // Policy first, then state: a packet racing in between re-creates the
        // state under the new policy.
        clear_ue_state(&key)
            .with_context(|| format!("policy for {} WAS updated, but clearing its rx/tx state failed", ue_ip))?;
    }
    Ok(outcome)
}

/// Delete the policy of `ue_ip` and its per-UE state. Ok(existed).
fn remove_policy(map: &MapHandle, ue_ip: Ipv4Addr) -> Result<bool> {
    let key = ue_ip_key(ue_ip);
    let existed = delete_key(map, &key)
        .with_context(|| format!("reset policy for {}", ue_ip))?;
    clear_ue_state(&key)
        .with_context(|| format!("clear rx/tx state for {}", ue_ip))?;
    Ok(existed)
}

fn lookup_policy(map: &MapHandle, ue_ip: Ipv4Addr) -> Result<Option<UePolicy>> {
    Ok(map.lookup(&ue_ip_key(ue_ip), MapFlags::empty())
        .with_context(|| format!("lookup ue_policy_map for {}", ue_ip))?
        .map(|b| from_bytes::<UePolicy>(&b)))
}

/// Every policy in the map, keyed by UE IP (sorted numerically).
fn read_all_policies(map: &MapHandle) -> Result<BTreeMap<Ipv4Addr, UePolicy>> {
    let mut out = BTreeMap::new();
    for key in map.keys() {
        let Some(b) = map.lookup(&key, MapFlags::empty())
            .with_context(|| format!("lookup {}", MAP_POLICY))? else { continue };  // deleted mid-scan
        out.insert(key_to_ip(&key)?, from_bytes::<UePolicy>(&b));
    }
    Ok(out)
}

fn cmd_set(ue_ip: Ipv4Addr, rx_mbps: u64, tx_mbps: u64) -> Result<()> {
    let map = open_policy_map()?;
    let _lock = writer_lock()?;
    let old = lookup_policy(&map, ue_ip)?;
    let outcome = write_policy(&map, ue_ip, old, mbps_policy(rx_mbps, tx_mbps))?;
    println!("[+] policy set: UE {} rx={} Mbps tx={} Mbps{}{}",
             ue_ip, rx_mbps, tx_mbps,
             if tx_mbps == 0 { "  (killswitch: DL blocked)" } else { "" },
             if outcome == SetOutcome::Unchanged { "  (unchanged; rx/tx state kept)" } else { "" });
    Ok(())
}

fn cmd_reset(ue_ip: Ipv4Addr) -> Result<()> {
    let map = open_policy_map()?;
    let _lock = writer_lock()?;
    if remove_policy(&map, ue_ip)? {
        println!("[+] policy cleared for UE {}", ue_ip);
    } else {
        println!("[i] no policy for UE {} (nothing to clear)", ue_ip);
    }
    Ok(())
}

// ---------- apply / export (policy file) ----------
//
// Format (also what `export` prints):
//   <UE_IPv4> <rx_mbps> <tx_mbps>     whitespace (spaces/tabs) separated
//   # comment                         `#` to end of line; blank lines ignored
// Values as for `set`: integer Mbps 0..=MAX_MBPS. A UE listed twice is an
// error. The file is fully parsed and checked before the map is touched.

#[derive(Debug)]
struct PolicyLine {
    line:    usize,
    ue_ip:   Ipv4Addr,
    rx_mbps: u64,
    tx_mbps: u64,
}

/// File text for an error message: at most SHOW_MAX chars, escaped ({:?})
/// so invisible characters (BOM, NBSP, control chars) show up.
const SHOW_MAX: usize = 64;
fn show(s: &str) -> String {
    let n = s.chars().count();
    if n <= SHOW_MAX {
        format!("{:?}", s)
    } else {
        let head: String = s.chars().take(SHOW_MAX).collect();
        format!("{:?}... ({} chars)", head, n)
    }
}

fn parse_mbps(tok: &str, what: &str) -> std::result::Result<u64, String> {
    // Plain decimal digits only (u64::from_str would also take "+5").
    if tok.is_empty() || !tok.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("{} {} is not a non-negative integer (Mbps)", what, show(tok)));
    }
    match tok.parse::<u64>() {
        Ok(v) if v <= MAX_MBPS => Ok(v),
        _ => Err(format!("{} {} out of range 0..={}", what, show(tok), MAX_MBPS)),
    }
}

/// Parse a whole policy file. Err lists every problem found (with line numbers).
fn parse_policy_file(text: &str) -> std::result::Result<Vec<PolicyLine>, Vec<String>> {
    let mut out = Vec::new();
    let mut errs = Vec::new();
    let mut first_line: HashMap<Ipv4Addr, usize> = HashMap::new();
    // A UTF-8 BOM (Windows editors) would otherwise glue onto the first token.
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    for (i, raw) in text.lines().enumerate() {
        let n = i + 1;
        let body = raw.split('#').next().unwrap_or("");
        let toks: Vec<&str> = body.split_whitespace().collect();
        if toks.is_empty() {
            continue;
        }
        if toks.len() != 3 {
            errs.push(format!("line {}: expected `<UE_IPv4> <rx_mbps> <tx_mbps>`, got {} field(s): {}",
                              n, toks.len(), show(raw.trim())));
            continue;
        }
        let ip = toks[0].parse::<Ipv4Addr>()
            .map_err(|_| format!("line {}: {} is not an IPv4 address", n, show(toks[0])));
        let rx = parse_mbps(toks[1], "rx_mbps").map_err(|e| format!("line {}: {}", n, e));
        let tx = parse_mbps(toks[2], "tx_mbps").map_err(|e| format!("line {}: {}", n, e));
        match (ip, rx, tx) {
            (Ok(ue_ip), Ok(rx_mbps), Ok(tx_mbps)) => {
                if let Some(prev) = first_line.get(&ue_ip) {
                    errs.push(format!("line {}: duplicate UE {} (first on line {})", n, ue_ip, prev));
                    continue;
                }
                first_line.insert(ue_ip, n);
                out.push(PolicyLine { line: n, ue_ip, rx_mbps, tx_mbps });
            }
            (ip, rx, tx) => {
                errs.extend([ip.err(), rx.err(), tx.err()].into_iter().flatten());
            }
        }
    }
    if errs.is_empty() { Ok(out) } else { Err(errs) }
}

fn read_policy_source(file: &Path) -> Result<String> {
    if file.as_os_str() == "-" {
        let mut s = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut s).context("read policies from stdin")?;
        Ok(s)
    } else {
        std::fs::read_to_string(file).with_context(|| format!("read policy file {}", file.display()))
    }
}

fn cmd_apply(file: &Path, replace: bool, allow_empty: bool) -> Result<()> {
    let text = read_policy_source(file)?;
    let entries = match parse_policy_file(&text) {
        Ok(e) => e,
        Err(errs) => {
            eprintln!("[-] {}: {} error(s); nothing was changed:", file.display(), errs.len());
            for e in &errs {
                eprintln!("      {}", e);
            }
            bail!("invalid policy file {}", file.display());
        }
    };

    let map = open_policy_map()?;
    let _lock = writer_lock()?;
    let current = read_all_policies(&map)?;
    // O-8a: an empty or truncated file (failed `export >` redirect, full disk)
    // with --replace would silently drop every policy, killswitches included.
    if replace && entries.is_empty() && !current.is_empty() && !allow_empty {
        bail!("{} has no policies; --replace would remove all {} current policies \
               (pass --allow-empty if that is intended); nothing was changed",
              file.display(), current.len());
    }
    let wanted: HashSet<Ipv4Addr> = entries.iter().map(|e| e.ue_ip).collect();
    let to_remove: Vec<Ipv4Addr> = if replace {
        current.keys().filter(|ip| !wanted.contains(ip)).copied().collect()
    } else {
        Vec::new()
    };

    // Capacity: ue_policy_map is a plain HASH (no eviction); an update past
    // max_entries fails with E2BIG half-way through. Check before changing
    // anything so a too-large file is a validation error, not a partial apply.
    let max = map.info().context("info of ue_policy_map")?.info.max_entries as usize;
    let added = entries.iter().filter(|e| !current.contains_key(&e.ue_ip)).count();
    let final_n = current.len() - to_remove.len() + added;
    if final_n > max {
        bail!("{}: applying would leave {} policies, {} holds at most {}; nothing was changed",
              file.display(), final_n, MAP_POLICY, max);
    }

    // From here on the map is changed. A failure (EPERM, map removed by a
    // concurrent unload, ...) stops the run; what was done so far is printed.
    let mut n = [0usize; 4]; // added, changed, unchanged, removed
    let summary = |n: &[usize; 4]| format!("added {}, changed {}, unchanged {}, removed {}",
                                           n[0], n[1], n[2], n[3]);
    let mut run = || -> Result<()> {
        // Removals first so that a full map has room for the additions.
        for ip in &to_remove {
            remove_policy(&map, *ip)?;
            n[3] += 1;
            println!("    - {:<16} removed", ip);
        }
        for e in &entries {
            let val = mbps_policy(e.rx_mbps, e.tx_mbps);
            let outcome = write_policy(&map, e.ue_ip, current.get(&e.ue_ip).copied(), val)
                .with_context(|| format!("line {}", e.line))?;
            let (idx, tag) = match outcome {
                SetOutcome::Added => (0, "added"),
                SetOutcome::Changed => (1, "changed"),
                SetOutcome::Unchanged => (2, "unchanged (rx/tx state kept)"),
            };
            n[idx] += 1;
            if outcome != SetOutcome::Unchanged {
                println!("    {} {:<16} rx={} Mbps tx={} Mbps{}  {}",
                         if outcome == SetOutcome::Added { "+" } else { "~" },
                         e.ue_ip, e.rx_mbps, e.tx_mbps,
                         if e.tx_mbps == 0 { " (killswitch)" } else { "" }, tag);
            }
        }
        Ok(())
    };
    if let Err(e) = run() {
        eprintln!("[-] apply {} stopped part-way (done so far: {})", file.display(), summary(&n));
        return Err(e);
    }
    println!("[+] applied {}{}: {}", file.display(), if replace { " (--replace)" } else { "" }, summary(&n));
    Ok(())
}

fn cmd_export() -> Result<()> {
    let map = open_policy_map()?;
    let pols = read_all_policies(&map)?;
    println!("# Vantage-5G policies (vantage-5G export): <UE_IPv4> <rx_mbps> <tx_mbps>");
    println!("# rx_mbps=0: RX uncapped, tx_mbps=0: DL blocked (killswitch)");
    for (ip, p) in &pols {
        // `set`/`apply` only write whole Mbps; anything else came from
        // another writer and cannot be represented exactly.
        if p.rx_bps % 1_000_000 != 0 || p.tx_bps % 1_000_000 != 0 {
            eprintln!("[!] {}: rx_bps={} tx_bps={} is not a whole Mbps; exported rounded down",
                      ip, p.rx_bps, p.tx_bps);
        }
        println!("{:<16} {:>7} {:>7}", ip, p.rx_bps / 1_000_000, p.tx_bps / 1_000_000);
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

fn cmd_monitor(ip: IpAddr, port: u16, scrape_ms: u64) -> Result<()> {
    // clap restricts port to 1..=65535, so the address printed below is the
    // one actually bound (no ephemeral port 0).
    let bind = SocketAddr::new(ip, port);
    prometheus_exporter::start(bind)
        .with_context(|| format!("start Prometheus exporter on {}", bind))?;
    println!("[+] Prometheus exporter listening on http://{}/metrics", bind);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ok_comments_blank_tabs() {
        let t = "# header\n\n10.45.1.23 10 20   # trailing\n\t10.45.1.24\t0\t0\n   \n10.45.1.25 400000 1\n";
        let v = parse_policy_file(t).unwrap();
        assert_eq!(v.len(), 3);
        assert_eq!((v[0].line, v[0].ue_ip, v[0].rx_mbps, v[0].tx_mbps),
                   (3, Ipv4Addr::new(10, 45, 1, 23), 10, 20));
        assert_eq!((v[1].rx_mbps, v[1].tx_mbps), (0, 0));
        assert_eq!(v[2].rx_mbps, MAX_MBPS);
    }

    #[test]
    fn parse_empty_file() {
        assert!(parse_policy_file("").unwrap().is_empty());
        assert!(parse_policy_file("# only comments\n\n").unwrap().is_empty());
    }

    #[test]
    fn parse_errors_all_reported_with_lines() {
        let t = "10.45.1.23 10 20\n10.45.1.23 1 1\n10.45.1.300 1 1\n10.45.1.26 400001 1\n10.45.1.27 -1 +5\n10.45.1.28 1\n10.45.1.29 1 2 3\n10.45.1.30 1.5 2\n";
        let e = parse_policy_file(t).unwrap_err();
        let all = e.join("\n");
        assert!(all.contains("line 2: duplicate UE 10.45.1.23 (first on line 1)"), "{}", all);
        assert!(all.contains("line 3: \"10.45.1.300\" is not an IPv4 address"), "{}", all);
        assert!(all.contains("line 4: rx_mbps \"400001\" out of range"), "{}", all);
        assert!(all.contains("line 5: rx_mbps \"-1\""), "{}", all);
        assert!(all.contains("line 5: tx_mbps \"+5\""), "{}", all);
        assert!(all.contains("line 6: expected"), "{}", all);
        assert!(all.contains("line 7: expected"), "{}", all);
        assert!(all.contains("line 8: rx_mbps \"1.5\""), "{}", all);
        assert_eq!(e.len(), 8, "{}", all);
    }

    #[test]
    fn parse_rejects_huge_and_odd_ip_forms() {
        assert!(parse_policy_file("10.45.1.1 99999999999999999999999 1\n").is_err());
        // Ipv4Addr::from_str is strict: no shorthand / leading zeros.
        assert!(parse_policy_file("10.1 1 1\n").is_err());
        assert!(parse_policy_file("010.45.1.1 1 1\n").is_err());
    }

    #[test]
    fn parse_strips_bom_only_at_start() {
        let v = parse_policy_file("\u{FEFF}10.45.1.23 10 20\n").unwrap();
        assert_eq!(v[0].ue_ip, Ipv4Addr::new(10, 45, 1, 23));
        let v = parse_policy_file("\u{FEFF}# hdr\n10.45.1.23 1 2\n").unwrap();
        assert_eq!(v.len(), 1);
        // A BOM elsewhere is not stripped, and is shown escaped.
        let e = parse_policy_file("10.45.1.1 1 1\n\u{FEFF}10.45.1.2 1 1\n").unwrap_err();
        assert!(e[0].contains("\\u{feff}"), "{:?}", e);
    }

    #[test]
    fn error_tokens_truncated_and_escaped() {
        let long = "9".repeat(2_000_000);
        let e = parse_policy_file(&format!("10.45.1.1 {} 1\n", long)).unwrap_err();
        assert!(e[0].len() < 200, "{} bytes", e[0].len());
        assert!(e[0].contains("... (2000000 chars)"), "{}", e[0]);
        let e = parse_policy_file(&format!("{} 1 1 1\n", "x".repeat(500))).unwrap_err();
        assert!(e[0].len() < 250 && e[0].contains("chars)"), "{}", e[0]);
        let e = parse_policy_file("10.45.1.1\t1\t\u{7}\n").unwrap_err();
        assert!(e[0].contains("\\u{7}"), "{}", e[0]);
    }
}
