#!/usr/bin/env python3
"""
runbook_blocks.py -- extract the paste blocks of docs/install-runbook.md for the rehearsal.

A paste block is a ```bash fence preceded by
    <!-- rh: id=<id> host=svc|a|b|upf [mode=edit|reboot|measure|manual] -->
    **[서비스 노드]** | **[클라이언트 A]** | **[클라이언트 B]** | **[UPF 호스트]**
The visible host label must agree with host=. Every ```bash fence in the document must
carry such a comment (so no runnable block escapes the rehearsal).

Usage: runbook_blocks.py <runbook.md> <outdir>
Writes <outdir>/NN_<id>.sh (block text verbatim) and <outdir>/index.tsv
(n, id, host, mode, file). Exit 1 on any format error.
"""
import os
import re
import sys

LABEL = {"svc": "[서비스 노드]", "a": "[클라이언트 A]", "b": "[클라이언트 B]", "upf": "[UPF 호스트]"}
src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")
os.makedirs(out, exist_ok=True)
errs, blocks, pending = [], [], None
i = 0
while i < len(lines):
    ln = lines[i]
    m = re.match(r"^<!-- rh: (.*) -->$", ln.strip())
    if m:
        attrs = dict(kv.split("=", 1) for kv in m.group(1).split())
        pending = (attrs, i + 1)
        i += 1
        continue
    if ln.startswith("```bash"):
        start = i + 1
        j = start
        while j < len(lines) and not lines[j].startswith("```"):
            j += 1
        body = "\n".join(lines[start:j]) + "\n"
        if pending is None:
            errs.append("line %d: ```bash block without <!-- rh: --> comment" % (i + 1))
        else:
            attrs, at = pending
            host = attrs.get("host")
            between = [x for x in lines[at:i] if x.strip()]
            if host not in LABEL:
                errs.append("line %d: bad host=%r" % (at, host))
            elif len(between) != 1 or LABEL[host] not in between[0]:
                errs.append("line %d: host label for %s must be the single line between comment and fence"
                            % (at, attrs.get("id")))
            blocks.append((attrs.get("id"), host, attrs.get("mode", "run"), body))
        pending = None
        i = j + 1
        continue
    i += 1
if pending is not None:
    errs.append("line %d: <!-- rh: --> comment without a following ```bash block" % pending[1])
ids = [b[0] for b in blocks]
for d in sorted(set(x for x in ids if ids.count(x) > 1)):
    errs.append("duplicate id %s" % d)
if errs:
    print("\n".join(errs))
    sys.exit(1)
with open(os.path.join(out, "index.tsv"), "w") as idx:
    for n, (bid, host, mode, body) in enumerate(blocks, 1):
        fn = "%02d_%s.sh" % (n, bid)
        with open(os.path.join(out, fn), "w", encoding="utf-8") as f:
            f.write(body)
        idx.write("%d\t%s\t%s\t%s\t%s\n" % (n, bid, host, mode, fn))
print("%d blocks -> %s" % (len(blocks), out))
