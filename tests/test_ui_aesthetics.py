#!/usr/bin/env python3
import re
from pathlib import Path
import pathlib

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'script' / 'phonecam.sh'
text = SCRIPT.read_text(encoding='utf-8')

start = text.find("done <<'EOF'")
start = text.find('\n', start) + 1
end = text.find('\nEOF\n', start)
rows = [line.split('\t') for line in text[start:end].splitlines() if '\t' in line]
cat = {k: (en, es) for k, en, es in rows if len([k, en, es]) == 3}
errors = []

def check_max(key, n, label):
    for lang, idx in [('en', 0), ('es', 1)]:
        for part in cat[key][idx].split(r'\n'):
            # Conservative text budget for 560-720px Zenity dialogs and terminal menus.
            if len(part) > n:
                errors.append(f'{key} {lang} {label} too long: {len(part)} > {n}')

for key in ['MENU_WEBCAM_START','MENU_MIC_START','MENU_BOTH','MENU_CHOOSE_CAM','MENU_STATUS','MENU_CONFIG','MENU_HELP','MENU_EXIT']:
    check_max(key, 42, 'menu label')
for key in ['MENU_NEED_USB','MENU_CHOOSE_DESC','MENU_STATUS_DESC','MENU_CONFIG_DESC','MENU_HELP_DESC','MENU_EXIT_DESC','MENU_BOTH_DESC']:
    check_max(key, 92, 'menu description')

# Avoid accidental doubled punctuation when a description is wrapped by the CLI menu.
for key in ['MENU_CHOOSE_DESC','MENU_HELP_DESC','MENU_STATUS_DESC','MENU_CONFIG_DESC','MENU_EXIT_DESC','MENU_BOTH_DESC']:
    for lang in range(2):
        s = cat[key][lang].rstrip()
        if s.endswith(')') and ' (' in s:
            errors.append(f'{key} unexpectedly ends with a wrapped-parenthesis fragment')

# Visible labels should not contain raw ANSI escapes or unresolved translation markers.
for key, (en, es) in cat.items():
    for lang, value in [('en', en), ('es', es)]:
        if '\x1b[' in value:
            errors.append(f'{key} {lang} contains ANSI escape codes')
        if re.search(r'\[[A-Z][A-Z0-9_]+\]', value):
            errors.append(f'{key} {lang} contains unresolved translation marker')
        if re.search(r'[\U0001F300-\U0001FAFF\uFE0F\u200D]', value):
            errors.append(f'{key} {lang} contains font-dependent emoji in the CLI/GUI text')

# The Spanish webcam status needs feminine agreement in the compact GUI header.
if cat.get('INACTIVE_F') != ('inactive', 'inactiva'):
    errors.append('INACTIVE_F is missing or incorrect')
if '$(t INACTIVE_F)' not in text:
    errors.append('GUI header does not use feminine webcam inactive label')


# The shipped application icon is a real 1024x1024 RGBA asset with transparent padding.
icon = ROOT / 'assets' / 'phonecam-icon.png'
try:
    from PIL import Image
    with Image.open(icon) as im:
        if im.size != (1024, 1024):
            errors.append(f'icon size is {im.size}, expected 1024x1024')
        if im.mode != 'RGBA':
            errors.append(f'icon mode is {im.mode}, expected RGBA')
        alpha = im.getchannel('A')
        if alpha.getextrema() != (0, 255):
            errors.append('icon must contain both transparent padding and opaque artwork')
except Exception as exc:
    errors.append(f'could not inspect application icon: {exc}')

# The copy embedded in the script ("#@" lines) must show exactly the pixels of the asset.
try:
    import base64, io
    payload = ''.join(l[2:] for l in text.splitlines() if l.startswith('#@'))
    with Image.open(io.BytesIO(base64.b64decode(payload, validate=True))) as emb, Image.open(icon) as ref:
        if emb.size != ref.size or emb.convert('RGBA').tobytes() != ref.convert('RGBA').tobytes():
            errors.append('icon embedded in phonecam.sh differs from assets/phonecam-icon.png')
except Exception as exc:
    errors.append(f'could not inspect the embedded icon: {exc}')

# The Usage block is laid out by usage_row: one description column in both languages, derived from the function itself.
import os, subprocess, tempfile
row_def = re.search(r"^usage_row\(\) \{.*\}$", text, re.M).group(0)
name_width = int(re.search(r"%-(\d+)s", row_def).group(1))
pad_width = int(re.search(r"%(\d+)s' ''", row_def).group(1))
column = 2 + name_width + 1
usage_names = [q or w for q, w in re.findall(r"^\s+usage_row (?:'([^']+)'|(\S+))", text, re.M)]

def usage_problems(script, lang):
    out = subprocess.run(["bash", str(script), "help"], capture_output=True, text=True,
                         env=dict(os.environ, HOME=tempfile.mkdtemp(), PHONECAM_LANG=lang)).stdout.splitlines()
    starts = {len(m.group(0)) for m in (re.match(r"^  \S+ +(?=\S)", l) for l in out) if m}
    starts |= {len(l) - len(l.lstrip()) for l in out if l.startswith("   ")}
    commands = [l for l in out if re.match(r"^  \S", l)]
    if len(commands) != len(usage_names) or starts != {column}:
        return [f"usage block ({lang}): {len(commands)}/{len(usage_names)} commands, description columns {sorted(starts)}, expected {column}"]
    return []

if pad_width != column:
    errors.append(f"usage_row pads continuation lines to column {pad_width} but descriptions start at column {column}")
if max(map(len, usage_names)) > name_width:
    errors.append("a command name is wider than the usage_row name column")
for lang in ("en", "es"):
    errors += usage_problems(SCRIPT, lang)
# Mutations: the old misalignment (the widest command sticks out by one column) and a short continuation pad must both be caught.
with tempfile.TemporaryDirectory() as tmp:
    for label, old, new_ in (("narrow name column", f"%-{name_width}s", f"%-{name_width - 1}s"), ("short continuation pad", f"%{pad_width}s' ''", f"%{pad_width - 1}s' ''")):
        mutant = pathlib.Path(tmp) / "mutant.sh"
        mutant.write_text(text.replace(old, new_, 1), encoding="utf-8")
        if mutant.read_text(encoding="utf-8") == text or not usage_problems(mutant, "en"):
            errors.append(f"usage layout check does not catch: {label}")
if re.search(r"t USAGE_\w+ \| sed", text):
    errors.append("catalog usage text is trimmed by fixed widths instead of being translated as description only")

# Unicode symbols are intentional UI glyphs; ensure files stay valid UTF-8.
for path in [SCRIPT, ROOT / 'README.md', ROOT / 'README-es.md']:
    path.read_text(encoding='utf-8')

if errors:
    for e in errors:
        print('not ok - ' + e)
    raise SystemExit(1)
print('ok - UI text budgets, punctuation, encoding and status-label aesthetics')
