#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/run" "$TMP_DIR/logs" "$TMP_DIR/v4l2"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
export PATH="$TMP_DIR/bin:$PATH" SCRCPY_LOG="$TMP_DIR/scrcpy.log" PACTL_LOG="$TMP_DIR/pactl.log" ZENITY_LOG="$TMP_DIR/zenity.log"
cat > "$TMP_DIR/bin/adb" <<'EOF'
#!/bin/sh
case "${ADB_CASE:-one}" in
  none) printf 'List of devices attached\n';;
  multi) printf 'List of devices attached\nA\tdevice\nB\tdevice\n';;
  one) printf 'List of devices attached\nA\tdevice\n';;
  *) exit 1;;
esac
EOF
cat > "$TMP_DIR/bin/scrcpy" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then printf '%s\n' "${SCRCPY_VERSION:-scrcpy 3.0}"; exit "${SCRCPY_RC:-0}"; fi
for arg in "$@"; do [ "$arg" = --list-cameras ] && { printf '%s\n' '--camera-id=0 back'; exit 0; }; done
/bin/sleep 1000 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
EOF
cat > "$TMP_DIR/bin/zenity" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ZENITY_LOG"
case "${ZENITY_CASE:-accept}" in cancel) exit 1;; multi) printf 'B\n';; *) exit 0;; esac
EOF
cat > "$TMP_DIR/bin/pactl" <<'EOF'
#!/bin/sh
case "${PACTL_CASE:-ok}:${1:-}:${2:-}:${3:-}" in
  fail-load:load-module*) exit 1;;
  route-fail:*move-sink-input*) exit 1;;
  *:list:short:sinks) [ "${PACTL_CASE:-ok}" = fail-load ] && exit 0 || printf '1\tPhoneMicSink\n';;
  *:list:short:sources) printf '2\tPhoneMic\n';;
  *:list*) printf 'Sink Input #5\n application.process.binary = "other"\n';;
  *) exit 0;;
esac
EOF
cat > "$TMP_DIR/bin/notify-send" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP_DIR/bin"/*
source "$SCRIPT"
CONF_DIR="$HOME/.config/phonecam"; CONF_FILE="$CONF_DIR/phonecam.conf"; RUN_DIR="$TMP_DIR/run/phonecam"; LOG_DIR="$TMP_DIR/logs"; V4L2_DEVICE="$TMP_DIR/v4l2/video42"; mkdir -p "$RUN_DIR"; touch "$V4L2_DEVICE"

