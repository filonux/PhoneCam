#!/usr/bin/env python3
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script" / "phonecam.sh"
README = ROOT / "README.md"
README_ES = ROOT / "README-es.md"

def shell_words_after(src, pos):
    """Count the shell words of a command starting at pos, up to the first unquoted terminator."""
    n, count, in_word = len(src), 0, False
    while pos < n:
        c = src[pos]
        if c in " \t":
            in_word = False; pos += 1; continue
        if c in "\n;|&<>)":
            break
        if not in_word:
            fd = re.match(r"\d+(?=[<>])", src[pos:pos + 8])
            if fd:  # "2>file": the digits name a file descriptor, they are not an argument
                pos += fd.end(); continue
            count += 1; in_word = True
        if c == "\\":
            pos += 2
        elif c == "'":
            pos = src.find("'", pos + 1) + 1 or n
        elif c == '"':
            pos = skip_double_quotes(src, pos + 1)
        elif src.startswith("$(", pos):
            pos = skip_parens(src, pos + 2)
        elif src.startswith("${", pos):
            pos = src.find("}", pos + 2) + 1 or n
        else:
            pos += 1
    return count


def skip_double_quotes(src, pos):
    n = len(src)
    while pos < n and src[pos] != '"':
        if src[pos] == "\\":
            pos += 2
        elif src.startswith("$(", pos):
            pos = skip_parens(src, pos + 2)
        else:
            pos += 1
    return pos + 1


def skip_parens(src, pos):
    n, depth = len(src), 1
    while pos < n and depth:
        c = src[pos]
        if c == "\\":
            pos += 2; continue
        if c == "'":
            pos = src.find("'", pos + 1) + 1 or n; continue
        if c == '"':
            pos = skip_double_quotes(src, pos + 1); continue
        depth += (c == "(") - (c == ")")
        pos += 1
    return pos


text = SCRIPT.read_text(encoding="utf-8")
errors = []

marker = "done <<'EOF'"
start = text.find(marker)
if start == -1:
    errors.append("message catalog heredoc not found")
