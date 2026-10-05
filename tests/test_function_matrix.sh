#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
cleanup(){
  if [ -f "${SCRCPY_PID_LOG:-}" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      [ -r "/proc/$p/cmdline" ] || continue
      cmdline=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
      case "$cmdline" in *"$TMP_DIR/bin/scrcpy"*) kill "$p" 2>/dev/null || true;; esac
    done < "$SCRCPY_PID_LOG"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      alive=0
      while read -r p; do
        [ -n "$p" ] || continue
        [ -r "/proc/$p/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
        case "$cmdline" in *"$TMP_DIR/bin/scrcpy"*) alive=1;; esac
      done < "$SCRCPY_PID_LOG"
      [ "$alive" -eq 0 ] && break
      /bin/sleep 0.05
    done
    while read -r p; do
      [ -n "$p" ] || continue
      [ -r "/proc/$p/cmdline" ] || continue
      cmdline=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
      case "$cmdline" in *"$TMP_DIR/bin/scrcpy"*) kill -9 "$p" 2>/dev/null || true;; esac
    done < "$SCRCPY_PID_LOG"
  fi
  jobs -pr | while read -r p; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/run" "$TMP_DIR/logs" "$TMP_DIR/v4l2"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
export RUN_DIR="$TMP_DIR/run/phonecam" LOG_DIR="$TMP_DIR/logs"
export SCRCPY_LOG="$TMP_DIR/scrcpy.log" PACTL_LOG="$TMP_DIR/pactl.log" SCRCPY_PID_LOG="$TMP_DIR/scrcpy.pids" ADB_STATE_FILE="$TMP_DIR/adb-stay" ADB_LOG="$TMP_DIR/adb.log"
mkdir -p "$RUN_DIR"

cat > "$TMP_DIR/bin/adb" <<'EOF'
#!/bin/sh
STATE_FILE="${ADB_STATE_FILE:?}"
case "${1:-}" in
  start-server) exit 0 ;;
  devices) printf 'List of devices attached\n'; printf '%b' "${ADB_DEVICES:-SERIAL1\tdevice\n}" ;;
  -s)
    serial="$2"; shift 2
    case "$serial" in SERIAL1) ;; SERIAL2) STATE_FILE="$STATE_FILE.2" ;; *) exit 1 ;; esac
    [ "${ADB_DRAIN_STDIN:-}" = 1 ] && cat > /dev/null
    [ "${1:-}" = shell ] || exit 0
    shift
    case "${1:-}" in
      getprop) [ "${2:-}" = ro.build.version.sdk ] && printf '%s\n' "${ADB_API:-35}" ;;
      settings)
        case "${2:-}" in
          get) [ -s "$STATE_FILE" ] && cat "$STATE_FILE" || printf '0\n' ;;
          put) printf '%s\n' "${5:-}" > "$STATE_FILE" ;;
        esac
        ;;
      cmd) [ "${2:-}" = display ] && [ "${3:-}" = power-off ] && printf '%s\n' 'display-power-off' >> "${ADB_LOG:?}" ;;
      input) printf '%s\n' "input $*" >> "${ADB_LOG:?}" ;;
      dumpsys) printf 'mWakefulness=Awake\n' ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP_DIR/bin/scrcpy" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then printf 'scrcpy %s\n' "${SCRCPY_VERSION:-3.0}"; exit 0; fi
printf '%s\n' "$$" >> "$SCRCPY_PID_LOG"
for arg in "$@"; do
  [ "$arg" = "--list-cameras" ] && { printf 'INFO: List of cameras:\n--camera-id=0  back\n--camera-id=1  front\n'; exit 0; }
done
printf '%s\n' "$*" >> "$SCRCPY_LOG"
trap 'exit 0' TERM INT
if [ "${SCRCPY_BUSY:-0}" = 1 ]; then
  while :; do :; done
fi
while :; do /bin/sleep 1; done
EOF
cat > "$TMP_DIR/bin/pactl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PACTL_LOG"
if [ "${1:-}" = list ] && [ "${2:-}" = short ]; then
  case "${3:-}" in
    sinks) printf '1\tPhoneMicSink\tmodule-null-sink.c\n' ;;
    sources) printf '2\tPhoneMic\tmodule-remap-source.c\n' ;;
    modules) printf '10\tmodule-null-sink\t sink_name=PhoneMicSink\n11\tmodule-remap-source\t source_name=PhoneMic\n' ;;
  esac
elif [ "${1:-}" = list ]; then
  printf 'Sink Input #44\n application.process.binary = "scrcpy"\n'
fi
case "${1:-}" in
  load-module|unload-module|move-sink-input) exit 0 ;;
esac
exit 0
EOF
cat > "$TMP_DIR/bin/zenity" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ZENITY_LOG"
case "$*" in
  *'--print-column=1'*) printf '1\n' ;;
  *'--forms'*)
      if [ "${ZENITY_FORM:-}" = defaults ]; then
        n=0; for a in "$@"; do case "$a" in --combo-values=*) v=${a#--combo-values=}; n=$((n+1)); eval "c$n=\${v%%|*}" ;; esac; done
        printf '%s|1920x1080|30|%s|%s|%s|192K|%s|%s|%s\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7"
      else printf 'back|1920x1080|30|balanced|mic|opus|192K|ask|false|true\n'; fi ;;
  *'--question'*) exit 0 ;;
  *'--progress'*) cat >/dev/null; exit 0 ;;
  *'--list'*)
      case "$ZENITY_CHOICE" in auto) printf '(auto)\n';; 2) printf '2\n';; *) printf '1\n';; esac ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP_DIR/bin/notify-send" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_LOG"