ensure_scrcpy_installed(){ return 0; }
pass=0 fail=0
ok(){ pass=$((pass+1)); echo "ok - $1"; }
bad(){ fail=$((fail+1)); echo "not ok - $1"; }
check(){ local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
expect_fail(){ local d="$1"; shift; if "$@"; then bad "$d"; else ok "$d"; fi; }
# Runs "$@" on a desktop (DISPLAY set) whose PATH lacks the tools named in $1. A real desktop has zenity, adb and pactl
# in /usr/bin, so a PATH cut down to /usr/bin:/bin would still find them (and zenity would open a window and hang).
desktop_lacking() {
    local names="$1" d="$TMP_DIR/path-${1// /-}" n; shift
    mkdir -p "$d"
    ln -sf -t "$d" /bin/* 2>/dev/null || :; ln -sf -t "$d" /usr/bin/* 2>/dev/null || :; ln -sf -t "$d" "$TMP_DIR"/bin/*
    for n in $names; do rm -f "$d/$n"; done
    ( PATH="$d"; hash -r; DISPLAY=:0 "$@" )
}

check 'required tools detected when present' require_tools
: > "$ZENITY_LOG"; check 'connection help uses graphical helper when present' desktop_lacking '' show_connection_help
check 'connection help opened its dialog through zenity' grep -q -- '--info' "$ZENITY_LOG"
: > "$ZENITY_LOG"; check 'connection help falls back to terminal without zenity' desktop_lacking zenity show_connection_help
check 'terminal fallback does not call zenity' test ! -s "$ZENITY_LOG"

expect_fail 'missing adb/pactl rejected by require_tools' desktop_lacking 'adb pactl' require_tools
export ADB_CASE=none; expect_fail 'ADB rejects no device' adb_serial
export ADB_CASE=multi; serial=$(desktop_lacking zenity adb_serial 2>/dev/null); [ "$serial" = A ] && ok 'ADB fallback picks first without GUI' || bad 'ADB fallback picks first without GUI'
export ADB_CASE=one; export SCRCPY_VERSION='scrcpy 2.1'; expect_fail 'scrcpy 2.1 rejected' check_scrcpy_version
export SCRCPY_VERSION='scrcpy 2.3.1'; check_scrcpy_version && ok 'scrcpy 2.3.1 accepted' || bad 'scrcpy 2.2 accepted'
export SCRCPY_VERSION='broken'; check_scrcpy_version && bad 'unknown scrcpy version rejected' || ok 'unknown scrcpy version rejected'
export SCRCPY_RC=7; expect_fail 'scrcpy execution error rejected' check_scrcpy_version; export SCRCPY_RC=0
export SCRCPY_VERSION='scrcpy 2.4'; expect_fail 'scrcpy_at_least rejects an older minor version' scrcpy_at_least 2 5
export SCRCPY_VERSION='scrcpy 2.5'; check 'scrcpy_at_least accepts the exact version' scrcpy_at_least 2 5
export SCRCPY_VERSION='scrcpy 2.10'; check 'scrcpy_at_least compares minor versions numerically' scrcpy_at_least 2 5
export SCRCPY_VERSION='scrcpy 3.3.1 <https://github.com/Genymobile/scrcpy>'; check 'scrcpy_at_least accepts a newer major version' scrcpy_at_least 2 5
export SCRCPY_VERSION='scrcpy 3.1'; expect_fail 'scrcpy_at_least rejects 3.1 for a 3.2 feature' scrcpy_at_least 3 2
export SCRCPY_VERSION='broken'; expect_fail 'scrcpy_at_least rejects an unknown version' scrcpy_at_least 2 5
export SCRCPY_VERSION='scrcpy 3.3'; export SCRCPY_RC=7; expect_fail 'scrcpy_at_least rejects an execution error' scrcpy_at_least 2 5; export SCRCPY_RC=0; unset SCRCPY_VERSION

rm -f "$V4L2_DEVICE"; expect_fail 'missing V4L2 rejected' ensure_v4l2_device; touch "$V4L2_DEVICE"
export PACTL_CASE=fail-load; expect_fail 'audio sink creation failure propagates' ensure_audio_devices; export PACTL_CASE=ok

CURRENT_LANG=en
m=$(validate_advanced_fields '1920-1080' '30fps' 'bad'); [[ "$m" == *'Resolution'* ]] && ok 'validation errors in English' || bad 'validation errors in English'
CURRENT_LANG=es
m=$(validate_advanced_fields '1920-1080' '30fps' 'bad'); [[ "$m" == *'Resolución'* ]] && ok 'validation errors in Spanish' || bad 'validation errors in Spanish'

CURRENT_LANG=en; set_config CAMERA_FACING "front"; source "$CONF_FILE"; [ "$CAMERA_FACING" = front ] && ok 'config save and reload' || bad 'config save and reload'
set_config CAMERA_SIZE "1920x1080"; grep -q "CAMERA_SIZE='1920x1080'" "$CONF_FILE" && ok 'quoted config value saved' || bad 'quoted config value saved'
printf '%s\n' "CAMERA_FACING='back'" > "$CONF_FILE"; pids=(); for i in 1 2 3 4 5 6 7 8 9 10; do ( source "$SCRIPT"; CONF_DIR="$HOME/.config/phonecam"; CONF_FILE="$CONF_DIR/phonecam.conf"; set_config CAMERA_FACING "value-$i" ) & pids+=("$!"); done; for pid in "${pids[@]}"; do wait "$pid"; done; check_config_lines=$(grep -c '^CAMERA_FACING=' "$CONF_FILE"); [ "$check_config_lines" -eq 1 ] && source "$CONF_FILE" && [[ "$CAMERA_FACING" =~ ^value-[0-9]+$ ]] && ok 'concurrent config writes stay valid' || bad 'concurrent config writes stay valid'
printf '%s\n' "CAMERA_FACING='back'" "CAMERA_FACING='front'" > "$CONF_FILE"; set_config CAMERA_FACING "auto"; check_config_lines=$(grep -c '^CAMERA_FACING=' "$CONF_FILE"); source "$CONF_FILE"; [ "$check_config_lines" -eq 2 ] && [ "$CAMERA_FACING" = auto ] && ok 'duplicate config keys all update' || bad 'duplicate config keys all update'

printf '%s\n' 'CAMERA_FACING="back"  # keep this comment' > "$CONF_FILE"; set_config CAMERA_FACING "front"; grep -Fxq "CAMERA_FACING='front'  # keep this comment" "$CONF_FILE" && ok 'double-quoted config comment preserved' || bad 'double-quoted config comment preserved'

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
