#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "script" / "phonecam.sh").read_text(encoding="utf-8")

# Linux Mint 21 ships mawk 1.3.4-20200120 as awk: no regex intervals ({64}) and no gawk extensions.
UNSUPPORTED = re.compile(
    r"\{\d+(?:,\d*)?\}|\\[sSwWyB<>]|\b(?:gensub|strftime|systime|mktime|asorti?|nextfile)\s*\(|"
    r"\b(?:PROCINFO|IGNORECASE|BEGINFILE|ENDFILE|FPAT)\b|@include|match\([^()]*,[^()]*,[^()]*\)"
)
for sample in ("$1 ~ /^[0-9a-f]{64}$/", "gensub(/a/, \"b\", 1)", "$0 ~ /\\s/", "match($0, /x/, m)"):
    assert UNSUPPORTED.search(sample), f"portability scanner misses: {sample}"
assert not UNSUPPORTED.search("length($1) == 64 && $1 !~ /[^[:xdigit:]]/"), "scanner flags supported awk"

# The program is the first single-quoted string after `awk`, possibly after a line continuation.
programs = [(text.count("\n", 0, m.start()) + 1, m.group(1)) for m in re.finditer(r"\bawk\b(?:[^'\n]|\\\n)*'([^']*)'", text)]
assert len(programs) >= 10, f"awk program scan found only {len(programs)} programs"
offenders = [f"line {n}: {UNSUPPORTED.search(p).group(0)}" for n, p in programs if UNSUPPORTED.search(p)]
assert not offenders, "awk programs unsupported by mawk 1.3.4-20200120: " + "; ".join(offenders)

print(f"ok - portability: {len(programs)} awk programs avoid intervals and gawk-only features")