exit 0
EOF
cat > "$TMP_DIR/bin/yad" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$YAD_LOG"
exit 0
EOF
cat > "$TMP_DIR/bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat > "$TMP_DIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
EOF
cat > "$TMP_DIR/bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
EOF
chmod +x "$TMP_DIR/bin"/*
export PATH="$TMP_DIR/bin:$PATH"
export DISPLAY=":0"
hash -r
export ZENITY_LOG="$TMP_DIR/zenity.log" NOTIFY_LOG="$TMP_DIR/notify.log" YAD_LOG="$TMP_DIR/yad.log" SYSTEMCTL_LOG="$TMP_DIR/systemctl.log" SUDO_LOG="$TMP_DIR/sudo.log"
: > "$ZENITY_LOG"; : > "$NOTIFY_LOG"; : > "$YAD_LOG"; : > "$SYSTEMCTL_LOG"; : > "$SUDO_LOG"; : > "$ADB_LOG"; printf '0\n' > "$ADB_STATE_FILE"

source "$SCRIPT"
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
RUN_DIR="$TMP_DIR/run/phonecam"
LOG_DIR="$TMP_DIR/logs"
BIN_DIR="$TMP_DIR/bin-installed"
INSTALLED_BIN="$BIN_DIR/phonecam"
SCRCPY_DIR="$TMP_DIR/scrcpy"
PID_WEBCAM="$RUN_DIR/webcam.pid" PID_MIC="$RUN_DIR/mic.pid" PID_ROUTE="$RUN_DIR/route.pid"
PID_AGENT="$RUN_DIR/agent.pid"
V4L2_DEVICE="$TMP_DIR/v4l2/video42" MIC_SINK_NAME=PhoneMicSink MIC_SOURCE_NAME=PhoneMic
mkdir -p "$BIN_DIR" "$SCRCPY_DIR"
touch "$V4L2_DEVICE"
CURRENT_LANG=en
ICON_FILE="$TMP_DIR/icon/phonecam.png"; ICON_SOURCE="$ROOT_DIR/assets/phonecam-icon.png"

# Direct rendering helpers: keep the public status functions covered without shadowing their names.
ui_info=$(info 'test message'); [[ "$ui_info" == 'ℹ test message' ]] || { echo 'not ok - info output'; exit 1; }
ui_ok=$(ok 'test message'); [[ "$ui_ok" == '✓ test message' ]] || { echo 'not ok - ok output'; exit 1; }
ui_warn=$(warn 'test message'); [[ "$ui_warn" == '⚠ test message' ]] || { echo 'not ok - warn output'; exit 1; }
ui_err=$(err 'test message' 2>&1); [[ "$ui_err" == '✗ test message' ]] || { echo 'not ok - err output'; exit 1; }
ui_hdr=$(hdr 'test header'); [[ "$ui_hdr" == 'test header' ]] || { echo 'not ok - hdr output'; exit 1; }
notify 'PhoneCam' 'test notification'; grep -Fq -- 'test notification' "$NOTIFY_LOG" || { echo 'not ok - notify output'; exit 1; }

pass=0 fail=0
pass_case(){ pass=$((pass+1)); echo "ok - $1"; }
fail_case(){ fail=$((fail+1)); echo "not ok - $1"; }
check(){ local d="$1"; shift; if "$@"; then pass_case "$d"; else fail_case "$d"; fi; }
check_eq(){ local d="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then pass_case "$d"; else fail_case "$d (expected=$e got=$a)"; fi; }
cat > "$TMP_DIR/bin/notify-send" <<'EOF_NOTIFY'
#!/bin/sh
exit 1
EOF_NOTIFY
chmod +x "$TMP_DIR/bin/notify-send"
check 'notification failure is non-fatal' notify 'title' 'body'
cat > "$TMP_DIR/bin/notify-send" <<'EOF_NOTIFY_OK'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_LOG"
exit 0
EOF_NOTIFY_OK
chmod +x "$TMP_DIR/bin/notify-send"

check_eq 'camera bitrate balanced' 20M "$(video_bitrate)"
check 'window icon falls back before install' test "$(window_icon)" = camera-web
rm -f "$ICON_FILE"; check 'custom application icon installs atomically' install_app_icon; check 'installed icon is used by UI helper' test "$(window_icon)" = "$ICON_FILE"; check 'installed icon has expected dimensions' python3 - "$ICON_FILE" <<'PY2'
from PIL import Image
import sys
with Image.open(sys.argv[1]) as im:
    assert im.size == (1024, 1024)
    assert im.mode == 'RGBA'
    assert im.getchannel('A').getextrema() == (0, 255)
PY2

# Embedded icon: used only when neither the repository asset nor an installed icon exists.
ICON_CASE_DIR="$TMP_DIR/icon-embedded"; mkdir -p "$ICON_CASE_DIR"
payload_complete() { icon_payload > /dev/null; }
# icon_case FILTER...: install_app_icon from a copy of the script passed through FILTER, with no asset beside it.
icon_case() (
    SELF_PATH="$ICON_CASE_DIR/phonecam.sh"; ICON_SOURCE="$ICON_CASE_DIR/no-asset.png"; ICON_FILE="$ICON_CASE_DIR/out/phonecam.png"
    "$@" < "$SCRIPT" > "$SELF_PATH"; rm -rf "$ICON_CASE_DIR/out"
    install_app_icon
)
icon_case_rejected() { ! icon_case "$@" && [ ! -e "$ICON_CASE_DIR/out/phonecam.png" ]; }
icon_pixels_match() { python3 - "$1" "$ROOT_DIR/assets/phonecam-icon.png" <<'PY3'
from PIL import Image
import sys
a, b = (Image.open(p).convert('RGBA') for p in sys.argv[1:3])
assert a.size == b.size == (1024, 1024) and a.tobytes() == b.tobytes()   # getbbox() of a difference ignores RGB where alpha agrees
PY3
}
icon_asset_wins() (
    ICON_SOURCE="$ICON_CASE_DIR/asset.png"; ICON_FILE="$ICON_CASE_DIR/wins/phonecam.png"
    printf 'asset' > "$ICON_SOURCE"
    install_app_icon && [ "$(cat "$ICON_FILE")" = asset ]
)
icon_keeps_installed() (
    ICON_SOURCE="$ICON_CASE_DIR/no-asset.png"; ICON_FILE="$ICON_CASE_DIR/kept/phonecam.png"
    mkdir -p "$ICON_CASE_DIR/kept"; printf 'custom' > "$ICON_FILE"
    install_app_icon && [ "$(cat "$ICON_FILE")" = custom ]
)
check 'embedded icon payload is complete' payload_complete
check 'script without assets installs the embedded icon' icon_case cat
check 'embedded icon matches the repository asset pixel for pixel' icon_pixels_match "$ICON_CASE_DIR/out/phonecam.png"
check_eq 'embedded icon is installed with mode 644' 644 "$(stat -c %a "$ICON_CASE_DIR/out/phonecam.png")"
check 'missing icon payload is rejected without writing a file' icon_case_rejected sed '/^#@/d'
check 'icon payload cut at a line boundary is rejected' icon_case_rejected sed '$d'
check 'icon payload cut mid-line is rejected' icon_case_rejected head -c -5
check 'icon payload truncated to its first lines is rejected' icon_case_rejected awk '/^#@/ && ++n > 50 {next} 1'
check 'icon beside the script wins over the embedded one' icon_asset_wins
check 'installed icon wins over the embedded one' icon_keeps_installed

cp "$TMP_DIR/bin/scrcpy" "$TMP_DIR/scrcpy-functional-stub"
cat > "$TMP_DIR/bin/scrcpy" <<'EOF'
#!/bin/sh
printf 'no version here\n'
EOF
chmod +x "$TMP_DIR/bin/scrcpy"; hash -r
if check_scrcpy_version >/dev/null 2>&1; then fail_case 'unknown scrcpy version rejected'; else pass_case 'unknown scrcpy version rejected'; fi
cat > "$TMP_DIR/bin/scrcpy" <<'EOF'
#!/bin/sh
printf 'scrcpy 2.3.0\n'
EOF
chmod +x "$TMP_DIR/bin/scrcpy"; hash -r
if check_scrcpy_version >/dev/null 2>&1; then fail_case 'scrcpy 2.3.0 rejected'; else pass_case 'scrcpy 2.3.0 rejected'; fi
cat > "$TMP_DIR/bin/scrcpy" <<'EOF'
#!/bin/sh
printf 'scrcpy 2.3.1\n'
EOF
chmod +x "$TMP_DIR/bin/scrcpy"; hash -r
if check_scrcpy_version >/dev/null 2>&1; then pass_case 'scrcpy 2.3.1 minimum accepted'; else fail_case 'minimum scrcpy version accepted'; fi
cp "$TMP_DIR/scrcpy-functional-stub" "$TMP_DIR/bin/scrcpy"; chmod +x "$TMP_DIR/bin/scrcpy"; hash -r
VIDEO_QUALITY_PROFILE=max
check_eq 'camera bitrate max' 30M "$(video_bitrate)"
check_eq 'video codec max' h265 "$(video_codec)"
camera_listing="$(phone_camera_list SERIAL1)"; check 'phone camera helper returns camera data' grep -q -- '--camera-id=0' <<<"$camera_listing"
TIMEOUT_LOG="$TMP_DIR/timeout.log"; export TIMEOUT_LOG; : > "$TIMEOUT_LOG"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$TIMEOUT_LOG"\nshift\nexec "$@"\n' > "$TMP_DIR/bin/timeout"; chmod +x "$TMP_DIR/bin/timeout"; hash -r
phone_camera_list SERIAL1 >/dev/null
check 'phone camera helper runs scrcpy under a time limit' grep -Eq '^[0-9]+ scrcpy -s SERIAL1 --list-cameras$' "$TIMEOUT_LOG"
rm -f "$TMP_DIR/bin/timeout"; hash -r
VIDEO_QUALITY_PROFILE=balanced
check_eq 'video codec balanced' h264 "$(video_codec)"
CAMERA_ID=7; build_camera_args; check_eq 'camera id args' '--camera-id=7' "${CAMERA_ARGS[0]}"
CAMERA_ID=; CAMERA_FACING=front; build_camera_args; check_eq 'camera facing args' '--camera-facing=front' "${CAMERA_ARGS[0]}"
printf '2\n' > "$ADB_STATE_FILE"; check_eq 'stay-awake value is read from the phone' 2 "$(phone_stay_awake_get SERIAL1)"
phone_keep_awake_start SERIAL1
check_eq 'keep-awake sets AC/USB/wireless on the phone' 7 "$(cat "$ADB_STATE_FILE")"
check 'keep-awake saves the original value before changing it' grep -Fxq 'SERIAL1 2' "$RUN_DIR/keepawake.saved"
phone_keep_awake_stop
check_eq 'keep-awake restores the original value once capture stops' 2 "$(cat "$ADB_STATE_FILE")"
check 'keep-awake clears its saved-value file after restoring' bash -c '[ ! -e "$1" ]' _ "$RUN_DIR/keepawake.saved"
# A restore that fails (phone unplugged) keeps the original value for the next stop; the value of another phone stays pending too.
phone_keep_awake_start SERIAL1
mv "$TMP_DIR/bin/adb" "$TMP_DIR/adb.real"; printf '#!/bin/sh\nexit 1\n' > "$TMP_DIR/bin/adb"; chmod +x "$TMP_DIR/bin/adb"
check 'keep-awake stop stays successful when the restore fails' phone_keep_awake_stop
mv -f "$TMP_DIR/adb.real" "$TMP_DIR/bin/adb"
check 'keep-awake keeps the saved value when the restore fails' grep -Fxq 'SERIAL1 2' "$RUN_DIR/keepawake.saved"
phone_keep_awake_start SERIAL1
check 'keep-awake start keeps the original value after a failed restore' grep -Fxq 'SERIAL1 2' "$RUN_DIR/keepawake.saved"
phone_keep_awake_stop
check_eq 'keep-awake restores the phone on the next stop after a failed restore' 2 "$(cat "$ADB_STATE_FILE")"
printf 'GONE 5\n' > "$RUN_DIR/keepawake.saved"; phone_keep_awake_start SERIAL1
check 'keep-awake start keeps the value another phone is still waiting to get back' grep -Fxq 'GONE 5' "$RUN_DIR/keepawake.saved"
check 'keep-awake start adds the original value of the new phone' grep -Fxq 'SERIAL1 2' "$RUN_DIR/keepawake.saved"
phone_keep_awake_stop
check_eq 'keep-awake restores the reachable phone while another stays pending' 2 "$(cat "$ADB_STATE_FILE")"
check_eq 'keep-awake keeps only the entry it could not restore' 'GONE 5' "$(cat "$RUN_DIR/keepawake.saved")"
rm -f "$RUN_DIR/keepawake.saved"
printf '2\n' > "$ADB_STATE_FILE"; printf '5\n' > "$ADB_STATE_FILE.2"; phone_keep_awake_start SERIAL1; phone_keep_awake_start SERIAL2
check_eq 'keep-awake saves one original value per phone' 'SERIAL1 2,SERIAL2 5,' "$(sort "$RUN_DIR/keepawake.saved" | tr '\n' ,)"
ADB_DRAIN_STDIN=1 phone_keep_awake_stop
check_eq 'keep-awake restores the first of two phones' 2 "$(cat "$ADB_STATE_FILE")"
check_eq 'keep-awake restores the second of two phones' 5 "$(cat "$ADB_STATE_FILE.2")"
check 'keep-awake clears its saved values once every phone is restored' test ! -e "$RUN_DIR/keepawake.saved"
ka_write=$(declare -f atomic_write_file); atomic_write_file() { return 1; }; phone_keep_awake_start SERIAL1 || :; eval "$ka_write"
check_eq 'keep-awake leaves the phone setting alone when the original value cannot be saved' 2 "$(cat "$ADB_STATE_FILE")"

printf '%s\n' old > "$TMP_DIR/atomic"; printf '%s\n' new | check 'atomic writer replaces complete file' atomic_write_file "$TMP_DIR/atomic" 600; check_eq 'atomic writer content' new "$(cat "$TMP_DIR/atomic")"
printf '%s\n' keep > "$TMP_DIR/atomic"; if atomic_write_file "$TMP_DIR/atomic" badmode <<<new 2>/dev/null; then fail_case 'atomic writer preserves destination on write failure'; else check_eq 'atomic writer preserves destination on write failure' keep "$(cat "$TMP_DIR/atomic")"; fi
printf '%s\n' sudo-new | sudo_atomic_write_file "$TMP_DIR/sudo-atomic" 644; check_eq 'sudo atomic writer content' sudo-new "$(cat "$TMP_DIR/sudo-atomic")"
printf '%s\n' sudo-keep > "$TMP_DIR/sudo-fail"; if printf '%s\n' changed | sudo_atomic_write_file "$TMP_DIR/sudo-fail" badmode >/dev/null 2>&1; then fail_case 'sudo atomic writer preserves destination on mode failure'; else check 'sudo atomic writer preserves destination on mode failure' test "$(cat "$TMP_DIR/sudo-fail")" = sudo-keep; fi
printf '%s\n' sudo-protected > "$TMP_DIR/sudo-link-target"; ln -s "$TMP_DIR/sudo-link-target" "$TMP_DIR/sudo-link"; printf '%s\n' sudo-safe | sudo_atomic_write_file "$TMP_DIR/sudo-link" 644; check 'sudo atomic writer replaces symlink safely' bash -c '[ "$(cat "$1")" = sudo-protected ] && [ "$(cat "$2")" = sudo-safe ] && [ ! -L "$2" ]' _ "$TMP_DIR/sudo-link-target" "$TMP_DIR/sudo-link"
printf '%s\n' protected > "$TMP_DIR/log-target"; ln -s "$TMP_DIR/log-target" "$TMP_DIR/log-link"; prepare_log_file "$TMP_DIR/log-link"; check 'log writer replaces symlink safely' bash -c '[ "$(cat "$1")" = protected ] && [ ! -L "$2" ]' _ "$TMP_DIR/log-target" "$TMP_DIR/log-link"
check_eq 'android API detection' 35 "$(android_api SERIAL1)"
check 'camera API minimum accepts Android 12' require_android_api SERIAL1 31
ADB_API=30; export ADB_API; if require_android_api SERIAL1 31 >/dev/null 2>&1; then fail_case 'camera API rejects Android 11'; else pass_case 'camera API rejects Android 11'; fi; export ADB_API=35
ADB_LOG="$TMP_DIR/adb.log"; export ADB_LOG; check 'screen-off command on modern Android' phone_screen_off SERIAL1; grep -Fq -- 'display-power-off' "$ADB_LOG" && pass_case 'modern screen-off command was issued' || fail_case 'modern screen-off command was issued'
ADB_API=34; export ADB_API; check 'screen-off fallback on Android 14' phone_screen_off SERIAL1; grep -Fq -- 'input keyevent KEYCODE_POWER' "$ADB_LOG" && pass_case 'legacy screen-off fallback was issued' || fail_case 'legacy screen-off fallback was issued'; export ADB_API=35

# apply_phone_settings: screen-off and keep-awake shared by start_webcam and start_mic.
ORIGINAL_SCREEN_OFF=$(declare -f phone_screen_off); saved_screen=$TURN_SCREEN_OFF; saved_awake=$KEEP_AWAKE
: > "$ADB_LOG"; printf '0\n' > "$ADB_STATE_FILE"
TURN_SCREEN_OFF=false KEEP_AWAKE=false
check 'phone settings: both options off returns success' apply_phone_settings SERIAL1
check_eq 'phone settings: both options off leaves the phone alone' '|0' "$(cat "$ADB_LOG")|$(cat "$ADB_STATE_FILE")"
TURN_SCREEN_OFF=true; out=$(apply_phone_settings SERIAL1)
check 'phone settings: screen-off is issued when enabled' grep -Fq -- 'display-power-off' "$ADB_LOG"
check_eq 'phone settings: a successful screen-off prints no warning' '' "$out"
phone_screen_off() { return 1; }; out=$(apply_phone_settings SERIAL1)
check 'phone settings: a failed screen-off only warns' grep -Fq -- "$(t PHONE_SCREEN_OFF_FAIL)" <<<"$out"
phone_screen_off() { return 2; }; out=$(apply_phone_settings SERIAL1)
check 'phone settings: an unrecognised screen state warns about support' grep -Fq -- "$(t PHONE_SCREEN_OFF_UNSUPPORTED)" <<<"$out"
check 'phone settings: an unrecognised screen state is not reported as a failure' bash -c '! grep -Fq -- "$1" <<<"$2"' _ "$(t PHONE_SCREEN_OFF_FAIL)" "$out"
eval "$ORIGINAL_SCREEN_OFF"
TURN_SCREEN_OFF=false KEEP_AWAKE=true
check 'phone settings: keep-awake enabled returns success' apply_phone_settings SERIAL1
check_eq 'phone settings: keep-awake is applied when enabled' 7 "$(cat "$ADB_STATE_FILE")"
phone_keep_awake_stop; TURN_SCREEN_OFF=$saved_screen KEEP_AWAKE=$saved_awake

printf '%s\n' profile > "$TMP_DIR/profile"; chmod 640 "$TMP_DIR/profile"; printf '%s\n' added | atomic_append_file "$TMP_DIR/profile"; check 'atomic append keeps content' bash -c '[ "$(sed -n 1p "$1")" = profile ] && [ "$(sed -n 2p "$1")" = added ]' _ "$TMP_DIR/profile"; check 'atomic append keeps mode' bash -c '[ "$(stat -c %a "$1")" = 640 ]' _ "$TMP_DIR/profile"
printf '%s\n' protected-profile > "$TMP_DIR/profile-target"; ln -s "$TMP_DIR/profile-target" "$TMP_DIR/profile-link"; printf '%s\n' safe | atomic_append_file "$TMP_DIR/profile-link"; check 'atomic append replaces symlink safely' bash -c '[ "$(cat "$1")" = protected-profile ] && [ "$(sed -n 1p "$2")" = protected-profile ] && [ "$(sed -n 2p "$2")" = safe ] && [ ! -L "$2" ]' _ "$TMP_DIR/profile-target" "$TMP_DIR/profile-link"
printf '%s\n' target > "$TMP_DIR/mode-target"; chmod 666 "$TMP_DIR/mode-target"; check_eq 'existing_file_mode strips the other-write bit' 664 "$(existing_file_mode "$TMP_DIR/mode-target" 644)"
chmod 600 "$TMP_DIR/mode-target"; ln -sf "$TMP_DIR/mode-target" "$TMP_DIR/mode-link"; check_eq 'existing_file_mode follows -L to the target mode, not the symlink itself' 600 "$(existing_file_mode "$TMP_DIR/mode-link" 644)"
check_eq 'existing_file_mode falls back to the given default for a missing path' 755 "$(existing_file_mode "$TMP_DIR/mode-missing" 755)"

pid=$$; start=$(proc_start_time "$pid"); printf '%s %s\n' "$pid" "$start" > "$TMP_DIR/pid"; check 'pidfile matches current process' pidfile_matches_process "$TMP_DIR/pid" bash
check 'wait helper accepts current process' wait_for_process "$TMP_DIR/pid" bash 2
# /proc/PID/stat holds the process name in field 2: spaces or ")" in it must not shift the start-time field.
odd_name_times=$( ( me=$BASHPID; before=$(proc_start_time "$me"); printf '%s' 'odd name) 1 2 3' > /proc/self/comm; printf '%s|%s|%s' "$before" "$(proc_start_time "$me")" "$(< /proc/$me/comm)" ) )
check_eq 'the renamed process really carries the awkward name' 'odd name) 1 2 3' "${odd_name_times##*|}"
check_eq 'start time survives a process name with spaces and parentheses' "${odd_name_times%%|*}" "$(cut -d'|' -f2 <<<"$odd_name_times")"
check_eq 'start time of a vanished process is reported silently' '' "$(proc_start_time 4194999 2>&1)"
if proc_start_time 4194999 >/dev/null 2>&1; then fail_case 'start time of a vanished process fails'; else pass_case 'start time of a vanished process fails'; fi
printf '%s\n' protected > "$TMP_DIR/pid-target"; ln -s "$TMP_DIR/pid-target" "$TMP_DIR/pid-link"; write_pidfile "$TMP_DIR/pid-link" "$pid"; if [ "$(cat "$TMP_DIR/pid-target")" = protected ] && [ ! -L "$TMP_DIR/pid-link" ] && [ "$(pidfile_pid "$TMP_DIR/pid-link")" = "$pid" ]; then pass_case 'pidfile replaces symlink without touching target'; else fail_case 'pidfile replaces symlink without touching target'; fi
printf '%s\n' keep > "$TMP_DIR/atomic-dir-target"; mkdir "$TMP_DIR/atomic-dir"; if printf '%s\n' blocked | atomic_write_file "$TMP_DIR/atomic-dir" 600 2>/dev/null; then fail_case 'atomic writer rejects directory destination'; else pass_case 'atomic writer rejects directory destination'; fi; check 'atomic writer leaves directory intact' test -d "$TMP_DIR/atomic-dir"
printf '%s\n' "CAMERA_FACING='back'" > "$CONF_FILE"; set_config CAMERA_FACING 'C:\\camera\\test'; source "$CONF_FILE"; check 'config preserves backslashes' test "$CAMERA_FACING" = 'C:\\camera\\test'
set_config CAMERA_FACING 'back'; printf '%s\n' "CAMERA_FACING='old # literal'" > "$CONF_FILE"; set_config CAMERA_FACING 'new'; check 'config does not mistake hash inside value for comment' grep -Fxq "CAMERA_FACING='new'" "$CONF_FILE"
printf '%s\n' "CAMERA_FACING='old'  # keep this comment" > "$CONF_FILE"; set_config CAMERA_FACING 'new'; check 'config preserves real inline comment' grep -Fx "CAMERA_FACING='new'  # keep this comment" "$CONF_FILE"
printf '%s\n' 'CAMERA_FACING="back"  # keep double-quoted comment' > "$CONF_FILE"; set_config CAMERA_FACING 'new'; check 'config preserves double-quoted inline comment' grep -Fx "CAMERA_FACING='new'  # keep double-quoted comment" "$CONF_FILE"
set_config CAMERA_FACING "O'Brien"; source "$CONF_FILE"; check 'config preserves single quote in value' test "$CAMERA_FACING" = "O'Brien"
printf '%s\n' "CAMERA_FACING='one'" "CAMERA_FACING='two'" > "$CONF_FILE"; set_config CAMERA_FACING 'new'; check 'config updates duplicate keys consistently' test "$(grep -c '^CAMERA_FACING=' "$CONF_FILE")" -eq 2 && ! grep -Fq "CAMERA_FACING='one'" "$CONF_FILE" && ! grep -Fq "CAMERA_FACING='two'" "$CONF_FILE"
chmod 640 "$CONF_FILE"; set_config CAMERA_FPS '60'; check 'config preserves existing mode' bash -c '[ "$(stat -c %a "$1")" = 640 ]' _ "$CONF_FILE"
printf '%s\n' protected-config > "$TMP_DIR/config-target"; ln -sf "$TMP_DIR/config-target" "$CONF_FILE"; set_config CAMERA_FPS '45'; check 'config replaces destination symlink safely' test ! -L "$CONF_FILE" && test "$(cat "$TMP_DIR/config-target")" = protected-config && grep -Fq "CAMERA_FPS='45'" "$CONF_FILE"
rm -f "$CONF_FILE"; mkdir "$CONF_FILE"; if set_config CAMERA_FPS '50' >/dev/null 2>&1; then fail_case 'config rejects directory destination'; else pass_case 'config rejects directory destination'; fi; check 'config directory destination remains intact' test -d "$CONF_FILE"; rm -rf "$CONF_FILE"
if set_config CAMERA_FPS $'30\n40'; then fail_case 'config rejects multiline values'; else pass_case 'config rejects multiline values'; fi
# A first write must start from the commented template (a bare file would make `install` skip it), in the language being set.
rm -f "$CONF_FILE"; set_config CAMERA_FACING front
check 'first config write starts from the commented template' grep -Fq '#  PhoneCam - configuration' "$CONF_FILE"
check 'first config write applies the value and keeps the template hint' grep -Fx "CAMERA_FACING='front'        # back | front | external" "$CONF_FILE"
check_eq 'first config write is private' 600 "$(stat -c %a "$CONF_FILE")"
check_eq 'first config write leaves one entry per key' 1 "$(grep -c '^CAMERA_FACING=' "$CONF_FILE")"
rm -f "$CONF_FILE"; set_config PHONECAM_LANG es
check 'first language write seeds the template in the chosen language' grep -Fq '#  PhoneCam - configuración' "$CONF_FILE"
check 'first language write stores the chosen language' grep -Fx "PHONECAM_LANG='es'" "$CONF_FILE"
check_eq 'first language write leaves one language entry' 1 "$(grep -c '^PHONECAM_LANG=' "$CONF_FILE")"
check_eq 'first language write leaves this shell in its language' en "$CURRENT_LANG"
rm -f "$CONF_FILE"; CURRENT_LANG=es; set_config PHONECAM_LANG en; CURRENT_LANG=en
check 'first language write seeds the English template when English is chosen' bash -c '! grep -Fq "configuración" "$1" && grep -Fq "#  PhoneCam - configuration" "$1"' _ "$CONF_FILE"
rm -f "$CONF_FILE"; CURRENT_LANG=es; PHONECAM_LANG_ENV=es; set_config PHONECAM_LANG en; PHONECAM_LANG_ENV=""; CURRENT_LANG=en
check 'first language write seeds the chosen language even when the environment forces another' bash -c '! grep -Fq "configuración" "$1" && grep -Fq "#  PhoneCam - configuration" "$1"' _ "$CONF_FILE"
rm -f "$CONF_FILE"; PHONECAM_LANG=auto
check 'system language helper is executable' detect_system_language
check 'phone status helper reports connected' test "$(phone_status_short)" = connected
PATH_SAVE_CLI="$PATH"; PATH=/usr/bin:/bin; if cli_menu </dev/null >/dev/null 2>&1; then fail_case 'cli menu rejects non-tty'; else pass_case 'cli menu rejects non-tty'; fi; PATH="$PATH_SAVE_CLI"; hash -r
printf '%s %s\n' "$pid" 0 > "$TMP_DIR/pid"; if pidfile_matches_process "$TMP_DIR/pid" bash; then fail_case 'stale starttime rejected'; else pass_case 'stale starttime rejected'; fi
printf '%s\n' "$pid" > "$TMP_DIR/legacy-pid"; if pidfile_matches_process "$TMP_DIR/legacy-pid" bash; then fail_case 'legacy pidfile without starttime rejected'; else pass_case 'legacy pidfile without starttime rejected'; fi
/bin/sleep 30 & other=$!; os=$(proc_start_time "$other"); printf '%s %s\n' "$other" "$os" > "$TMP_DIR/other.pid"; if pidfile_matches_process "$TMP_DIR/other.pid" scrcpy; then fail_case 'wrong process name rejected'; else pass_case 'wrong process name rejected'; fi; kill "$other" 2>/dev/null || true; wait "$other" 2>/dev/null || true
/bin/sleep 30 & term_pid=$!; check 'terminate_pid stops process' terminate_pid "$term_pid" 0; check 'terminated process is gone' test ! -e "/proc/$term_pid/stat"

check 'audio devices created' ensure_audio_devices
check 'audio creation idempotent' ensure_audio_devices
check 'v4l2 present and writable' ensure_v4l2_device
# lsmod prints the module first and keeps writing past the pipe buffer: a grep -q reader quits at that line and, under pipefail, the SIGPIPE reads as "not loaded".
cat > "$TMP_DIR/bin/lsmod" <<'EOF_LSMOD'
#!/bin/sh
printf 'Module                  Size  Used by\nv4l2loopback           40960  0\n'
head -c 300000 /dev/zero | tr '\0' x; echo
EOF_LSMOD
chmod +x "$TMP_DIR/bin/lsmod"; hash -r
check 'v4l2loopback is detected although lsmod keeps writing after its line' v4l2loopback_loaded
printf '#!/bin/sh\nprintf "Module Size Used by\\nv4l2loopback_dc 4096 0\\nsnd 1 0\\n"\n' > "$TMP_DIR/bin/lsmod"
if v4l2loopback_loaded; then fail_case 'a module that only starts with v4l2loopback is not v4l2loopback'; else pass_case 'a module that only starts with v4l2loopback is not v4l2loopback'; fi
printf '#!/bin/sh\nprintf "Module Size Used by\\nsnd 1 0\\n"\n' > "$TMP_DIR/bin/lsmod"
if v4l2loopback_loaded; then fail_case 'v4l2loopback is not reported when lsmod lacks it'; else pass_case 'v4l2loopback is not reported when lsmod lacks it'; fi
rm -f "$TMP_DIR/bin/lsmod"; hash -r

# v4l2_node_exists is the hook tests override: the default must accept any node type (real /dev/video* are character devices).
mkfifo "$TMP_DIR/node fifo"
check 'v4l2_node_exists accepts a node that is not a regular file' v4l2_node_exists "$TMP_DIR/node fifo"
if v4l2_node_exists "$TMP_DIR/no-such-node"; then fail_case 'v4l2_node_exists rejects a missing node'; else pass_case 'v4l2_node_exists rejects a missing node'; fi
rm -f "$TMP_DIR/node fifo"

# GUI forms must parse stable machine values regardless of translated labels.
export ZENITY_CHOICE=2
CAMERA_ID=''; choose_camera_gui >/dev/null 2>&1
check_eq 'camera chooser stores selected id' 2 "$CAMERA_ID"
CURRENT_LANG=en
advanced_settings_gui >/dev/null 2>&1
form_signature="$CAMERA_FACING|$CAMERA_SIZE|$CAMERA_FPS|$VIDEO_QUALITY_PROFILE|$AUDIO_SOURCE|$AUDIO_CODEC|$AUDIO_BITRATE|$AUTO_MODE|$TURN_SCREEN_OFF|$KEEP_AWAKE"
check_eq 'advanced form preserves all machine values' 'back|1920x1080|30|balanced|mic|opus|192K|ask|false|true' "$form_signature"
CURRENT_LANG=es
advanced_settings_gui >/dev/null 2>&1
form_signature_es="$CAMERA_FACING|$CAMERA_SIZE|$CAMERA_FPS|$VIDEO_QUALITY_PROFILE|$AUDIO_SOURCE|$AUDIO_CODEC|$AUDIO_BITRATE|$AUTO_MODE|$TURN_SCREEN_OFF|$KEEP_AWAKE"
check_eq 'advanced form is language-invariant' "$form_signature" "$form_signature_es"

# The extra microphone sources exist only in scrcpy 3.2+; older versions reject them.
EXTRA_SOURCES='--combo-values=mic|mic-unprocessed|mic-voice-communication|mic-voice-recognition|mic-camcorder'
: > "$ZENITY_LOG"; SCRCPY_VERSION=3.1 advanced_settings_gui >/dev/null 2>&1
if grep -Fq -- 'mic-unprocessed' "$ZENITY_LOG"; then fail_case 'advanced form hides the extra audio sources before scrcpy 3.2'; else pass_case 'advanced form hides the extra audio sources before scrcpy 3.2'; fi
: > "$ZENITY_LOG"; SCRCPY_VERSION=3.2 advanced_settings_gui >/dev/null 2>&1
check 'advanced form offers the extra audio sources from scrcpy 3.2' grep -Fq -- "$EXTRA_SOURCES" "$ZENITY_LOG"
# A stored source that scrcpy cannot run is never replaced behind the user's back: it stays the first (default) entry and mic is an explicit choice.
AUDIO_SOURCE=mic-camcorder; : > "$ZENITY_LOG"; ZENITY_FORM=defaults SCRCPY_VERSION=3.1 advanced_settings_gui >/dev/null 2>&1
check 'advanced form lists a stored source scrcpy 3.1 cannot run first, then mic' grep -Fq -- '--combo-values=mic-camcorder|mic --add-combo=' "$ZENITY_LOG"
if grep -Fq -- 'mic-unprocessed' "$ZENITY_LOG"; then fail_case 'advanced form offers no new source scrcpy 3.1 cannot run'; else pass_case 'advanced form offers no new source scrcpy 3.1 cannot run'; fi
check_eq 'accepting the form keeps a stored source scrcpy 3.1 cannot run' mic-camcorder "$AUDIO_SOURCE"
check 'accepting the form leaves that source in the config file' grep -Fq "AUDIO_SOURCE='mic-camcorder'" "$CONF_FILE"
SCRCPY_VERSION=3.1 advanced_settings_gui >/dev/null 2>&1
check_eq 'choosing mic in the form replaces that source' mic "$AUDIO_SOURCE"
AUDIO_SOURCE=mic-camcorder; : > "$ZENITY_LOG"; SCRCPY_VERSION=3.2 advanced_settings_gui >/dev/null 2>&1
check 'advanced form keeps a stored extra audio source first on scrcpy 3.2' grep -Fq -- '--combo-values=mic-camcorder|mic|mic-unprocessed|mic-voice-communication|mic-voice-recognition' "$ZENITY_LOG"
AUDIO_SOURCE=mic

# Override pactl for route success after the process starts.
cat > "$TMP_DIR/bin/pactl_route" <<'EOF'
#!/bin/sh
case "${1:-}" in
  list) printf 'Sink Input #44\n application.process.binary = "scrcpy"\n';;
  move-sink-input) exit 0;;
  *) printf '1\tPhoneMicSink\n';;
esac
EOF
chmod +x "$TMP_DIR/bin/pactl_route"
mv "$TMP_DIR/bin/pactl_route" "$TMP_DIR/bin/pactl_ok"
# Build mic with a specialized pactl stub for source/sink and routing.
cat > "$TMP_DIR/bin/pactl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PACTL_LOG"
case "${1:-}" in
  list)
    if [ "${2:-}" = short ]; then
      case "${3:-}" in sinks) printf '1\tPhoneMicSink\n';; sources) printf '2\tPhoneMic\n';; modules) :;; esac
    else
      printf 'Sink Input #44\n application.process.binary = "scrcpy"\n'
    fi
    ;;
  load-module|move-sink-input|unload-module) exit 0;;
esac
EOF
chmod +x "$TMP_DIR/bin/pactl"
# Remaining helpers and long-running paths.
PID_ONLY="$TMP_DIR/pid-only"; printf '%s %s\n' "$BASHPID" "$(proc_start_time "$BASHPID")" > "$PID_ONLY"; check_eq 'pidfile_pid returns pid' "$BASHPID" "$(pidfile_pid "$PID_ONLY")"
if use_color; then fail_case 'stdout is non-colour in non-TTY'; else pass_case 'stdout is non-colour in non-TTY'; fi
if use_color_err; then fail_case 'stderr is non-colour in non-TTY'; else pass_case 'stderr is non-colour in non-TTY'; fi
# Colour mode must print the text literally: a backslash in a log line or path is not an escape sequence.
use_color() { :; }; use_color_err() { :; }
color_text='C:\temp\new 100%\n'; color_esc=$'\e'
check_eq 'info keeps backslashes in colour mode' "${color_esc}[34mℹ${color_esc}[0m $color_text" "$(info "$color_text")"
check_eq 'ok keeps backslashes in colour mode' "${color_esc}[32m✓${color_esc}[0m $color_text" "$(ok "$color_text")"
check_eq 'warn keeps backslashes in colour mode' "${color_esc}[33m⚠${color_esc}[0m $color_text" "$(warn "$color_text")"
check_eq 'err keeps backslashes in colour mode' "${color_esc}[31m✗${color_esc}[0m $color_text" "$(err "$color_text" 2>&1)"
check_eq 'hdr keeps backslashes in colour mode' "${color_esc}[1m${color_text}${color_esc}[0m" "$(hdr "$color_text")"
unset -f use_color use_color_err
NONINTERACTIVE=1; check 'ask_yn noninteractive yes' ask_yn 'x' y; if ask_yn 'x' n; then fail_case 'ask_yn noninteractive no'; else pass_case 'ask_yn noninteractive no'; fi
CURRENT_LANG=en
mv() { return 1; }
if toggle_language >/dev/null 2>&1; then fail_case 'language toggle propagates write failure'; else pass_case 'language toggle propagates write failure'; fi
check 'language toggle keeps current language on write failure' test "$CURRENT_LANG" = en
unset -f mv

# fetch_to_stdout / fetch_to_file: curl and wget are tested independently.
NET_BIN="$TMP_DIR/netbin"; mkdir -p "$NET_BIN"
cat > "$NET_BIN/curl" <<'EOF'
#!/bin/sh
out=''
for arg in "$@"; do
  if [ "${take_out:-0}" -eq 1 ]; then out="$arg"; take_out=0; continue; fi
  [ "$arg" = '-o' ] && take_out=1
done
if [ -n "$out" ]; then printf 'CURLEXAMPLE\n' > "$out"; else printf 'CURLEXAMPLE\n'; fi
EOF
cat > "$NET_BIN/wget" <<'EOF'
#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in -O) shift; out="$1";; -qO-|-qO) :;; esac
  shift
done
if [ -n "$out" ]; then printf 'WGETEXAMPLE\n' > "$out"; else printf 'WGETEXAMPLE\n'; fi
EOF
chmod +x "$NET_BIN/curl" "$NET_BIN/wget"
old_path="$PATH"; export PATH="$NET_BIN"
hash -r
check 'fetch stdout with curl' test "$(fetch_to_stdout example)" = CURLEXAMPLE
/bin/mkdir -p "$TMP_DIR/fetch"; check 'fetch file with curl' fetch_to_file example "$TMP_DIR/fetch/curl"; check 'curl file content' test "$(/bin/cat "$TMP_DIR/fetch/curl")" = CURLEXAMPLE
/bin/mv "$NET_BIN/curl" "$NET_BIN/curl.off"; hash -r; check 'fetch stdout with wget' test "$(fetch_to_stdout example)" = WGETEXAMPLE
/bin/mv "$NET_BIN/curl.off" "$NET_BIN/curl"; hash -r
export PATH="$old_path"; hash -r
# No downloader: use an isolated PATH with only sudo/apt for ensure_downloader.
ISO_BIN="$TMP_DIR/iso"; mkdir -p "$ISO_BIN"
printf '#!/bin/sh\nexit 0\n' > "$ISO_BIN/sudo"; printf '#!/bin/sh\nexit 0\n' > "$ISO_BIN/apt"; chmod +x "$ISO_BIN/sudo" "$ISO_BIN/apt"
old_path2="$PATH"; export PATH="$ISO_BIN"; hash -r; NONINTERACTIVE=1; check 'ensure_downloader installs missing downloader' ensure_downloader; export PATH="$old_path2"; hash -r

# run_with_zenity_progress returns the wrapped command status.
check 'zenity progress success' run_with_zenity_progress progress true
if run_with_zenity_progress progress false; then fail_case 'zenity progress propagates failure'; else pass_case 'zenity progress propagates failure'; fi

# Exercise automatic scrcpy download/extract/install with a local fake release.
FAKE_RELEASE_DIR="$TMP_DIR/release-src/scrcpy-linux-x86_64-v3.0"; mkdir -p "$FAKE_RELEASE_DIR"; printf '#!/bin/sh\nprintf "scrcpy 3.0\\n"\n' > "$FAKE_RELEASE_DIR/scrcpy"; chmod +x "$FAKE_RELEASE_DIR/scrcpy"
FAKE_ARCHIVE="$TMP_DIR/scrcpy-linux-x86_64-v3.0.tar.gz"; export FAKE_ARCHIVE
/bin/tar -czf "$FAKE_ARCHIVE" -C "$TMP_DIR/release-src" "scrcpy-linux-x86_64-v3.0"
check 'scrcpy archive validator accepts regular archive' validate_scrcpy_archive "$FAKE_ARCHIVE"
printf 'not a gzip archive\n' > "$TMP_DIR/corrupt.tar.gz"
if validate_scrcpy_archive "$TMP_DIR/corrupt.tar.gz" >/dev/null 2>&1; then fail_case 'corrupt scrcpy archive is rejected'; else pass_case 'corrupt scrcpy archive is rejected'; fi
cat > "$NET_BIN/curl" <<'EOF'
#!/bin/sh
out=''; last=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift; out="$1";; *) last="$1";; esac
  shift
done
case "$last" in
  */releases/latest) printf '%s\n' 'https://github.com/Genymobile/scrcpy/releases/tag/v3.0';;
  *SHA256SUMS.txt) if [ "${BAD_CHECKSUM:-0}" = 1 ]; then printf '%064d  scrcpy-linux-x86_64-v3.0.tar.gz\n' 0; else printf '%s  scrcpy-linux-x86_64-v3.0.tar.gz\n' "$(sha256sum "$FAKE_ARCHIVE" | awk '{print $1}')"; fi;;
  *) /bin/cp "$FAKE_ARCHIVE" "$out";;
