#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
cleanup(){ jobs -pr | while read -r p; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP_DIR"; }; trap cleanup EXIT

export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
export RUN_DIR="$TMP_DIR/run/phonecam" LOG_DIR="$TMP_DIR/logs"
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
export CONF_DIR CONF_FILE
export V4L2_DEVICE="$TMP_DIR/v4l2/video42"
mkdir -p "$CONF_DIR" "$RUN_DIR" "$LOG_DIR" "$(dirname "$V4L2_DEVICE")" "$TMP_DIR/bin"
touch "$V4L2_DEVICE"

export ZENITY_LOG="$TMP_DIR/zenity.log" CHOICE_FILE="$TMP_DIR/choices"
: > "$ZENITY_LOG"
cat > "$TMP_DIR/bin/adb" <<'SH'
#!/bin/sh
printf 'List of devices attached\nSERIAL1\tdevice\n'
SH
cat > "$TMP_DIR/bin/zenity" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$ZENITY_LOG"
if [ -f "$CHOICE_FILE" ] && [ -s "$CHOICE_FILE" ]; then
    IFS= read -r choice < "$CHOICE_FILE"
    tail -n +2 "$CHOICE_FILE" > "$CHOICE_FILE.tmp" 2>/dev/null || :
    mv "$CHOICE_FILE.tmp" "$CHOICE_FILE"
    printf '%s\n' "$choice"
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/adb" "$TMP_DIR/bin/zenity"
export PATH="$TMP_DIR/bin:$PATH"
export DISPLAY=":0"

source "$SCRIPT"
ensure_scrcpy_installed(){ return 0; }
phone_status_short(){ printf 'connected\n'; }
is_running(){ return 1; }
status(){ printf 'status ok\n'; }
choose_camera_gui(){ printf 'choose_cam\n' >> "$ACTION_LOG"; }
start_webcam(){ printf 'webcam_start\n' >> "$ACTION_LOG"; }
stop_webcam_only(){ printf 'webcam_stop\n' >> "$ACTION_LOG"; }
start_mic(){ printf 'mic_start\n' >> "$ACTION_LOG"; }
stop_mic_only(){ printf 'mic_stop\n' >> "$ACTION_LOG"; }
start_both(){ printf 'both_start\n' >> "$ACTION_LOG"; }
stop_all(){ printf 'stop_all\n' >> "$ACTION_LOG"; }
advanced_settings_gui(){ printf 'config\n' >> "$ACTION_LOG"; }
show_connection_help(){ printf 'help\n' >> "$ACTION_LOG"; }
toggle_language(){ printf 'language\n' >> "$ACTION_LOG"; }
ACTION_LOG="$TMP_DIR/actions.log"
: > "$ACTION_LOG"
pass=0
fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

# have_gui() needs a real display in addition to the zenity binary.
if ( unset DISPLAY WAYLAND_DISPLAY; have_gui ); then bad 'have_gui false with zenity but no display'; else ok 'have_gui false with zenity but no display'; fi
if ( unset DISPLAY; export WAYLAND_DISPLAY="wayland-0"; have_gui ); then ok 'have_gui true on Wayland without DISPLAY'; else bad 'have_gui true on Wayland without DISPLAY'; fi
if ( PATH="/no/such/dir"; have_gui ); then bad 'have_gui false without zenity even with a display'; else ok 'have_gui false without zenity even with a display'; fi
if have_gui; then ok 'have_gui true with zenity and DISPLAY set'; else bad 'have_gui true with zenity and DISPLAY set'; fi

run_choice(){
    local c="$1" state="${2:-inactive}"; : > "$CHOICE_FILE"; printf '%s\nexit\n' "$c" > "$CHOICE_FILE"
    case "$state" in
      active-webcam) is_running(){ [ "$1" = "$PID_WEBCAM" ]; } ;;
      active-mic) is_running(){ [ "$1" = "$PID_MIC" ]; } ;;
      *) is_running(){ return 1; } ;;
    esac
    gui_menu >/dev/null 2>&1
    tail -n 1 "$ACTION_LOG"
}

PID_WEBCAM="$RUN_DIR/webcam.pid" PID_MIC="$RUN_DIR/mic.pid"
for pair in 'webcam_start inactive' 'mic_start inactive' 'both_start inactive' 'choose_cam inactive' 'status inactive' 'config inactive' 'help inactive' 'language inactive' 'webcam_stop active-webcam' 'mic_stop active-mic' 'stop_all active-webcam'; do
  choice=${pair% *}; state=${pair#* }
  case "$choice" in
    status) expected=status_any;;
    *) expected=$choice;;
  esac
  got=$(run_choice "$choice" "$state")
  if [ "$choice" = status ]; then
    check 'GUI status opens text-info dialog' grep -q -- '--text-info' "$ZENITY_LOG"
  else
    check "GUI action dispatches $choice" test "$got" = "$expected"
  fi
done

# Icons live in gui_menu, not in the shared catalog (which test_ui_aesthetics.py keeps emoji-free).
is_running(){ return 1; }; : > "$ZENITY_LOG"; printf '%s\n' exit > "$CHOICE_FILE"; gui_menu >/dev/null 2>&1
for icon in 📱 🎥 🎙️ 🎯 📊 ⚙️ ❓ 🌐 🚪; do check "GUI menu shows icon $icon" grep -qF -- "$icon" "$ZENITY_LOG"; done

# ADB-missing branch: a desktop has a real adb in /usr/bin, so the PATH is rebuilt from the system tools and the fakes without it.
no_adb="$TMP_DIR/no-adb"; mkdir -p "$no_adb"
ln -sf -t "$no_adb" /bin/* 2>/dev/null || :; ln -sf -t "$no_adb" /usr/bin/* 2>/dev/null || :; ln -sf -t "$no_adb" "$TMP_DIR"/bin/*; rm -f "$no_adb/adb"
printf '%s\n' exit > "$CHOICE_FILE"; set +e; ( PATH="$no_adb"; hash -r; gui_menu >/dev/null 2>&1 ); rc=$?; set -e; check 'GUI menu rejects missing ADB' test "$rc" -eq 1; check 'GUI menu reports missing ADB' grep -q -- '--error' "$ZENITY_LOG"
# scrcpy preparation failure branch.
ensure_scrcpy_installed(){ return 1; }
printf '%s\n' exit > "$CHOICE_FILE"; set +e; gui_menu >/dev/null 2>&1; rc=$?; set -e; check 'GUI menu rejects scrcpy preparation failure' test "$rc" -eq 1; check 'GUI menu reports scrcpy preparation failure' grep -q -- '--error' "$ZENITY_LOG"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