else:
    start = text.find("\n", start) + 1
    end = text.find("\nEOF\n", start)
    rows = text[start:end].splitlines() if end != -1 else []
    keys = set()
    catalog = {}
    for n, row in enumerate(rows, 1):
        parts = row.split("\t")
        if len(parts) != 3:
            errors.append(f"catalog row {n}: expected 3 tab-separated fields")
            continue
        key, en, es = parts
        if key in keys:
            errors.append(f"duplicate catalog key: {key}")
        keys.add(key)
        catalog[key] = (en, es)
        if not en or not es:
            errors.append(f"empty translation: {key}")
        # Both languages must preserve the same printf placeholders and escaped line breaks.
        if re.findall(r"%[a-zA-Z]", en) != re.findall(r"%[a-zA-Z]", es):
            errors.append(f"placeholder mismatch: {key}")
        if en.count(r"\n") != es.count(r"\n"):
            errors.append(f"escaped newline mismatch: {key}")
        # Single-line messages keep the same closing punctuation across languages.
        if r"\n" not in en and r"\n" not in es and en[-1:] in '.!?…' and es[-1:] != en[-1:]:
            errors.append(f"closing punctuation mismatch: {key}")

    # Every translation key used by the script must exist; unused catalog entries are rejected.
    calls = set(re.findall(r"\bt\s+(?:[\"\'])?([A-Z][A-Z0-9_]*)(?:[\"\'])?\b", text))
    missing = sorted(calls - keys)
    unused = sorted(keys - calls)
    if missing:
        errors.append("missing catalog keys: " + ", ".join(missing))
    if unused:
        errors.append("unused catalog keys: " + ", ".join(unused))

    # A sentence lives in one key: KEY next to KEY2 (or KEY1, KEY2) is one message cut in pieces, which cannot be reordered in translation.
    def split_keys(names):
        stems = {}
        for name in names:
            stems.setdefault(name.rstrip("0123456789"), []).append(name)
        return sorted(n for group in stems.values() if len(group) > 1 for n in group)

    if split_keys({"A_B", "A_B2", "C_D"}) != ["A_B", "A_B2"] or split_keys({"A_B1", "A_B2"}) != ["A_B1", "A_B2"] or split_keys({"A_B", "C_D"}):
        errors.append("split-key check does not behave as intended")
    if split_keys(keys):
        errors.append("sentence split across catalog keys: " + ", ".join(split_keys(keys)))

    # Each t call must pass exactly as many arguments as its message has printf placeholders:
    # printf pads missing ones with blanks and silently repeats the format for extra ones.
    def placeholders(message):
        return len(re.findall(r"%[-0-9.]*[a-zA-Z]", message.replace("%%", "")))

    # The key may be quoted ($(t "KEY")). The guard is deliberately looser than the scan, so any call
    # shape the scan cannot parse is reported instead of silently skipped.
    T_CALL = r"(?<![\w$-])t[ \t]+([\"']?)([A-Z][A-Z0-9_]*)\1(?=[\s)\"';|&]|$)"
    T_LOOKALIKE = r"(?<![\w$-])t(?:[ \t]|\\\n)+[\"']?[A-Z]"

    def arity_scan(script):
        """(errors, calls checked) for the t calls in a script text."""
        head = script.find("\nEOF\n", script.find(marker))
        body, found, checked = script[head:], [], 0
        for call in re.finditer(T_CALL, body):
            key = call.group(2)
            if key not in catalog:
                continue
            line_no = script.count("\n", 0, head) + body.count("\n", 0, call.start()) + 1
            given = shell_words_after(body, call.end())
            checked += 1
            for lang, message in zip(("EN", "ES"), catalog[key]):
                if placeholders(message) != given:
                    found.append(f"t {key} at line {line_no}: {given} argument(s) for {placeholders(message)} placeholder(s) in {lang}")
        if checked < len(re.findall(T_LOOKALIKE, body)):
            found.append("argument-count scan skipped some t calls")
        return found, checked

    scan_errors, arity_checked = arity_scan(text)
    errors.extend(scan_errors)

    # Mutations: the scan must flag each of these, or a green run proves nothing.
    for name, old, new in (
        ("quoted key given an argument", '$(t "DESKTOP_GENERIC")', '$(t "DESKTOP_GENERIC" extra)'),
        ("unquoted key missing its argument", 't V4L2_MISSING "$V4L2_DEVICE"', "t V4L2_MISSING"),
        ("call shape the scan cannot parse", '$(t "DESKTOP_COMMENT")', '$(t "DESKTOP_COMMENT"x)'),
        ("file-descriptor redirection hiding a missing argument", 't V4L2_MISSING "$V4L2_DEVICE"', "t V4L2_MISSING 2>/dev/null"),
        ("call split from its key by a line continuation", '$(t "DESKTOP_COMMENT")', '$(t \\\n "DESKTOP_COMMENT")'),
    ):
        mutant = text.replace(old, new, 1)
        if mutant == text or not arity_scan(mutant)[0]:
            errors.append(f"arity scan does not catch: {name}")

    if arity_scan(text.replace('t V4L2_MISSING "$V4L2_DEVICE"', 't V4L2_MISSING "$V4L2_DEVICE" 2>/dev/null', 1))[0]:
        errors.append("arity scan rejects a correct call followed by a redirection")

    # Prevent accidental printf expansion in a translation with no argument.
    if re.search(r"(?<!\w)printf \"\$text\"", text):
        errors.append("translation helper passes catalog text directly as an unsafe printf format")
    if "printf '%b' \"$text\"" not in text:
        errors.append("translation helper does not preserve escaped newlines for messages without arguments")

    # These are technical command/config values and must remain identical where translated text mentions them.
    required_literals = ["scrcpy", "v4l2loopback", "PipeWire", "PulseAudio", "PHONECAM_LANG", "AUTO_MODE", "CAMERA_FACING"]
    for key, (en, es) in catalog.items():
        for literal in required_literals:
            if literal in en and literal not in es:
                errors.append(f"technical literal lost in Spanish translation: {key}: {literal}")

