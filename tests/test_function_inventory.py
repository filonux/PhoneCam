#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script" / "phonecam.sh"
TEST_DIR = ROOT / "tests"
RUNNER = TEST_DIR / "run_all.sh"

script = SCRIPT.read_text(encoding="utf-8")
funcs = re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", script, re.M)
assert len(funcs) == len(set(funcs)), "Duplicate function definitions detected"

# Search executable-looking test source, ignoring comments so a stale comment
# cannot make an untested function look covered.
parts = []
for path in sorted(TEST_DIR.glob('test_*')):
    if not path.is_file() or path.name == Path(__file__).name or '.before_' in path.name:
        continue
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.lstrip().startswith("#"):
            continue
        parts.append(line)
corpus = "\n".join(parts)

# These functions are invoked through subprocess dispatch rather than by name
# in an assertion body; keep their ownership explicit here.
dispatch_only = {"main", "cmd_install", "cmd_uninstall"}
missing = [
    f for f in funcs
    if f not in dispatch_only and not re.search(r"(?<![A-Za-z0-9_])" + re.escape(f) + r"(?![A-Za-z0-9_])", corpus)
]
assert not missing, "Functions without a test reference: " + ", ".join(missing)

runner = RUNNER.read_text(encoding="utf-8")
suite_files = sorted(p.name for p in TEST_DIR.glob("test_*") if p.is_file() and p.name != Path(__file__).name and '.before_' not in p.name) + [Path(__file__).name]
for name in suite_files:
    count = len(re.findall(r"(?:^|\s)(?:bash tests/|python3 tests/)" + re.escape(name) + r"(?:\s|$)", runner))
    assert count == 1, f"Suite {name} must be listed exactly once in run_all.sh (found {count})"

print(f"ok - function inventory: {len(funcs)} functions referenced; {len(suite_files)} test files listed exactly once")