esac
EOF
chmod +x "$NET_BIN/curl"
export PATH="$NET_BIN:$old_path2"; hash -r; check_eq 'latest_scrcpy_tag resolves the tag via the curl redirect' v3.0 "$(latest_scrcpy_tag)"
SCRCPY_DIR="$TMP_DIR/release-dst"; BIN_DIR="$TMP_DIR/release-bin"; export BIN_DIR; mkdir -p "$SCRCPY_DIR" "$BIN_DIR"; printf '%s\n' stale > "$SCRCPY_DIR/stale.marker"; printf '%s\n' protected > "$TMP_DIR/scrcpy-protected"; ln -s "$TMP_DIR/scrcpy-protected" "$BIN_DIR/scrcpy"; export PATH="$NET_BIN:$old_path2"; check 'automatic scrcpy release install' download_scrcpy_release; check 'downloaded scrcpy exists' test -x "$SCRCPY_DIR/scrcpy"; check 'stale scrcpy content replaced' test ! -e "$SCRCPY_DIR/stale.marker"; check 'downloaded scrcpy symlinked' test -L "$BIN_DIR/scrcpy"; check 'pre-existing symlink target preserved' test "$(cat "$TMP_DIR/scrcpy-protected")" = protected; printf '%s\n' keep > "$SCRCPY_DIR/keep.marker"; cat > "$NET_BIN/cp" <<'EOF'
#!/bin/sh
exit 77
EOF
chmod +x "$NET_BIN/cp"; hash -r; if download_scrcpy_release >/dev/null 2>&1; then fail_case 'scrcpy preparation failure propagates'; else pass_case 'scrcpy preparation failure propagates'; fi; check 'failed scrcpy preparation preserves binary' test -x "$SCRCPY_DIR/scrcpy"; check 'failed scrcpy preparation preserves data' test "$(cat "$SCRCPY_DIR/keep.marker")" = keep; rm -f "$NET_BIN/cp"
cat > "$NET_BIN/mv" <<'EOF'
#!/bin/sh
dest=""
for arg do dest="$arg"; done
[ "$dest" = "$BIN_DIR/scrcpy" ] && exit 77
exec /bin/mv "$@"
EOF
chmod +x "$NET_BIN/mv"; hash -r; if download_scrcpy_release >/dev/null 2>&1; then fail_case 'scrcpy link replacement failure propagates'; else pass_case 'scrcpy link replacement failure propagates'; fi; check 'scrcpy rollback restores previous data' test -f "$SCRCPY_DIR/keep.marker" && test "$(cat "$SCRCPY_DIR/keep.marker")" = keep; check 'scrcpy rollback preserves previous binary' test -x "$SCRCPY_DIR/scrcpy"; check 'scrcpy rollback preserves previous symlink' test -L "$BIN_DIR/scrcpy" && test "$(readlink "$BIN_DIR/scrcpy")" = "$SCRCPY_DIR/scrcpy"; rm -f "$NET_BIN/mv"; export PATH="$old_path2"; hash -r
export PATH="$NET_BIN:$old_path2"; hash -r
BAD_CHECKSUM=1; export BAD_CHECKSUM FAKE_ARCHIVE; if download_scrcpy_release >/dev/null 2>&1; then fail_case 'scrcpy checksum mismatch is rejected'; else pass_case 'scrcpy checksum mismatch is rejected'; fi; check 'checksum failure preserves installed data' test "$(cat "$SCRCPY_DIR/keep.marker")" = keep; unset BAD_CHECKSUM
MAL_SRC="$TMP_DIR/malicious-src/release"; mkdir -p "$MAL_SRC"; printf '%s\n' protected > "$TMP_DIR/outside-target"; ln -s "$TMP_DIR/outside-target" "$MAL_SRC/payload"; MAL_ARCHIVE="$TMP_DIR/malicious.tar.gz"; /bin/tar -czf "$MAL_ARCHIVE" -C "$TMP_DIR/malicious-src" release; FAKE_ARCHIVE="$MAL_ARCHIVE"; export FAKE_ARCHIVE; if download_scrcpy_release >/dev/null 2>&1; then fail_case 'unsafe scrcpy archive is rejected'; else pass_case 'unsafe scrcpy archive is rejected'; fi; check 'unsafe archive cannot modify outside path' test "$(cat "$TMP_DIR/outside-target")" = protected; check 'unsafe archive preserves installed data' test "$(cat "$SCRCPY_DIR/keep.marker")" = keep
export PATH="$old_path2"; hash -r
# SHA256SUMS lookup: exact file name, optional binary-mode "*", strictly 64 hex digits, first match only.
SUMS_TEXT=$(printf '%s\n' "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1  scrcpy-linux-x86_64-v3.0.tar.gz.sig" "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 *scrcpy-linux-x86_64-v3.0.tar.gz" "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3  scrcpy-linux-x86_64-v3.0.tar.gz" "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d  short-hash.tar.gz" "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e  long-hash.tar.gz" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz  non-hex.tar.gz")
check_eq 'checksum_for_file skips the .sig line and honours the binary marker' "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2" "$(checksum_for_file scrcpy-linux-x86_64-v3.0.tar.gz <<<"$SUMS_TEXT")"
check_eq 'checksum_for_file ignores a hash shorter than 64 digits' '' "$(checksum_for_file short-hash.tar.gz <<<"$SUMS_TEXT")"
check_eq 'checksum_for_file ignores a hash longer than 64 digits' '' "$(checksum_for_file long-hash.tar.gz <<<"$SUMS_TEXT")"
check_eq 'checksum_for_file ignores a 64-character non-hex hash' '' "$(checksum_for_file non-hex.tar.gz <<<"$SUMS_TEXT")"
check_eq 'checksum_for_file returns nothing for an unlisted file' '' "$(checksum_for_file absent.tar.gz <<<"$SUMS_TEXT")"
WGET_ONLY_BIN="$TMP_DIR/wgetonly"; mkdir -p "$WGET_ONLY_BIN"; ln -s "$(command -v awk)" "$WGET_ONLY_BIN/awk"
cat > "$WGET_ONLY_BIN/wget" <<'EOF'
#!/bin/sh
echo 'Location: https://github.com/Genymobile/scrcpy/releases/tag/v4.1 [following]' >&2
EOF
chmod +x "$WGET_ONLY_BIN/wget"; check_eq 'latest_scrcpy_tag resolves the tag via wget when curl is absent' v4.1 "$(PATH="$WGET_ONLY_BIN" latest_scrcpy_tag)"
cat > "$WGET_ONLY_BIN/wget" <<'EOF'
#!/bin/sh
echo 'Location: https://github.com/Genymobile/scrcpy/releases/tag/not-a-version [following]' >&2
EOF
chmod +x "$WGET_ONLY_BIN/wget"; if PATH="$WGET_ONLY_BIN" latest_scrcpy_tag >/dev/null 2>&1; then fail_case 'latest_scrcpy_tag rejects a malformed resolved tag'; else pass_case 'latest_scrcpy_tag rejects a malformed resolved tag'; fi
rm -rf "$BIN_DIR/scrcpy"; mkdir "$BIN_DIR/scrcpy"; printf '%s\n' protected-dir > "$BIN_DIR/scrcpy/marker"; FAKE_ARCHIVE="$TMP_DIR/scrcpy-linux-x86_64-v3.0.tar.gz"; export FAKE_ARCHIVE; if download_scrcpy_release >/dev/null 2>&1; then fail_case 'scrcpy directory destination is rejected'; else pass_case 'scrcpy directory destination is rejected'; fi; check 'scrcpy directory destination keeps directory intact' test -d "$BIN_DIR/scrcpy" && test "$(cat "$BIN_DIR/scrcpy/marker")" = protected-dir; rm -rf "$BIN_DIR/scrcpy"; ln -s "$SCRCPY_DIR/scrcpy" "$BIN_DIR/scrcpy"
export PATH="$BIN_DIR:$old_path2"; hash -r; check 'installed scrcpy is reused without download' ensure_scrcpy_installed; export PATH="$old_path2"; hash -r
# install_scrcpy_tree and fetch_scrcpy_tree directly: clean installs, clean failures, verified downloads.
IT_DST="$TMP_DIR/tree-dst"; IT_SAVE_DIR="$SCRCPY_DIR"; IT_SAVE_BIN="$BIN_DIR"; SCRCPY_DIR="$IT_DST/data/scrcpy"; BIN_DIR="$IT_DST/bin"
it_leftovers() { find "$IT_DST" -name '.scrcpy-*' | head -1; }
check 'install_scrcpy_tree installs into a fresh location' install_scrcpy_tree "$FAKE_RELEASE_DIR"
check 'install_scrcpy_tree installs the executable' test -x "$SCRCPY_DIR/scrcpy"
check_eq 'install_scrcpy_tree links the binary directory to the install' "$SCRCPY_DIR/scrcpy" "$(readlink "$BIN_DIR/scrcpy")"
check_eq 'install_scrcpy_tree leaves no staging directories behind' '' "$(it_leftovers)"
check 'install_scrcpy_tree releases the install lock' flock -n "$IT_DST/data/.install.lock" true
mkdir -p "$TMP_DIR/tree-empty"
if install_scrcpy_tree "$TMP_DIR/tree-empty" 2>/dev/null; then fail_case 'install_scrcpy_tree rejects a tree without the scrcpy binary'; else pass_case 'install_scrcpy_tree rejects a tree without the scrcpy binary'; fi
check 'a rejected install_scrcpy_tree keeps the previous install' test -x "$SCRCPY_DIR/scrcpy"
check_eq 'a rejected install_scrcpy_tree leaves no staging directories behind' '' "$(it_leftovers)"
check 'a rejected install_scrcpy_tree releases the install lock' flock -n "$IT_DST/data/.install.lock" true
SCRCPY_DIR="$IT_SAVE_DIR"; BIN_DIR="$IT_SAVE_BIN"; unset -f it_leftovers
FT_URL='https://github.com/Genymobile/scrcpy/releases/download/v3.0/scrcpy-linux-x86_64-v3.0.tar.gz'; FT_DIR="$TMP_DIR/fetch-tree"
FAKE_ARCHIVE="$TMP_DIR/scrcpy-linux-x86_64-v3.0.tar.gz"; export FAKE_ARCHIVE; export PATH="$NET_BIN:$old_path2"; hash -r
mkdir -p "$FT_DIR"; check 'fetch_scrcpy_tree unpacks a verified release' fetch_scrcpy_tree "$FT_URL" "$FT_DIR"
check 'fetch_scrcpy_tree extracts the release directory' test -x "$FT_DIR/scrcpy-linux-x86_64-v3.0/scrcpy"
rm -rf "$FT_DIR"; mkdir -p "$FT_DIR"; BAD_CHECKSUM=1; export BAD_CHECKSUM
if fetch_scrcpy_tree "$FT_URL" "$FT_DIR" >/dev/null 2>&1; then fail_case 'fetch_scrcpy_tree rejects a checksum mismatch'; else pass_case 'fetch_scrcpy_tree rejects a checksum mismatch'; fi
check_eq 'fetch_scrcpy_tree unpacks nothing after a checksum mismatch' 1 "$(find "$FT_DIR" -mindepth 1 | wc -l)"
unset BAD_CHECKSUM; export PATH="$old_path2"; hash -r
python3 - "$TMP_DIR/path-traversal.tar.gz" "$TMP_DIR/multi-root.tar.gz" "$TMP_DIR/odd-control.tar.gz" "$TMP_DIR/odd-backslash.tar.gz" <<'PY'
import io, tarfile, sys
traversal, multi, odd_control, odd_backslash = sys.argv[1:]
with tarfile.open(traversal, 'w:gz') as tf:
    data = b'x'
    info = tarfile.TarInfo('../escape')
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
with tarfile.open(multi, 'w:gz') as tf:
    for name in ('one/scrcpy', 'two/extra'):
        data = b'x'
        info = tarfile.TarInfo(name)
        info.mode = 0o755
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))
for path, odd in ((odd_control, 'one/odd\tname'), (odd_backslash, 'one/odd\\name')):
    with tarfile.open(path, 'w:gz') as tf:
        for name in ('one/scrcpy', odd):
            data = b'x'
            info = tarfile.TarInfo(name)
            info.mode = 0o755
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
PY
if validate_scrcpy_archive "$TMP_DIR/path-traversal.tar.gz" >/dev/null 2>&1; then fail_case 'tar path traversal is rejected'; else pass_case 'tar path traversal is rejected'; fi
if validate_scrcpy_archive "$TMP_DIR/multi-root.tar.gz" >/dev/null 2>&1; then fail_case 'multi-root scrcpy archive is rejected'; else pass_case 'multi-root scrcpy archive is rejected'; fi
if validate_scrcpy_archive "$TMP_DIR/odd-control.tar.gz" >/dev/null 2>&1; then fail_case 'scrcpy archive with a control character in a name is rejected'; else pass_case 'scrcpy archive with a control character in a name is rejected'; fi
if validate_scrcpy_archive "$TMP_DIR/odd-backslash.tar.gz" >/dev/null 2>&1; then fail_case 'scrcpy archive with a backslash in a name is rejected'; else pass_case 'scrcpy archive with a backslash in a name is rejected'; fi
FAKE_ARCHIVE="$TMP_DIR/scrcpy-linux-x86_64-v3.0.tar.gz"; export FAKE_ARCHIVE;

