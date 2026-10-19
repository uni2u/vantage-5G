#!/usr/bin/env python3
"""
contract_check.py — Vantage-5G cross-boundary contract checker.

Runs on any host (macOS included): pure text analysis, no kernel/libbpf needed.
Compares the contracts that tie the BPF C objects, the Rust CLI, the shell
scripts and the README together, and fails loudly when they drift.

Checks:
  C1  struct defined in several BPF objects is identical everywhere
  C2  Rust #[repr(C)] wire struct == C struct (field order, names, widths)
  C3  same-named map (LIBBPF_PIN_BY_NAME => shared) has identical definition
  C4  every Rust MAP_* const names a pinned map in some BPF object
  C5  every Rust PROG_*_NAME const names a SEC() program; OBJ_* in Makefile
  C6  pin dir: Rust BPF_PIN_DIR == setup.sh / detach.sh / ready.sh PIN paths
  C7  Prometheus metric names in Rust == metric names documented in README
  C8  BPF sources built by Makefile exist; legacy .c files reported (info)

Usage:  python3 contract_check.py [repo_root]      (exit 1 on any FAIL)
Python 3.8 compatible on purpose (macOS system python).
"""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")

C_TO_RUST = {
    "__u8": "u8", "__u16": "u16", "__u32": "u32", "__u64": "u64",
    "__s8": "i8", "__s16": "i16", "__s32": "i32", "__s64": "i64",
    "__be16": "u16", "__be32": "u32",
}

results = []  # (level, check, message)


def add(level, check, msg):
    results.append((level, check, msg))


