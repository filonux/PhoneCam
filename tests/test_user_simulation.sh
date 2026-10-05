#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
export SCRCPY_PID_LOG="$TMP_DIR/scrcpy.pids"
cleanup(){
  trap - EXIT
  if [ -f "${SCRCPY_PID_LOG:-}" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      [ -r "/proc/$p/cmdline" ] || continue
      cmdline=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
      case "$cmdline" in *"$TMP_DIR/bin/scrcpy"*) kill -9 "$p" 2>/dev/null || true;; esac
    done < "$SCRCPY_PID_LOG"
  fi
  jobs -pr | while read -r p; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/bin" "$TMP_DIR/run" "$TMP_DIR/logs" "$TMP_DIR/v4l2"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
export PATH="$TMP_DIR/bin:/usr/bin:/bin"
export DISPLAY=":0"
export SCRCPY_LOG="$TMP_DIR/scrcpy.log"
export ADB_LOG="$TMP_DIR/adb.log"
export ADB_STAY_FILE="$TMP_DIR/adb-stay"
export ADB_STATE=connected
printf '2\n' > "$ADB_STAY_FILE"

cat > "$TMP_DIR/home/.config/phonecam/phonecam.conf" <<EOF_CONF
PHONECAM_LANG=auto
CAMERA_ID=
CAMERA_FACING=front
CAMERA_SIZE=1920x1080
CAMERA_FPS=30
VIDEO_QUALITY_PROFILE=balanced
AUDIO_CODEC=opus
AUDIO_BITRATE=192K
AUDIO_SOURCE=mic
AUTO_MODE=ask
TURN_SCREEN_OFF=false
KEEP_AWAKE=true
V4L2_DEVICE=$TMP_DIR/v4l2/video42
MIC_SINK_NAME=PhoneMicSink
MIC_SOURCE_NAME=PhoneMic
EOF_CONF

touch "$TMP_DIR/v4l2/video42"
cat > "$TMP_DIR/bin/adb" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${ADB_LOG:?}"
case "${1:-}" in
  start-server) exit 0 ;;
  devices)
    case "$ADB_STATE" in
      none) printf 'List of devices attached\n' ;;
      *) printf 'List of devices attached\nTEST123\tdevice\n' ;;
    esac
    ;;
  -s)
    [ "${2:-}" = TEST123 ] || exit 1
    shift 2
    [ "${1:-}" = shell ] || exit 0
    shift
    case "${1:-}" in
      getprop) [ "${2:-}" = ro.build.version.sdk ] && printf '35\n' ;;
      settings)
        case "${2:-}" in
          get) [ -s "${ADB_STAY_FILE:?}" ] && cat "$ADB_STAY_FILE" || printf '0\n' ;;
          put) printf '%s\n' "${5:-}" > "${ADB_STAY_FILE:?}" ;;
        esac
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
cat > "$TMP_DIR/bin/scrcpy" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then printf 'scrcpy 3.0\n'; exit 0; fi
printf '%s\n' "$$" >> "$SCRCPY_PID_LOG"
for arg in "$@"; do
  [ "$arg" = --list-cameras ] && { printf '%s\n' 'INFO: List of cameras:' '--camera-id=0  back' '--camera-id=1  front'; exit 0; }
done
printf '%s\n' "$*" >> "$SCRCPY_LOG"
/bin/sleep 1000 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
SH
cat > "$TMP_DIR/bin/pactl" <<'SH'
#!/bin/sh
case "${1:-}:${2:-}:${3:-}" in
  list:short:sinks) printf '1\tPhoneMicSink\n' ;;
  list:short:sources) printf '2\tPhoneMic\n' ;;
  list:short:modules) printf '10\tmodule-null-sink\t sink_name=PhoneMicSink\n11\tmodule-remap-source\t source_name=PhoneMic\n' ;;
  list:sink-inputs:*) printf 'Sink Input #44\n application.process.binary = "scrcpy"\n' ;;
  load-module|move-sink-input|unload-module*) exit 0 ;;
esac
SH
cat > "$TMP_DIR/bin/zenity" <<'SH'
#!/bin/sh
case "$*" in
  *--list*) printf '1\n' ;;
  *--forms*) printf 'front|1920x1080|30|balanced|mic|opus|192K|ask|false|true\n' ;;
  *--question*) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP_DIR/bin"/*
mkdir -p "$TMP_DIR/no-zenity-bin"
ln -s "$TMP_DIR/bin/adb" "$TMP_DIR/no-zenity-bin/adb"
ln -s "$TMP_DIR/bin/scrcpy" "$TMP_DIR/no-zenity-bin/scrcpy"
ln -s "$TMP_DIR/bin/pactl" "$TMP_DIR/no-zenity-bin/pactl"