# Startup failures must not orphan capture processes.
SCRCPY_BUSY=1
ORIGINAL_WRITE_PIDFILE=$(declare -f write_pidfile)
ORIGINAL_ATOMIC_WRITE=$(declare -f atomic_write_file)
atomic_write_file() { return 1; }
if start_webcam >/dev/null 2>&1; then fail_case 'webcam aborts on pidfile write failure'; else pass_case 'webcam aborts on pidfile write failure'; fi
if pgrep -f -- "$TMP_DIR/bin/scrcpy" >/dev/null 2>&1; then fail_case 'webcam pidfile failure leaves no scrcpy'; else pass_case 'webcam pidfile failure leaves no scrcpy'; fi
eval "$ORIGINAL_ATOMIC_WRITE"
write_pidfile() {
  if [ "$1" = "$PID_MIC" ]; then
    return 1
  fi
  local pidfile="$1" pid="$2" start
  start="$(proc_start_time "$pid")" || return 1
  printf '%s %s\n' "$pid" "$start" | atomic_write_file "$pidfile" 600
}
if start_mic >/dev/null 2>&1; then fail_case 'microphone aborts on pidfile write failure'; else pass_case 'microphone aborts on pidfile write failure'; fi
if pgrep -f -- "$TMP_DIR/bin/scrcpy" >/dev/null 2>&1; then fail_case 'microphone pidfile failure leaves no scrcpy'; else pass_case 'microphone pidfile failure leaves no scrcpy'; fi
if [ -e "$PID_MIC" ]; then fail_case 'microphone pidfile failure removes pidfile'; else pass_case 'microphone pidfile failure removes pidfile'; fi
eval "$ORIGINAL_WRITE_PIDFILE"
# Force the route pidfile write to fail after the microphone itself starts.
write_pidfile() {
  if [ "$1" = "$PID_ROUTE" ]; then
    for _i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ROUTE_PID_MARK" ] && break; /bin/sleep 0.01; done
    return 1
  fi
  local pidfile="$1" pid="$2" start
  start="$(proc_start_time "$pid")" || return 1
  printf '%s %s\n' "$pid" "$start" | atomic_write_file "$pidfile" 600
}
ORIGINAL_ROUTE_AUDIO=$(declare -f route_audio_to_mic)
ROUTE_PID_MARK="$TMP_DIR/route.pid.mark"
route_audio_to_mic() { printf '%s\n' "$BASHPID" > "$ROUTE_PID_MARK"; while :; do :; done; }
route_awake=$KEEP_AWAKE; KEEP_AWAKE=true; printf '0\n' > "$ADB_STATE_FILE"; rm -f "$RUN_DIR/keepawake.saved"
if start_mic >/dev/null 2>&1; then fail_case 'route pidfile failure aborts microphone start'; else pass_case 'route pidfile failure aborts microphone start'; fi
route_pid_test="$(cat "$ROUTE_PID_MARK")"
if kill -0 "$route_pid_test" 2>/dev/null; then fail_case 'route pidfile failure leaves no route process'; else pass_case 'route pidfile failure leaves no route process'; fi
if [ -e "$PID_ROUTE" ]; then fail_case 'route pidfile failure removes pidfile'; else pass_case 'route pidfile failure removes pidfile'; fi
if [ -e "$PID_MIC" ]; then fail_case 'route pidfile failure leaves no microphone pidfile'; else pass_case 'route pidfile failure leaves no microphone pidfile'; fi
check_eq 'route pidfile failure leaves the phone keep-awake setting alone' 0 "$(cat "$ADB_STATE_FILE")"
check 'route pidfile failure saves no keep-awake value' test ! -e "$RUN_DIR/keepawake.saved"
KEEP_AWAKE=$route_awake
unset -f write_pidfile route_audio_to_mic
eval "$ORIGINAL_WRITE_PIDFILE"
eval "$ORIGINAL_ROUTE_AUDIO"
SCRCPY_BUSY=0
# The route helper can end before the parent records its pidfile (pactl already sees scrcpy's stream): nothing is left to
# record, so the capture must survive. Only a helper that is still alive and cannot be recorded aborts the start.
route_audio_to_mic() { return 0; }
write_pidfile() {
  [ "$1" != "$PID_ROUTE" ] || /bin/sleep 0.3
  local pidfile="$1" pid="$2" start
  start="$(proc_start_time "$pid")" || return 1
  printf '%s %s\n' "$pid" "$start" | atomic_write_file "$pidfile" 600
}
if start_mic >/dev/null 2>&1; then pass_case 'microphone starts when the route helper ends before its pidfile is written'; else fail_case 'microphone starts when the route helper ends before its pidfile is written'; fi
if is_running "$PID_MIC"; then pass_case 'microphone keeps running after an early route helper'; else fail_case 'microphone keeps running after an early route helper'; fi
check 'an early route helper leaves no route pidfile' test ! -e "$PID_ROUTE"
stop_mic_only >/dev/null 2>&1
unset -f write_pidfile route_audio_to_mic
eval "$ORIGINAL_WRITE_PIDFILE"
eval "$ORIGINAL_ROUTE_AUDIO"

