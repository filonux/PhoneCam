#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/adb" <<'EOF'
#!/bin/sh
[ "${1:-}" = devices ] && printf 'List of devices attached\n'
EOF
chmod +x "$TMP_DIR/bin/adb"
printf 'PHONECAM_LANG=en\n' > "$TMP_DIR/home/.config/phonecam/phonecam.conf"
set +e
printf 'l\n8\n' | HOME="$TMP_DIR/home" TERM=xterm PATH="$TMP_DIR/bin:/usr/bin:/bin" script -q -c "/bin/bash -c 'source \"$ROOT_DIR/script/phonecam.sh\"; load_config; cli_menu'" "$TMP_DIR/menu.out" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "not ok - terminal menu exited with $rc" >&2; exit 1; }
printf '%s\n' 'ok - terminal menu exits cleanly'
output="$(cat "$TMP_DIR/menu.out")"
grep -q 'Change language' <<<"$output" || { echo 'not ok - terminal menu shows English language option' >&2; exit 1; }
printf '%s\n' 'ok - terminal menu shows English language option'
grep -q 'Cambiar idioma' <<<"$output" || { echo 'not ok - terminal menu shows Spanish language option' >&2; exit 1; }
printf '%s\n' 'ok - terminal menu shows Spanish language option'
grep -q "PHONECAM_LANG='es'" "$TMP_DIR/home/.config/phonecam/phonecam.conf" || { echo 'not ok - terminal menu persists language toggle' >&2; exit 1; }
printf '%s\n' 'ok - terminal menu persists language toggle'
for spec in en:y:Y/n en:n:y/N es:y:S/n es:n:s/N; do
    IFS=: read -r lang def hint <<<"$spec"
    printf '\n' | script -q -c "/bin/bash -c 'source \"$ROOT_DIR/script/phonecam.sh\"; CURRENT_LANG=$lang; ask_yn Q $def'" "$TMP_DIR/ask.out" >/dev/null 2>&1
    grep -Fq "Q [$hint]" "$TMP_DIR/ask.out" || { echo "not ok - ask_yn prompt $lang/$def" >&2; exit 1; }
    printf 'ok - ask_yn prompt %s/%s\n' "$lang" "$def"
done
set +e
printf '\004' | HOME="$TMP_DIR/home" TERM=xterm PATH="$TMP_DIR/bin:/usr/bin:/bin" timeout 10 script -q -c "/bin/bash -c 'source \"$ROOT_DIR/script/phonecam.sh\"; load_config; cli_menu; echo RC=\$?'" "$TMP_DIR/eof.out" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fq 'RC=0' "$TMP_DIR/eof.out"; then
    printf '%s\n' 'ok - terminal menu exits on Ctrl-D'
else
    echo 'not ok - terminal menu exits on Ctrl-D' >&2; exit 1
fi
