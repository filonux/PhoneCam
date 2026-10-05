#!/usr/bin/env bash
# The agent runs from a systemd --user unit (WantedBy=default.target), which can start before the desktop session has
# exported DISPLAY to the user manager. Fakes stand in for the phone and the desktop tools; the "session" is a file.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
export T="$TMP_DIR" SCRIPT HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" PHONECAM_LANG=en PHONECAM_START_GRACE=0
export PATH="$TMP_DIR/bin:/usr/bin:/bin"
mkdir -p "$HOME/.config/phonecam" "$XDG_RUNTIME_DIR" "$TMP_DIR/bin"
unset DISPLAY WAYLAND_DISPLAY

printf "AUTO_MODE='ask'\nKEEP_AWAKE='false'\nV4L2_DEVICE='%s/video42'\n" "$TMP_DIR" > "$HOME/.config/phonecam/phonecam.conf"
touch "$TMP_DIR/video42"

# adb: the phone is connected while $T/phone exists.
cat > "$TMP_DIR/bin/adb" <<'SH'
#!/bin/sh
case "$1" in
  devices) printf 'List of devices attached\n'; [ -e "$T/phone" ] && printf 'TEST123\tdevice\n' ;;
  -s) shift 2; [ "$1" = shell ] && [ "$2" = getprop ] && echo 35 ;;
esac
exit 0
SH
# scrcpy: stays alive as a child of a script named scrcpy, which is what the pidfile check expects.
cat > "$TMP_DIR/bin/scrcpy" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo 'scrcpy 3.0'; exit 0; fi
echo "$*" >> "$T/scrcpy.log"
/bin/sleep 1000 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; exit 0' TERM INT
wait "$child"
SH
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/pactl"
# yad: like the real one, it dies without a display and otherwise stays resident as the tray icon.
cat > "$TMP_DIR/bin/yad" <<'SH'
#!/bin/sh
echo "yad DISPLAY=${DISPLAY:-none}" >> "$T/yad.log"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || exit 1
exec /bin/sleep 1000
SH
# zenity: fails without a display; the mode list is answered with "webcam".
cat > "$TMP_DIR/bin/zenity" <<'SH'
#!/bin/sh
echo "zenity DISPLAY=${DISPLAY:-none} $1" >> "$T/zenity.log"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || exit 1
case "$*" in *--list*) echo webcam ;; esac
exit 0
SH
cat > "$TMP_DIR/bin/notify-send" <<'SH'
#!/bin/sh
shift 2
echo "$*" >> "$T/notify.log"
SH
# systemctl: the user manager exists unless $T/no-manager does; it holds the $T/session-env lines once $T/session exists.
cat > "$TMP_DIR/bin/systemctl" <<'SH'
#!/bin/sh
echo "$*" >> "$T/systemctl.log"
[ ! -e "$T/no-manager" ] || exit 1
if [ "$*" = "--user show-environment" ]; then
    echo 'LANG=C'
    if [ -e "$T/session" ]; then cat "$T/session-env"; fi
