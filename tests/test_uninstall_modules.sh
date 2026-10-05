#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/run"
chmod 755 "$TMP_DIR"
chmod 777 "$TMP_DIR/home" "$TMP_DIR/run"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" PATH="$TMP_DIR/bin:$PATH"
export PACTL_UNLOAD_LOG="$TMP_DIR/unload.log" PACTL_MODULES="$TMP_DIR/modules.txt"

# Module ids: 11/12 are the real PhoneCam modules (12 uses quoted values, as some
# PipeWire builds print them); 21-24 merely share a prefix or suffix with them.
printf '%s\t%s\t%s\n' \
    11 module-null-sink 'sink_name=PhoneMicSink sink_properties=device.description=PhoneMicSink' \
    21 module-null-sink 'sink_name=PhoneMicSinkOtro sink_properties=device.description=X' \
    22 module-null-sink 'sink_name=xPhoneMicSink' \
    31 module-remap-source 'master=PhoneMicSink.monitor source_name=PhoneMic' \
    23 module-remap-source 'master=PhoneMicSink.monitor source_name=PhoneMicOtro' \
    24 module-loopback 'sink_name=PhoneMicSink' \
    12 module-null-sink 'sink_name="PhoneMicSink"' > "$PACTL_MODULES"

cat > "$TMP_DIR/bin/pactl" <<'EOF_PACTL'
#!/bin/sh
case "$1 $2 $3" in
  "list short modules") cat "$PACTL_MODULES" ;;
  "unload-module "*) printf '%s\n' "$2" >> "$PACTL_UNLOAD_LOG" ;;
esac
exit 0
EOF_PACTL
chmod +x "$TMP_DIR/bin/pactl"
: > "$PACTL_UNLOAD_LOG"; chmod 666 "$PACTL_UNLOAD_LOG"

# The uninstaller refuses to run as root, so drop to "nobody" like the other suites.
run_uninstall() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || { echo 'runuser is required to drop root for the uninstall test' >&2; return 1; }
        runuser -u nobody -- bash "$SCRIPT" uninstall <<<n
    else
        bash "$SCRIPT" uninstall <<<n
    fi
}

pass=0
fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }

run_uninstall > "$TMP_DIR/uninstall.out" 2>&1 || { cat "$TMP_DIR/uninstall.out" >&2; bad 'uninstall completes'; }
unloaded="$(sort -n "$PACTL_UNLOAD_LOG" | tr '\n' ' ')"
check_eq 'uninstall unloads only modules whose name matches exactly' "$unloaded" '11 12 31 '

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