# register_capture: pidfile and startup wait shared by start_webcam and start_mic.
RC_PIDFILE="$TMP_DIR/register.pid"; RC_LOG_NAME="$TMP_DIR/register.log"; RC_ERR="$TMP_DIR/register.err"
spawn_probe_scrcpy() { "$TMP_DIR/bin/scrcpy" --register-probe >/dev/null 2>&1 9>&- & rc_pid=$!; for _i in $(seq 1 100); do [ "$(cat "/proc/$rc_pid/comm" 2>/dev/null)" = scrcpy ] && break; /bin/sleep 0.02; done; }
spawn_probe_scrcpy
check 'register_capture accepts a running scrcpy' register_capture "$RC_PIDFILE" "$rc_pid" "$RC_LOG_NAME"
check_eq 'register_capture records the process in the pidfile' "$rc_pid" "$(pidfile_pid "$RC_PIDFILE")"
terminate_pid "$rc_pid"; rm -f "$RC_PIDFILE"
/bin/sleep 30 >/dev/null 2>&1 9>&- & rc_pid=$!
if register_capture "$RC_PIDFILE" "$rc_pid" "$RC_LOG_NAME" 2>"$RC_ERR"; then fail_case 'register_capture fails when the process is not scrcpy'; else pass_case 'register_capture fails when the process is not scrcpy'; fi
check 'register_capture names the log when scrcpy does not start' grep -Fq -- "$(t SCRCPY_START_FAIL "$RC_LOG_NAME")" "$RC_ERR"
check 'register_capture removes the pidfile when scrcpy does not start' test ! -e "$RC_PIDFILE"
if kill -0 "$rc_pid" 2>/dev/null; then fail_case 'register_capture stops a live process that is not scrcpy'; else pass_case 'register_capture stops a live process that is not scrcpy'; fi
kill "$rc_pid" 2>/dev/null || true; wait "$rc_pid" 2>/dev/null || true
printf '%s\n' 'INFO: Device: fake' 'ERROR: Could not open video device' > "$RC_LOG_NAME"
/bin/sleep 0 & rc_pid=$!; wait "$rc_pid"
write_pidfile() { printf '%s 1\n' "$2" > "$1"; }
rc_rc=0; rc_sleeps=0; sleep() { rc_sleeps=$((rc_sleeps + 1)); }   # the sleep on PATH is a stub
register_capture "$RC_PIDFILE" "$rc_pid" "$RC_LOG_NAME" >"$RC_ERR" 2>&1 || rc_rc=$?; unset -f sleep
check 'register_capture fails for a scrcpy that died before it was recognized' test "$rc_rc" -ne 0
check 'register_capture shows the log tail of a scrcpy that died before it was recognized' grep -Fq 'Could not open video device' "$RC_ERR"
check_eq 'register_capture does not wait out the recognition period for a dead scrcpy' 0 "$rc_sleeps"
check 'register_capture removes the pidfile of a scrcpy that died before it was recognized' test ! -e "$RC_PIDFILE"
write_pidfile() { :; }
rc_out="$(register_capture "$RC_PIDFILE" "$rc_pid" "$RC_LOG_NAME" 2>&1)" || rc_rc=$?
check_eq 'register_capture stays silent when a stop already took the pidfile' '' "$rc_out"
eval "$ORIGINAL_WRITE_PIDFILE"
# A scrcpy that died before its state could be read is a failed start (log shown), not a state-save failure.
/bin/sleep 0 & rc_pid=$!; wait "$rc_pid"; printf '%s\n' stale > "$RC_PIDFILE"
write_pidfile() { return 1; }
rc_rc=0; register_capture "$RC_PIDFILE" "$rc_pid" "$RC_LOG_NAME" >"$RC_ERR" 2>&1 || rc_rc=$?
check 'register_capture fails for a scrcpy that died before its state was saved' test "$rc_rc" -ne 0
check 'register_capture names the log of a scrcpy that died before its state was saved' grep -Fq -- "$(t SCRCPY_START_FAIL "$RC_LOG_NAME")" "$RC_ERR"
check 'register_capture shows the log tail of a scrcpy that died before its state was saved' grep -Fq 'Could not open video device' "$RC_ERR"
if grep -Fq -- "$(t PROCESS_STATE_SAVE_FAIL)" "$RC_ERR"; then fail_case 'register_capture blames the state file for a scrcpy that died first'; else pass_case 'register_capture blames the state file for a scrcpy that died first'; fi
check 'register_capture removes the pidfile of a scrcpy that died before its state was saved' test ! -e "$RC_PIDFILE"
eval "$ORIGINAL_WRITE_PIDFILE"
spawn_probe_scrcpy; printf '%s\n' stale > "$RC_PIDFILE"
write_pidfile() { return 1; }
if register_capture "$RC_PIDFILE" "$rc_pid" "$RC_LOG_NAME" 2>"$RC_ERR"; then fail_case 'register_capture fails when the pidfile cannot be written'; else pass_case 'register_capture fails when the pidfile cannot be written'; fi
check 'register_capture reports the state-save failure' grep -Fq -- "$(t PROCESS_STATE_SAVE_FAIL)" "$RC_ERR"
if kill -0 "$rc_pid" 2>/dev/null; then fail_case 'register_capture stops the process when the pidfile cannot be written'; else pass_case 'register_capture stops the process when the pidfile cannot be written'; fi
check 'register_capture removes a stale pidfile when the write fails' test ! -e "$RC_PIDFILE"
eval "$ORIGINAL_WRITE_PIDFILE"; unset -f spawn_probe_scrcpy
exec 9>"$TMP_DIR/launch.lock"
check 'launch_capture starts and registers scrcpy' launch_capture "$RC_PIDFILE" "$RC_LOG_NAME" SERIAL1 --launch-probe
lc_pid="$(pidfile_pid "$RC_PIDFILE")"
check 'launch_capture passes the serial and arguments to scrcpy' grep -Fq -- '-s SERIAL1 --launch-probe' "$SCRCPY_LOG"
check 'launch_capture keeps the start lock away from scrcpy' test ! -e "/proc/$lc_pid/fd/9"
exec 9>&-; terminate_pid "$lc_pid"; rm -f "$RC_PIDFILE"