run(){ timeout --kill-after=5s 30s bash "$SCRIPT" "$@"; }
expect_success(){ local label="$1"; shift; if output=$(run "$@" 2>&1); then printf 'ok - %s\n' "$label"; else printf 'not ok - %s\n%s\n' "$label" "$output" >&2; return 1; fi; }
expect_output(){ local label="$1" needle="$2"; shift 2; local output; output=$(run "$@" 2>&1); if [[ "$output" == *"$needle"* ]]; then printf 'ok - %s\n' "$label"; else printf 'not ok - %s (missing=%s)\n%s\n' "$label" "$needle" "$output" >&2; return 1; fi; }
expect_condition(){ local label="$1"; shift; if "$@"; then printf 'ok - %s\n' "$label"; else printf 'not ok - %s\n' "$label" >&2; return 1; fi; }

# Public user journey: discover -> choose -> start -> inspect -> stop -> repeat for mic/both -> switch language.
expect_output 'user sees available cameras' '--camera-id=0' cameras
expect_success 'user can choose the default camera' choose-cam
expect_condition 'chosen camera persisted' grep -Fxq "CAMERA_ID='1'" "$HOME/.config/phonecam/phonecam.conf"

expect_success 'user starts webcam from CLI' webcam
for _ in {1..20}; do [ -f "$XDG_RUNTIME_DIR/phonecam/webcam.pid" ] && break; /bin/sleep 0.05; done
expect_condition 'webcam pidfile created' test -f "$XDG_RUNTIME_DIR/phonecam/webcam.pid"
expect_output 'user sees active webcam status' 'Webcam' status

expect_condition 'webcam arguments recorded' grep -q -- '--video-source=camera' "$SCRCPY_LOG"
expect_condition 'webcam never passes --stay-awake to scrcpy' bash -c '! grep -q -- "--stay-awake" "$1"' _ "$SCRCPY_LOG"
expect_condition 'webcam keeps the phone awake over ADB instead' grep -Fq 'settings put global stay_on_while_plugged_in 7' "$ADB_LOG"
expect_success 'user stops webcam' stop
expect_condition 'webcam pidfile removed' test ! -f "$XDG_RUNTIME_DIR/phonecam/webcam.pid"
expect_condition 'stopping webcam restores the original stay-awake value' bash -c '[ "$(cat "$1")" = 2 ]' _ "$ADB_STAY_FILE"

expect_success 'user starts microphone from CLI' mic
expect_condition 'microphone pidfile created' test -f "$XDG_RUNTIME_DIR/phonecam/mic.pid"
expect_condition 'microphone arguments disable video' grep -q -- '--no-video' "$SCRCPY_LOG"
expect_condition 'microphone requires actual audio capture' grep -q -- '--require-audio' "$SCRCPY_LOG"
expect_success 'user stops microphone' stop
expect_condition 'microphone pidfile removed' test ! -f "$XDG_RUNTIME_DIR/phonecam/mic.pid"

expect_success 'user starts both devices' both
expect_condition 'combined mode pidfiles created' test -f "$XDG_RUNTIME_DIR/phonecam/webcam.pid" -a -f "$XDG_RUNTIME_DIR/phonecam/mic.pid"
expect_output 'user sees combined active status' 'Webcam' status
expect_success 'user stops both devices' stop
expect_condition 'combined mode pidfiles removed' test ! -f "$XDG_RUNTIME_DIR/phonecam/webcam.pid" -a ! -f "$XDG_RUNTIME_DIR/phonecam/mic.pid"

expect_success 'user switches interface to Spanish' l
expect_condition 'Spanish preference persisted' grep -Fxq "PHONECAM_LANG='es'" "$HOME/.config/phonecam/phonecam.conf"
expect_output 'Spanish status is visible' 'Conexión' status
expect_success 'user switches interface back to English' l
expect_condition 'English preference persisted' grep -Fxq "PHONECAM_LANG='en'" "$HOME/.config/phonecam/phonecam.conf"
# A real zenity in /usr/bin survives the PATH filter, so the missing GUI is also forced by dropping DISPLAY.
help_en=$(unset DISPLAY WAYLAND_DISPLAY; PATH="$TMP_DIR/no-zenity-bin:/usr/bin:/bin" run ayuda 2>&1)
expect_condition 'English terminal connection guide is visible' bash -c '[[ "$1" == *"On the phone: Settings"* ]]' _ "$help_en"

printf '%s\n' 'ok - complete public-CLI user simulation'