fi
exit 0
SH
chmod +x "$TMP_DIR/bin"/*

pass=0
fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
check_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
# Polls "$@" for up to $1 tenths of a second.
within(){ local tenths="$1" i; shift; for ((i = 0; i < tenths; i++)); do "$@" && return 0; /bin/sleep 0.1; done; return 1; }
has_line(){ grep -Fq -- "$2" "$1" 2>/dev/null; }
lacks_line(){ ! has_line "$@"; }
reset_state(){ rm -f "$T/session" "$T/no-manager" "$T/systemctl.log" "$T/phone"; printf 'DISPLAY=:0\nXAUTHORITY=/home/u/.Xauthority\n' > "$T/session-env"; }
# Runs code in a fresh shell that has sourced the script; $2.. are its positional args.
in_child(){ local code="$1"; shift; bash -c 'source "$SCRIPT"; CURRENT_LANG=en; '"$code" _ "$@"; }

# ---------- agent_wait_display ---------------------------------------------------
reset_state
wrc=0; DISPLAY=:7 in_child 'agent_wait_display' || wrc=$?
check_eq 'a display inherited from the environment needs no wait' "$wrc" 0
check 'an inherited display leaves the user manager alone' test ! -e "$T/systemctl.log"

wrc=0; WAYLAND_DISPLAY=wayland-1 in_child 'agent_wait_display' || wrc=$?
check_eq 'an inherited Wayland display needs no wait either' "$wrc" 0

wrc=0; PHONECAM_DISPLAY_WAIT=0 in_child 'agent_wait_display' || wrc=$?
check_eq 'PHONECAM_DISPLAY_WAIT=0 skips the wait' "$wrc" 0
check 'PHONECAM_DISPLAY_WAIT=0 never queries the user manager' test ! -e "$T/systemctl.log"

touch "$T/no-manager"
t0=$SECONDS; wrc=0; PHONECAM_DISPLAY_WAIT=30 in_child 'agent_wait_display' >/dev/null 2>&1 || wrc=$?
check_eq 'without a user manager the wait gives up at once' "$wrc" 1
check 'without a user manager nothing is waited for' test $((SECONDS - t0)) -lt 4

reset_state; touch "$T/session"
out="$(PHONECAM_DISPLAY_WAIT=5 in_child 'agent_wait_display; echo "rc=$? DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY"; bash -c "echo child=\$DISPLAY"')"
check 'a display already published by the manager is adopted' grep -Fxq 'rc=0 DISPLAY=:0 XAUTHORITY=/home/u/.Xauthority' <<<"$out"
check 'the adopted display is exported to child processes' grep -Fxq 'child=:0' <<<"$out"
check 'adopting the display is logged' grep -Fq 'Graphical session found after' <<<"$out"

reset_state
( /bin/sleep 2; touch "$T/session" ) &
t0=$SECONDS; out="$(PHONECAM_DISPLAY_WAIT=15 in_child 'agent_wait_display; echo "rc=$? DISPLAY=$DISPLAY"')"
check 'a session that starts later is picked up' grep -Fxq 'rc=0 DISPLAY=:0' <<<"$out"
check 'a late session is picked up without waiting out the limit' test $((SECONDS - t0)) -lt 8
wait

reset_state
t0=$SECONDS; out="$(PHONECAM_DISPLAY_WAIT=2 in_child 'agent_wait_display; echo "rc=$?"' 2>&1)"
check 'without a session the wait ends with failure' grep -Fxq 'rc=1' <<<"$out"
check 'the failed wait names its limit and the command that fixes it' grep -Fq 'No graphical session after 2 s' <<<"$out"
check 'the failed wait lasts about the limit' test $((SECONDS - t0)) -ge 2 -a $((SECONDS - t0)) -lt 8

reset_state; touch "$T/session"; printf 'DISPLAY=:0;touch %s/pwned\nXAUTHORITY=a b\n' "$T" > "$T/session-env"
out="$(PHONECAM_DISPLAY_WAIT=1 in_child 'agent_wait_display; echo "rc=$? DISPLAY=${DISPLAY:-none}"' 2>&1)"
check 'values with unexpected characters are not adopted' grep -Fxq 'rc=1 DISPLAY=none' <<<"$out"
check 'values with unexpected characters run nothing' test ! -e "$T/pwned"

# ---------- the real agent, as systemd starts it: no display at first ----------------
reset_state; rm -f "$T"/{yad,zenity,notify,scrcpy}.log
export PHONECAM_DISPLAY_WAIT=30
bash "$SCRIPT" agent > "$T/agent.out" 2>&1 & agent=$!
agent_registered(){ [ "$(cut -d' ' -f1 "$XDG_RUNTIME_DIR/phonecam/agent.pid" 2>/dev/null)" = "$agent" ]; }
check 'the agent registers itself while it waits for the session' within 50 agent_registered
/bin/sleep 1.5
check 'no tray icon is attempted before there is a display' test ! -e "$T/yad.log"

touch "$T/session"
check 'the tray icon appears once the session exists' within 80 has_line "$T/yad.log" 'yad DISPLAY=:0'
check 'the agent reports the session it found' within 20 has_line "$T/agent.out" 'Graphical session found'
check 'the tray icon is created exactly once' test "$(wc -l < "$T/yad.log")" -eq 1

touch "$T/phone"
check 'plugging the phone in shows the mode dialog' within 80 has_line "$T/zenity.log" 'zenity DISPLAY=:0 --list'
check 'choosing webcam in the dialog starts scrcpy' within 80 has_line "$T/scrcpy.log" '--video-source=camera'
check 'scrcpy writes to the virtual camera node of the configuration' has_line "$T/scrcpy.log" "--v4l2-sink=$T/video42"
check 'the dialog replaces the "open the menu" fallback notification' lacks_line "$T/notify.log" "Run 'phonecam menu'"

rm -f "$T/phone"
capture_stopped(){ [ ! -e "$XDG_RUNTIME_DIR/phonecam/webcam.pid" ]; }
check 'unplugging the phone stops the capture' within 150 capture_stopped

kill "$agent"
agent_exited(){ ! kill -0 "$agent" 2>/dev/null; }
check 'a terminated agent exits' within 50 agent_exited
wait "$agent" 2>/dev/null || true
check 'a terminated agent removes its pidfile' test ! -e "$XDG_RUNTIME_DIR/phonecam/agent.pid"

# ---------- terminated while it still waits ----------------------------------------
reset_state; rm -f "$T/yad.log"
bash "$SCRIPT" agent > "$T/agent2.out" 2>&1 & agent=$!
check 'a second agent also registers while it waits' within 50 agent_registered
/bin/sleep 1.2
kill "$agent"
check 'an agent terminated during the wait exits at once' within 30 agent_exited
wait "$agent" 2>/dev/null || true
check 'an agent terminated during the wait removes its pidfile' test ! -e "$XDG_RUNTIME_DIR/phonecam/agent.pid"
check 'an agent terminated during the wait never tried a tray icon' test ! -e "$T/yad.log"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