# Audio routing and cleanup pidfile.
MANUAL_ROUTE_PID="$TMP_DIR/manual-route.pid"; ( PID_ROUTE="$MANUAL_ROUTE_PID"; write_pidfile "$PID_ROUTE" "$BASHPID"; cleanup_route_pidfile; test ! -f "$PID_ROUTE" ) && pass_case 'route pidfile cleanup and removal' || fail_case 'route pidfile cleanup and removal'
: > "$NOTIFY_LOG"
check 'audio route success' route_audio_to_mic
check 'a routed audio stream sends no failure notice' test ! -s "$NOTIFY_LOG"
# The helper runs detached and only its log is read, so a failed route must also reach the user as a notification.
route_rc=0; ( pactl() { return 0; }; sleep() { :; }; route_audio_to_mic ) >/dev/null 2>&1 || route_rc=$?
check_eq 'an unroutable audio stream fails the helper' 1 "$route_rc"
check 'an unroutable audio stream notifies the user' grep -Fq -- "$(t AUDIO_ROUTE_FAIL 15)" "$NOTIFY_LOG"
check 'the failure notice carries the manual routing hint' grep -Fq -- "$MIC_SINK_NAME" "$NOTIFY_LOG"

# Text editor fallback and GUI wrappers.
mkdir -p "$TMP_DIR/xdgonly"
cat > "$TMP_DIR/xdgonly/xdg-open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$XDG_OPEN_LOG"
exit 0
EOF
chmod +x "$TMP_DIR/xdgonly/xdg-open"; export XDG_OPEN_LOG="$TMP_DIR/xdg-open.log"; : > "$XDG_OPEN_LOG"; unset VISUAL EDITOR EDITOR; old_path_editor="$PATH"; export PATH="$TMP_DIR/xdgonly"; hash -r; check 'text editor fallback' edit_config; for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$XDG_OPEN_LOG" ] && break; /bin/sleep 0.05; done; check 'xdg-open fallback used' test -s "$XDG_OPEN_LOG"; export PATH="$old_path_editor"; hash -r
combo=$(combo_with_current front front back); check 'combo current preserved' test "$combo" = 'front|back'
failing_action(){ echo 'oops'; return 7; }; if run_gui_action failing_action >/dev/null 2>&1; then fail_case 'GUI action propagates failure'; else pass_case 'GUI action propagates failure'; fi; grep -q -- '--error' "$ZENITY_LOG" && pass_case 'GUI action opened error dialog' || fail_case 'GUI action opened error dialog'
unset -f failing_action