if not README.exists() or not README_ES.exists():
    errors.append("bilingual README files are incomplete")
else:
    en = README.read_text(encoding="utf-8")
    es = README_ES.read_text(encoding="utf-8")
    if "[Español](README-es.md)" not in en:
        errors.append("English README does not link to Spanish README")
    if "[English version](README.md)" not in es:
        errors.append("Spanish README does not link to English README")
    for name, data in (("English", en), ("Spanish", es)):
        if "PHONECAM_LANG" not in data:
            errors.append(f"{name} README does not document PHONECAM_LANG")
        if "phonecam l" not in data:
            errors.append(f"{name} README does not document the quick language switch")
    # Both command tables must list the same commands (a prose mention elsewhere does not make up for a missing row).
    cmds = lambda data: sorted(re.findall(r"^\| `(phonecam[^`]*)`", data, re.M))
    if cmds(en) != cmds(es):
        errors.append(f"README command tables differ: only English {sorted(set(cmds(en)) - set(cmds(es)))}, only Spanish {sorted(set(cmds(es)) - set(cmds(en)))}")
    # Each README shows screenshots in its own language, from files in the repo (one hosted image shared by both cannot).
    for name, data, lang in (("English", en, "en"), ("Spanish", es, "es")):
        shots = [s for s in re.findall(r'<img[^>]*\bsrc="([^"]+)"', data) if not s.endswith("phonecam-icon.png")]
        if not shots or not all(re.fullmatch(rf"assets/screenshots/[\w-]+-{lang}\.png", s) and (ROOT / s).is_file() for s in shots):
            errors.append(f"{name} README screenshots must be existing assets/screenshots/*-{lang}.png files: {shots}")
        # width= is the PNG's own pixel width (IHDR), so the README shows each screenshot unscaled.
        for tag in re.findall(r"<img\b[^>]*>", data):
            src, width = re.search(r'\bsrc="(assets/screenshots/[^"]+)"', tag), re.search(r'\bwidth="(\d+)"', tag)
            if src and (ROOT / src.group(1)).is_file():
                head = (ROOT / src.group(1)).read_bytes()[:24]
                real = struct.unpack(">I", head[16:20])[0] if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR" else None
                if real is None or not width or int(width.group(1)) != real:
                    errors.append(f"{name} README: {src.group(1)} is {real} px wide, its width is {width.group(1) if width else None}")
    # Internal links must resolve to real local sections/files.
    for name, data in (("English", en), ("Spanish", es)):
        headings = set()
        for h in re.findall(r"^#{2,6} +(.+)$", data, re.M):
            slug = re.sub(r"[^\w -]", "", h.lower(), flags=re.UNICODE).replace(" ", "-")
            headings.add(slug)
        for target in re.findall(r"\]\((#[^)]+)\)", data):
            if target[1:] not in headings:
                errors.append(f"{name} README has unresolved internal link: {target}")
        for target in re.findall(r"\]\(([^)#][^)]*)\)", data):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            target_path = (ROOT / target.split("#", 1)[0]).resolve()
            if not target_path.exists():
                errors.append(f"{name} README has unresolved local link: {target}")
    # The main README is English: obvious Spanish-only markers should not remain in prose.
    for forbidden in ["## Qué es", "## Ventajas", "## Compatibilidad", "## Instalación", "## Idioma y roadmap"]:
        if forbidden in en:
            errors.append(f"English README still contains Spanish heading: {forbidden}")

if errors:
    for error in errors:
        print(f"not ok - {error}")
    sys.exit(1)

print(f"ok - localization catalog, placeholders, technical literals, {arity_checked} t-call argument counts and bilingual README integrity")