def read(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_c_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def strip_rust_comments(s):
    return re.sub(r"//[^\n]*", "", s)


def camel(name):
    return "".join(p.capitalize() for p in name.split("_"))


# ---------- Makefile ----------
mk = read("Makefile") or ""
m = re.search(r"^BPF_SRCS\s*:?=\s*(.+)$", mk, re.M)
bpf_srcs = m.group(1).split() if m else []
if not bpf_srcs:
    add("FAIL", "C8", "Makefile: BPF_SRCS not found")
bpf_objs = [s[:-2] + ".o" for s in bpf_srcs]

all_c = sorted(f for f in os.listdir(ROOT) if f.endswith(".c"))
for f in all_c:
    if f not in bpf_srcs:
        add("INFO", "C8", "{} is not in BPF_SRCS (legacy / reference only)".format(f))
for f in bpf_srcs:
    if f not in all_c:
        add("FAIL", "C8", "Makefile BPF_SRCS lists {} but file is missing".format(f))

# ---------- parse BPF C ----------
c_structs = {}   # name -> {file: [(type, field)]}
c_maps = {}      # name -> {file: {attr: val}}
c_progs = {}     # func name -> (file, section)

STRUCT_RE = re.compile(r"struct\s+(\w+)\s*\{([^{}]*)\}\s*(?:__attribute__\s*\(\(.*?\)\))?\s*;", re.S)
MAP_RE = re.compile(r"struct\s*\{([^{}]*)\}\s*(\w+)\s+SEC\(\s*\"\.maps\"\s*\)", re.S)
PROG_RE = re.compile(r"SEC\(\s*\"([^\"]+)\"\s*\)\s*int\s+(\w+)\s*\(")

for f in bpf_srcs:
    src = read(f)
    if src is None:
        continue
    src = strip_c_comments(src)
    for name, body in STRUCT_RE.findall(src):
        fields = []
        for decl in body.split(";"):
            decl = " ".join(decl.split())
            if not decl:
                continue
            mm = re.match(r"(\w+)\s+(\w+)(\[\d+\])?$", decl)
            if not mm:
                add("WARN", "C1", "{}: struct {}: unparsed field '{}'".format(f, name, decl))
                continue
            fields.append((mm.group(1) + (mm.group(3) or ""), mm.group(2)))
        c_structs.setdefault(name, {})[f] = fields
    for body, name in MAP_RE.findall(src):
        attrs = {}
        for k, v in re.findall(r"__(?:uint|type)\(\s*(\w+)\s*,\s*([^)]+?)\s*\)", body):
            attrs[k] = " ".join(v.split())
        c_maps.setdefault(name, {})[f] = attrs
    for sec, fn in PROG_RE.findall(src):
        c_progs[fn] = (f, sec)

# C1: struct identical across objects
for name, per_file in sorted(c_structs.items()):
    variants = {tuple(v) for v in per_file.values()}
    if len(variants) > 1:
        add("FAIL", "C1", "struct {} differs between {}: {}".format(
            name, ", ".join(sorted(per_file)), per_file))
    elif len(per_file) > 1:
        add("PASS", "C1", "struct {} identical in {}".format(name, ", ".join(sorted(per_file))))

# ---------- parse Rust ----------
rs = strip_rust_comments(read("src/main.rs") or "")
rust_structs = {}
for name, body in re.findall(r"#\[repr\(C\)\][^{]*?struct\s+(\w+)\s*\{([^}]*)\}", rs, re.S):
    fields = []
    for fn, ty in re.findall(r"(\w+)\s*:\s*([\w\[\]; ]+?)\s*,", body + ","):
        fields.append((" ".join(ty.split()), fn))
    rust_structs[name] = fields
rust_consts = dict(re.findall(r"const\s+(\w+)\s*:\s*&str\s*=\s*\"([^\"]*)\"", rs))

# C2: Rust wire struct == C struct
for rname, rfields in sorted(rust_structs.items()):
    cname = next((c for c in c_structs if camel(c) == rname), None)
    if cname is None:
        add("FAIL", "C2", "Rust #[repr(C)] {} has no matching C struct".format(rname))
        continue
    cfields = next(iter(c_structs[cname].values()))
    exp = [(C_TO_RUST.get(t, "?" + t), n) for t, n in cfields]
    if exp != rfields:
        add("FAIL", "C2", "{} (Rust) != struct {} (C)\n      C   : {}\n      Rust: {}".format(
            rname, cname, exp, rfields))
    else:
        add("PASS", "C2", "{} == struct {} ({} fields)".format(rname, cname, len(rfields)))
for cname in sorted(c_structs):
    if camel(cname) not in rust_structs:
        add("INFO", "C2", "struct {} is BPF-only (no Rust mirror)".format(cname))

# C3: shared maps identical
for name, per_file in sorted(c_maps.items()):
    variants = {tuple(sorted(a.items())) for a in per_file.values()}
    pinned = any("pinning" in a for a in per_file.values())
    if len(per_file) > 1 and len(variants) > 1:
        add("FAIL", "C3", "map {} declared differently in {} (pinned maps must match "
                          "or the 2nd object fails to load): {}".format(
                              name, ", ".join(sorted(per_file)), per_file))
    elif len(per_file) > 1:
        add("PASS", "C3", "map {} shared by {}".format(name, ", ".join(sorted(per_file))))
    if not pinned:
        add("WARN", "C3", "map {} has no LIBBPF_PIN_BY_NAME pinning".format(name))

# C4: Rust MAP_* consts
for k, v in sorted(rust_consts.items()):
    if k.startswith("MAP_"):
        if v in c_maps:
            add("PASS", "C4", "{}=\"{}\" exists".format(k, v))
        else:
            add("FAIL", "C4", "{}=\"{}\" not declared in any BPF_SRCS object".format(k, v))
rust_map_names = {v for k, v in rust_consts.items() if k.startswith("MAP_")}
for name in sorted(c_maps):
    if name not in rust_map_names:
        add("WARN", "C4", "map {} has no Rust MAP_* const (not pinned by load?)".format(name))

# C5: programs / objects
for k, v in sorted(rust_consts.items()):
    if k.startswith("PROG_") and k.endswith("_NAME"):
        if v in c_progs:
            add("PASS", "C5", "{}=\"{}\" -> {} SEC(\"{}\")".format(k, v, *c_progs[v]))
        else:
            add("FAIL", "C5", "{}=\"{}\" has no SEC() function in BPF_SRCS".format(k, v))
    if k.startswith("OBJ_"):
        if v in bpf_objs:
            add("PASS", "C5", "{}=\"{}\" built by Makefile".format(k, v))
        else:
            add("FAIL", "C5", "{}=\"{}\" not produced by Makefile ({})".format(k, v, bpf_objs))

# C6: pin dir
pin_dir = rust_consts.get("BPF_PIN_DIR")
for sh in ("setup.sh", "detach.sh"):
    s = read(sh)
    if s is None:
        continue
    found = set(re.findall(r"(/sys/fs/bpf/[\w/]+)", s))
    pd = re.search(r"PIN_DIR=\"?(/sys/fs/bpf/[\w/]+)", s)
    if pd:
        found |= {pd.group(1) + "/" + leaf
                  for leaf in re.findall(r"\$\{PIN_DIR\}/(\w+)", s)}
    for p in sorted(found):
        if pin_dir and not p.startswith(pin_dir):
            add("FAIL", "C6", "{} uses {} but Rust BPF_PIN_DIR={}".format(sh, p, pin_dir))
        elif pin_dir:
            leaf = p[len(pin_dir):].strip("/")
            if leaf and leaf not in c_progs and leaf not in c_maps:
                add("FAIL", "C6", "{} references pin {} but nothing pins '{}'".format(sh, p, leaf))
            else:
                add("PASS", "C6", "{}: {}".format(sh, p))
s = read("ready.sh")
if s:
    for p in sorted(set(re.findall(r"(/sys/fs/bpf/[\w/]+)", s))):
        leaf = p.rsplit("/", 1)[-1]
        if leaf not in c_progs and leaf not in c_maps:
            add("INFO", "C6", "ready.sh (legacy) references {} — not produced by current build".format(p))

# C7: metrics
rust_metrics = set(re.findall(r"opts!\(\s*\"(vantage_\w+)\"", rs))
readme = read("README.md") or ""
doc_metrics = set(re.findall(r"\b(vantage_ue_\w+)\b", readme))
for mname in sorted(rust_metrics - doc_metrics):
    add("FAIL", "C7", "metric {} exported but not documented in README".format(mname))
for mname in sorted(doc_metrics - rust_metrics):
    add("FAIL", "C7", "metric {} documented in README but not exported".format(mname))
if rust_metrics and rust_metrics == doc_metrics:
    add("PASS", "C7", "{} metrics match README".format(len(rust_metrics)))

# ---------- report ----------
order = {"FAIL": 0, "WARN": 1, "PASS": 2, "INFO": 3}
results.sort(key=lambda r: (order[r[0]], r[1]))
print("# Vantage-5G contract check  ({})\n".format(ROOT))
for lvl, chk, msg in results:
    print("[{:<4}] {}  {}".format(lvl, chk, msg))
n = {k: sum(1 for r in results if r[0] == k) for k in order}
print("\nsummary: FAIL={FAIL} WARN={WARN} PASS={PASS} INFO={INFO}".format(**n))
sys.exit(1 if n["FAIL"] else 0)