# Agent helper paths.
run_agent_action true >/dev/null; check 'agent current device' test "$(agent_current_device)" = SERIAL1
STOP_MARKER="$TMP_DIR/agent-stop"; stop_all(){ : > "$STOP_MARKER"; }; agent_handle_removed_device; check 'agent removal invokes stop' test -f "$STOP_MARKER"; unset -f stop_all
agent_tray_icon; for _i in 1 2 3 4 5; do [ -s "$YAD_LOG" ] && break; /bin/sleep 0.05; done; check 'agent tray command emitted' test -s "$YAD_LOG"
check 'agent tray menu contains no pipe operators' bash -c '! grep -qF -- "|" "$1"' _ "$YAD_LOG"
TRAY_DIR="$TMP_DIR/bin/phone cam's"; mkdir -p "$TRAY_DIR"; printf '#!/bin/sh\nexit 0\n' > "$TRAY_DIR/phonecam"; chmod +x "$TRAY_DIR/phonecam"; INSTALLED_BIN="$TRAY_DIR/phonecam"; : > "$YAD_LOG"; agent_tray_icon; for _i in 1 2 3 4 5; do [ -s "$YAD_LOG" ] && break; /bin/sleep 0.05; done; tray_line="$(cat "$YAD_LOG")"; expected_tray_path="$(printf '%q' "$INSTALLED_BIN")"; check 'agent tray safely quotes script path' grep -Fq -- "$expected_tray_path menu" <<<"$tray_line"
AGENT_NEW_MARKER="$TMP_DIR/agent-new"; run_agent_action(){ : > "$AGENT_NEW_MARKER"; }; AUTO_MODE=off; agent_handle_new_device SERIAL1; check 'agent new-device off branch' test ! -f "$AGENT_NEW_MARKER"; unset -f run_agent_action
AGENT_LOOP_LOG="$TMP_DIR/agent-loop.log"; AGENT_SEQ="$TMP_DIR/agent-seq"; printf 'SERIAL1\n' > "$AGENT_SEQ"; (
  agent_current_device(){ if [ -s "$AGENT_SEQ" ]; then head -1 "$AGENT_SEQ"; : > "$AGENT_SEQ"; fi; }
  load_config(){ :; }
  agent_handle_new_device(){ printf 'new\n' >> "$AGENT_LOOP_LOG"; }
  agent_handle_removed_device(){ printf 'removed\n' >> "$AGENT_LOOP_LOG"; }
  sleep(){ /bin/sleep 0.3; }
  agent_watcher_loop
) & loop_pid=$!; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do if grep -q '^new$' "$AGENT_LOOP_LOG" 2>/dev/null; then printf '\n' > "$AGENT_SEQ"; fi; if grep -q '^removed$' "$AGENT_LOOP_LOG" 2>/dev/null; then break; fi; /bin/sleep 0.1; done; kill "$loop_pid" 2>/dev/null || true 2>/dev/null || true; wait "$loop_pid" 2>/dev/null || true
check 'agent watcher reacts to connection' grep -q '^new$' "$AGENT_LOOP_LOG"
check 'agent watcher reacts to removal' grep -q '^removed$' "$AGENT_LOOP_LOG"
# Events the watcher raises for a scripted series of adb answers ("-" = empty answer).
agent_loop_events() {
  local n=$# lp
  printf '%s\n' "$@" > "$TMP_DIR/loop.seq"; : > "$TMP_DIR/loop.n"; : > "$TMP_DIR/loop.log"
  (
    agent_current_device() {
      local i; echo . >> "$TMP_DIR/loop.n"; i=$(wc -l < "$TMP_DIR/loop.n")
      [ "$i" -le "$n" ] || i=$n
      sed -n "${i}p" "$TMP_DIR/loop.seq" | sed 's/^-$//'
    }
    load_config() { :; }; phone_keep_awake_stop() { :; }
    agent_handle_new_device() { echo new >> "$TMP_DIR/loop.log"; }
    agent_handle_removed_device() { echo removed >> "$TMP_DIR/loop.log"; }
    sleep() { /bin/sleep 0.02; }
    agent_watcher_loop
  ) & lp=$!
  while [ "$(wc -l < "$TMP_DIR/loop.n")" -lt $((n + 3)) ]; do /bin/sleep 0.02; done
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null || true
  tr '\n' ' ' < "$TMP_DIR/loop.log"
}
check_eq 'agent watcher ignores a single empty adb answer' 'new ' "$(agent_loop_events SERIAL1 SERIAL1 - SERIAL1 SERIAL1)"
check_eq 'agent watcher ignores an empty adb answer after a recovered one' 'new removed ' "$(agent_loop_events SERIAL1 - SERIAL1 - - -)"
check_eq 'agent watcher ignores every isolated empty adb answer' 'new ' "$(agent_loop_events SERIAL1 - SERIAL1 - SERIAL1 SERIAL1)"
# With several phones the agent follows one: a second phone that sorts first must not look like an unplug.
dev_pick() { ADB_DEVICES="$1" agent_current_device ${2:+"$2"}; }
check_eq 'agent follows the first phone when it follows none' S0 "$(dev_pick 'S0\tdevice\nS1\tdevice\n')"
check_eq 'agent keeps the phone it follows when another sorts first' S1 "$(dev_pick 'S0\tdevice\nS1\tdevice\n' S1)"
check_eq 'agent moves to the first phone when the followed one is gone' S0 "$(dev_pick 'S0\tdevice\nS1\tdevice\n' S9)"
check_eq 'agent skips phones that are not authorized' S1 "$(dev_pick 'S0\tunauthorized\nS1\tdevice\n' S0)"
check_eq 'agent sees no phone when none is authorized' '' "$(dev_pick 'S0\tunauthorized\n' S0)"
agent_sticky_events() {   # lists ("A B" = adb order) are polled in turn; the stub picks like agent_current_device
  local n=$# lp
  printf '%s\n' "$@" > "$TMP_DIR/loop.seq"; : > "$TMP_DIR/loop.n"; : > "$TMP_DIR/loop.log"
  (
    agent_current_device() {
      local i l d first=""; echo . >> "$TMP_DIR/loop.n"; i=$(wc -l < "$TMP_DIR/loop.n"); [ "$i" -le "$n" ] || i=$n
      l=$(sed -n "${i}p" "$TMP_DIR/loop.seq")
      for d in $l; do [ -n "$first" ] || first=$d; [ "$d" != "${1:-}" ] || { echo "$d"; return; }; done
      echo "$first"
    }
    load_config() { :; }; phone_keep_awake_stop() { :; }
    agent_handle_new_device() { echo "new $1" >> "$TMP_DIR/loop.log"; }
    agent_handle_removed_device() { echo removed >> "$TMP_DIR/loop.log"; }
    sleep() { /bin/sleep 0.02; }
    agent_watcher_loop
  ) & lp=$!
  while [ "$(wc -l < "$TMP_DIR/loop.n")" -lt $((n + 3)) ]; do /bin/sleep 0.02; done
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null || true
  tr '\n' ' ' < "$TMP_DIR/loop.log"
}
check_eq 'agent watcher keeps a capture when a second phone sorts first' 'new B ' "$(agent_sticky_events B 'A B' 'A B')"
check_eq 'agent watcher follows the other phone once the followed one is unplugged' 'new B removed new A ' "$(agent_sticky_events B 'A B' A A)"
check_eq 'agent watcher stops after two empty adb answers in a row' 'new removed ' "$(agent_loop_events SERIAL1 - - -)"
check_eq 'agent watcher starts again when the phone returns after a removal' 'new removed new ' "$(agent_loop_events SERIAL1 - - SERIAL1)"
agent_watcher_loop_test_cleanup_marker="$TMP_DIR/agent-run"; run_agent_watcher_original=$(declare -f agent_watcher_loop); agent_watcher_loop(){ :; }; run_agent; check 'run_agent writes pidfile' test -f "$PID_AGENT"; unset -f agent_watcher_loop; eval "$run_agent_watcher_original"; rm -f "$PID_AGENT"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
