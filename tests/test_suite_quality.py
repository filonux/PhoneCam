#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TEST_DIR = ROOT / "tests"
RUNNER = TEST_DIR / "run_all.sh"

# Literal test labels identify logical cases. A pass/fail pair on one source line
# represents one case, so collect each label once per source location.
seen = {}
patterns = [
    re.compile(r"\b(?:check|check_eq|expect_fail|pass_case|fail_case)\s+'([^']+)'"),
    re.compile(r'\b(?:check|check_eq|expect_fail|pass_case|fail_case)\s+"([^\"]+)"'),
    re.compile(r"\bassert_(?:eq|contains)\s+'([^']+)'"),
    re.compile(r'\bassert_(?:eq|contains)\s+"([^\"]+)"'),
]
for path in sorted(TEST_DIR.glob("test_*.sh")):
    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue
        labels = []
        for pattern in patterns:
            labels.extend(m.group(1).strip() for m in pattern.finditer(line))
        for label in set(labels):
            if label and not label.startswith('$'):
                seen.setdefault(label, []).append(f"{path.name}:{line_no}")

duplicates = {label: locations for label, locations in seen.items() if len(locations) > 1}
assert not duplicates, "Duplicate logical test labels: " + "; ".join(f"{k}: {v}" for k, v in sorted(duplicates.items()))

runner = RUNNER.read_text(encoding="utf-8")
assert "test_full_regression.sh" not in runner, "Obsolete duplicated regression suite remains in run_all.sh"
assert "test_phonecam.sh" not in runner, "Obsolete duplicated phonecam suite remains in run_all.sh"
assert 'PYTHONDONTWRITEBYTECODE=1' in runner, "Python tests must not create repository bytecode"

for path in sorted(TEST_DIR.glob("test_*.sh")):
    text = path.read_text(encoding="utf-8", errors="ignore")
    assert re.search(r"^set -euo pipefail$", text, re.M), f"{path.name} must use set -euo pipefail"
    if "mktemp -d" in text:
        assert "trap " in text and "EXIT" in text, f"{path.name} creates temp state without an EXIT cleanup trap"
    for line_no, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if "|| true" in stripped:
            allowed = ("kill ", "wait ", "rm ", "tr '")
            assert any(token in stripped for token in allowed) or stripped.startswith("trap "), f"{path.name}:{line_no} contains an unguarded '|| true': {stripped}"
        assert "eval \"$(" not in stripped, f"{path.name}:{line_no} uses eval with command substitution"

for path in sorted(TEST_DIR.glob("test_*.sh")):
    text = path.read_text(encoding="utf-8", errors="ignore")
    assert "/tmp/phonecam-cli-" not in text, f"{path.name} writes fixed temporary files outside its own temp directory"

# Literal success labels in user-driven tests must also be unique. Helper definitions
# using "%s" are ignored because they emit dynamic labels already checked above.
literal_ok = {}
for path in sorted(TEST_DIR.glob("test_*.sh")):
    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        for match in re.finditer(r"(?:printf|echo).*?['\"]ok - ([^'\"]+)['\"]", line):
            label = match.group(1).strip()
            if "%s" in label or not label or label.startswith("$"):
                continue
            literal_ok.setdefault(label, []).append(f"{path.name}:{line_no}")
literal_duplicates = {k: v for k, v in literal_ok.items() if len(v) > 1}
assert not literal_duplicates, "Duplicate literal success labels: " + "; ".join(f"{k}: {v}" for k, v in sorted(literal_duplicates.items()))

# The same normalized check command in two suites is a likely duplicate test.
commands = {}
for path in sorted(TEST_DIR.glob("test_*.sh")):
    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        m = re.search(r"\bcheck(?:_eq)?\s+(['\"])(.*?)\1\s+(.*)$", line)
        if not m:
            continue
        command = re.sub(r"\s+", " ", m.group(3).strip())
        if command.startswith("grep ") and "<<<" in command:
            command = re.sub(r"<<<.*$", "<<<", command)
        commands.setdefault(command, []).append(f"{path.name}:{line_no}")
command_duplicates = {k: v for k, v in commands.items() if len({item.split(':',1)[0] for item in v}) > 1}
assert not command_duplicates, "Likely duplicate check commands across suites: " + "; ".join(f"{k}: {v}" for k, v in sorted(command_duplicates.items()))

print(f"ok - suite quality: {len(seen)} labelled cases + {len(literal_ok)} literal success labels; no duplicates")
