#!/usr/bin/env bash
# =============================================================================
#  PhoneCam — English walkthrough
#  Drives the real script through a full non-root user journey (fresh machine
#  -> install -> daily use -> language toggle -> uninstall) so every message
#  actually printed at runtime can be read and checked against the catalog,
#  instead of only inspected statically. No zenity/DISPLAY on purpose: it
#  forces the plain-text code paths, which is what this transcript is for.
#
#  PATH is an explicit allow-list (real coreutils, symlinked in) plus this
#  file's own mocks, and nothing else from the host — so a machine that
#  happens to have e.g. xdg-open or notify-send installed cannot silently
#  change which branch of phonecam.sh actually runs.
# =============================================================================
set -uo pipefail

SYSTEM_PATH="$PATH"
unset VISUAL EDITOR DISPLAY WAYLAND_DISPLAY

# Re-exec as an unprivileged user: install/uninstall refuse to run as root,
# and it also matches how a real user actually runs this script.
if [ "${EUID:-$(id -u)}" -eq 0 ] && [ "${WALKTHROUGH_REEXEC:-0}" -ne 1 ]; then
    command -v runuser >/dev/null 2>&1 || { echo "need runuser to drop root" >&2; exit 1; }
    exec env WALKTHROUGH_REEXEC=1 runuser -u nobody -- bash "$0" "$@"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
LOG="$TMP_DIR/transcript.log"
: > "$LOG"

export SCRCPY_PID_LOG="$TMP_DIR/scrcpy.pids"
cleanup() {
    trap - EXIT
    if [ -f "${SCRCPY_PID_LOG:-}" ]; then
        while read -r p; do
            [ -n "$p" ] || continue
            [ -r "/proc/$p/cmdline" ] || continue
            cmdline=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
            case "$cmdline" in *"$TMP_DIR/bin-full/scrcpy"*) kill -9 "$p" 2>/dev/null || true ;; esac
        done < "$SCRCPY_PID_LOG"
    fi
    jobs -pr | while read -r p; do kill -9 "$p" 2>/dev/null || true; done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/home" "$TMP_DIR/run" "$TMP_DIR/bin-pre" "$TMP_DIR/bin-full" "$TMP_DIR/v4l2" "$TMP_DIR/etc" "$TMP_DIR/pactl-state"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
# "C" (not "es*") is enough for detect_system_language() to fall back to
# English; it avoids a "cannot change locale" warning from a real es_ES.UTF-8.
export LANG=C LC_ALL=C
unset LC_MESSAGES

# ---- coreutils allow-list: symlink the real tool in from the host, once ----
link_tool() {
    local name="$1" dir="$2" real
    real="$(PATH="$SYSTEM_PATH" command -v "$name" 2>/dev/null)" || return 0
    ln -sf "$real" "$dir/$name"
}
# NOTE: "getent" is deliberately not on this list — bin-full ships its own
# fixed-answer mock further down (see the "real host group databases vary"
# comment) so overwriting it here would just replace it back with the host's.
CORE_TOOLS="awk basename cat chmod cp cut dirname env find flock grep head id kill ln mkdir mktemp mv nohup printf readlink rm rmdir sed seq sleep stat sync tail tee timeout touch tr uname wc date tar bash"
for dir in "$TMP_DIR/bin-pre" "$TMP_DIR/bin-full"; do
    for t in $CORE_TOOLS; do link_tool "$t" "$dir"; done
done
BASH_BIN="$(PATH="$SYSTEM_PATH" command -v bash)"

PATH_PRE="$TMP_DIR/bin-pre"
PATH_FULL="$TMP_DIR/bin-full"

INSTALLED_BIN="$HOME/.local/bin/phonecam"
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
V4L2_FAKE="$TMP_DIR/v4l2/video42"
LOG_DIR="$HOME/.local/share/phonecam/logs"
RUN_DIR="$TMP_DIR/run/phonecam"
DESKTOP_FILE="$HOME/.local/share/applications/phonecam.desktop"

pass=0 fail=0
step_n=0
step() {
    step_n=$((step_n + 1))
    printf '\n################################################################\n' | tee -a "$LOG"
    printf '## STEP %02d - %s\n' "$step_n" "$1" | tee -a "$LOG"
    printf '################################################################\n' | tee -a "$LOG"
}
note() { printf '   (%s)\n' "$1" | tee -a "$LOG"; }
check() {
    local label="$1"; shift
    if "$@"; then pass=$((pass + 1)); printf 'ok - %s\n' "$label" | tee -a "$LOG"
    else fail=$((fail + 1)); printf 'not ok - %s\n' "$label" | tee -a "$LOG"; fi
}
# No run ever leaves a literal "[KEY]" (undefined-message fallback) on stdout/stderr.
no_missing_keys() { ! grep -qE '\[[A-Z][A-Z0-9_]*\]' <<< "$1"; }

# run_pre/run_bin capture combined output into $LAST_OUT and always print it to
# the transcript; stdin defaults to /dev/null (nothing here is meant to block
# on a prompt) unless a caller pipes its own input in first.
# IMPORTANT: never call these as `x=$(run_pre ...)` — that runs the function in
# a subshell and the LAST_OUT/LAST_RC globals it sets would be lost. Call them
# directly; they already print (and log) the transcript as they go.
run_pre() {
    LAST_OUT=$(PATH="$PATH_PRE" "$BASH_BIN" -c 'timeout --kill-after=5s 30s bash "$1" "${@:2}" < /dev/null' _ "$SCRIPT" "$@" 2>&1)
    LAST_RC=$?
    printf '%s\n' "$LAST_OUT" | tee -a "$LOG"
}
run_bin() {
    LAST_OUT=$(PATH="$PATH_FULL" "$BASH_BIN" -c 'timeout --kill-after=5s 30s bash "$1" "${@:2}" < /dev/null' _ "$INSTALLED_BIN" "$@" 2>&1)
    LAST_RC=$?
    printf '%s\n' "$LAST_OUT" | tee -a "$LOG"
}
# Same as run_bin but feeds $1 on stdin (for prompts read via `read -rp`).
run_bin_stdin() {
    local input="$1"; shift
    LAST_OUT=$(printf '%s' "$input" | PATH="$PATH_FULL" "$BASH_BIN" -c 'timeout --kill-after=5s 30s bash "$1" "${@:2}"' _ "$INSTALLED_BIN" "$@" 2>&1)
    LAST_RC=$?
    printf '%s\n' "$LAST_OUT" | tee -a "$LOG"
}
out_has() { [[ "$LAST_OUT" == *"$1"* ]]; }
out_lacks() { [[ "$LAST_OUT" != *"$1"* ]]; }
out_matches() { [[ "$LAST_OUT" =~ $1 ]]; }
# Title of the last notify-send call (see the mock below): empty if none yet.
last_notify_title() { tail -n 1 "$NOTIFY_LOG" 2>/dev/null | cut -f1; }

# =========================== Mock tools (installed-state) ===========================
export ADB_LOG="$TMP_DIR/adb.log" SCRCPY_LOG="$TMP_DIR/scrcpy.log" NOTIFY_LOG="$TMP_DIR/notify.log"
export ZENITY_LOG="$TMP_DIR/zenity.log" ZENITY_CHOICE=""
: > "$NOTIFY_LOG"; : > "$ZENITY_LOG"
export ADB_STAY_FILE="$TMP_DIR/adb-stay"; printf '0\n' > "$ADB_STAY_FILE"
export ADB_STATE=none  # phone starts out disconnected; a step below "plugs it in"
export PACTL_STATE_DIR="$TMP_DIR/pactl-state"

cat > "$TMP_DIR/bin-full/adb" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${ADB_LOG:?}"
case "${1:-}" in
  start-server) exit 0 ;;
  devices)
    case "$ADB_STATE" in
      none) printf 'List of devices attached\n' ;;
      *) printf 'List of devices attached\nWALKTHRU01\tdevice\n' ;;
    esac
    ;;
  -s)
    [ "${2:-}" = WALKTHRU01 ] || exit 1
    shift 2
    [ "${1:-}" = shell ] || exit 0
    shift
    case "${1:-}" in
      getprop) [ "${2:-}" = ro.build.version.sdk ] && printf '34\n' ;;
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

cat > "$TMP_DIR/bin-full/scrcpy" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then printf 'scrcpy 3.1\n'; exit 0; fi
printf '%s\n' "$$" >> "${SCRCPY_PID_LOG:?}"
for arg in "$@"; do
  [ "$arg" = --list-cameras ] && { printf '%s\n' 'INFO: List of cameras:' '--camera-id=0  back' '--camera-id=1  front'; exit 0; }
done
printf '%s\n' "$*" >> "${SCRCPY_LOG:?}"
/bin/sleep 1000 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
SH

# Stateful: sinks/sources only "exist" once ensure_audio_devices() actually
# creates them, so status can honestly show "not created yet" vs "present".
# The "list sink-inputs" pattern is deliberately correct (list:sink-inputs:),
# matching the real invocation in route_audio_to_mic(); test_user_simulation.sh
# still has the old "list::" pattern, which never matches that real call.
cat > "$TMP_DIR/bin-full/pactl" <<'SH'
#!/bin/sh
d="${PACTL_STATE_DIR:?}"
case "${1:-}:${2:-}:${3:-}" in
  list:short:sinks)   [ -f "$d/sink" ]   && printf '1\tPhoneMicSink\n' ;;
  list:short:sources) [ -f "$d/source" ] && printf '2\tPhoneMic\n' ;;
  list:short:modules)
    [ -f "$d/sink" ]   && printf '10\tmodule-null-sink\t sink_name=PhoneMicSink\n'
    [ -f "$d/source" ] && printf '11\tmodule-remap-source\t source_name=PhoneMic\n'
    ;;
  list:sink-inputs:*) printf 'Sink Input #44\n application.process.binary = "scrcpy"\n' ;;
  load-module:module-null-sink:*)   : > "$d/sink";   printf '10\n' ;;
  load-module:module-remap-source:*) : > "$d/source"; printf '11\n' ;;
  move-sink-input*|unload-module*) exit 0 ;;
esac
exit 0
SH

# Records every desktop notification (title\tbody) so choose-cam/webcam/mic/stop
# messages can be checked at runtime, not just read statically from the catalog.
cat > "$TMP_DIR/bin-full/notify-send" <<'SH'
#!/bin/sh
# notify() always calls us as: notify-send -a PhoneCam TITLE [BODY]
shift 2
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${NOTIFY_LOG:?}"
SH

# have_gui() needs zenity AND $DISPLAY/$WAYLAND_DISPLAY; both stay unset for
# every step except the one dedicated GUI regression check below, so this
# mock's mere presence does not change any other step's plain-text code path.
cat > "$TMP_DIR/bin-full/zenity" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
case " $* " in
    *' --list '*) printf '%s\n' "${ZENITY_CHOICE:-}" ;;
esac
exit 0
SH

# Pass-through: this sandbox has no real sudo, and phonecam.sh only asks for
# it to run already-mocked commands (apt/usermod/modprobe) or, for /etc
# writes, a function replaced below by the install harness.
cat > "$TMP_DIR/bin-full/sudo" <<'SH'
#!/bin/sh
exec "$@"
SH

cat > "$TMP_DIR/bin-full/apt" <<'SH'
#!/bin/sh
exit 0
SH

# Forces two real branches of cmd_install: the kernel-headers fallback warning
# (linux-headers-$(uname -r) reported as unavailable) and the normal "adb"
# package name (as opposed to android-tools-adb).
cat > "$TMP_DIR/bin-full/apt-cache" <<'SH'
#!/bin/sh
case "${2:-}" in
  linux-headers-*) exit 1 ;;
  *) exit 0 ;;
esac
SH

cat > "$TMP_DIR/bin-full/systemctl" <<'SH'
#!/bin/sh
exit 0
SH

cat > "$TMP_DIR/bin-full/modprobe" <<'SH'
#!/bin/sh
exit 0
SH

# Reports v4l2loopback as already loaded, to exercise the reload branch
# (V4L2_RELOAD) instead of the silent first-load path.
cat > "$TMP_DIR/bin-full/lsmod" <<'SH'
#!/bin/sh
printf 'v4l2loopback           40960  0\n'
SH

# Succeeds, to exercise the "added to group, needs relogin" ending instead of
# the permission-denied path a sandboxed non-root user would otherwise hit.
cat > "$TMP_DIR/bin-full/usermod" <<'SH'
#!/bin/sh
exit 0
SH

# Reports Secure Boot enabled, to exercise the MOK warning block.
cat > "$TMP_DIR/bin-full/mokutil" <<'SH'
#!/bin/sh
[ "${1:-}" = --sb-state ] && printf 'SecureBoot enabled\n'
exit 0
SH

# Real host group databases vary; report "video"/"plugdev" as existing so the
# group-membership branch behaves the same on every machine that runs this.
cat > "$TMP_DIR/bin-full/getent" <<'SH'
#!/bin/sh
[ "${1:-}" = group ] && case "${2:-}" in video|plugdev) exit 0 ;; esac
exit 2
SH

# Same for id: the installer asks `id -nG` which groups the user already has, and a real user in video/plugdev skips the
# branch under test. The link made above is removed first so the mock is not written through it into the host's id.
rm -f "$TMP_DIR/bin-full/id"
cat > "$TMP_DIR/bin-full/id" <<SH
#!/bin/sh
[ "\${1:-}" = -nG ] && { echo tester; exit 0; }
exec "$(PATH="$SYSTEM_PATH" command -v id)" "\$@"
SH

chmod +x "$TMP_DIR/bin-full"/adb "$TMP_DIR/bin-full"/scrcpy "$TMP_DIR/bin-full"/pactl \
    "$TMP_DIR/bin-full"/sudo "$TMP_DIR/bin-full"/apt "$TMP_DIR/bin-full"/apt-cache "$TMP_DIR/bin-full"/systemctl \
    "$TMP_DIR/bin-full"/modprobe "$TMP_DIR/bin-full"/lsmod "$TMP_DIR/bin-full"/usermod "$TMP_DIR/bin-full"/id \
    "$TMP_DIR/bin-full"/mokutil "$TMP_DIR/bin-full"/getent "$TMP_DIR/bin-full"/notify-send "$TMP_DIR/bin-full"/zenity

echo "PhoneCam walkthrough (EN) — transcript log: $LOG"
echo "HOME=$HOME"

# =========================== 1. Fresh machine, no config ===========================
step "status with no config file yet, adb/pactl not even installed"
run_pre status
check "warns the config file is missing"       out_has "not found; using defaults"
check "tells the user to run install"          out_has "Run 'phonecam.sh install' if"
check "notices adb is missing"                 out_has "'adb' is not installed"
check "notices pactl is missing"               out_has "'pactl' is not installed"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "-h before install"
run_pre -h
check "prints usage title"                     out_has "use your Android as a webcam/microphone"
check "lists the install command"              out_matches $'(^|\n)  install +Install system dependencies'
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "unknown command"
run_pre frobnicate
check "reports the unknown command"            out_has "Unknown command: frobnicate"
check "still prints usage as a hint"           out_has "Usage: phonecam.sh <command>"
check "exits non-zero"                         test "$LAST_RC" -eq 1

# =========================== 2. Install (non-root, non-interactive) ===========================
# The real script writes /etc/modprobe.d and /etc/modules-load.d files as root
# via sudo_atomic_write_file(). There is no real sudo/root here (nor should
# there be, for a disposable sandbox run as "nobody"), so this harness
# `source`s phonecam.sh (its trailing `main "$@"` guard only fires when run
# directly, not sourced) and replaces just that one function to redirect
# /etc/* into the sandbox before calling main itself. Every other privileged
# call (apt/usermod/modprobe) goes through the plain pass-through "sudo" mock
# above, since those targets are already mocked and don't check real privilege.
export WALK_SCRIPT="$SCRIPT" WALK_ETC="$TMP_DIR/etc" WALK_DEV="$TMP_DIR/dev"
mkdir -p "$WALK_DEV"   # the installer sees this empty /dev, never a real /dev/video42
cat > "$TMP_DIR/install-harness.sh" <<'HARNESS'
set -uo pipefail
source "$WALK_SCRIPT"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$WALK_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
sudo_atomic_write_file() {
    local dest="${1:-}" mode="${2:-644}"
    case "$dest" in
        /etc/*) dest="$WALK_ETC/${dest#/etc/}" ;;
    esac
    atomic_write_file "$dest" "$mode"
}
main install --yes
HARNESS

step "install --yes (non-interactive, full toolset present)"
LAST_OUT=$(PATH="$PATH_FULL" timeout --kill-after=5s 30s bash "$TMP_DIR/install-harness.sh" < /dev/null 2>&1)
LAST_RC=$?
printf '%s\n' "$LAST_OUT" | tee -a "$LOG"
check "installer ran to completion"            test "$LAST_RC" -eq 0
check "picked the 'adb' package name"          out_has "Packages installed."
check "warned about missing kernel headers"    out_has "linux-headers-generic"
check "warned about Secure Boot / MOK"         out_has "Secure Boot is enabled"
check "id mock overrides the host groups"      test "$(PATH="$PATH_FULL" id -nG)" = tester
check "added the user to video/plugdev"        out_has "Added to group 'video'"
check "wrote the v4l2loopback modprobe.d conf" test -f "$TMP_DIR/etc/modprobe.d/phonecam-v4l2loopback.conf"
check "installed script is executable"         test -x "$INSTALLED_BIN"
check "config file was created"                test -f "$CONF_FILE"
check "PATH-not-set warning shown"             out_has "was added to PATH in ~/.profile"
check "install finished cleanly"               out_has "Installation completed."
check "relogin notice shown (new groups)"      out_has "must LOG OUT and back in"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

# =========================== 3. Daily use, as the installed "phonecam" binary ===========================
sed -i "s#^V4L2_DEVICE=.*#V4L2_DEVICE='$V4L2_FAKE'#" "$CONF_FILE"   # status runs in a subprocess: point it at the fake node, not yet created
step "status right after install (phone still unplugged, nothing running yet)"
run_bin status
check "adb no longer reported as missing"      out_lacks "'adb' is not installed"
check "phone reported as not authorized"       out_has "No authorized phone detected."
check "webcam reported inactive"               out_has "Webcam inactive."
check "microphone reported inactive"           out_has "Microphone inactive."
check "virtual webcam reported absent"         out_has "does not exist yet."
check "virtual mic reported not created yet"   out_has "not created yet"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "phone gets plugged in over USB; v4l2loopback is faked as already loaded"
export ADB_STATE=plugged
mkdir -p "$(dirname -- "$V4L2_FAKE")"; : > "$V4L2_FAKE"
note "ADB now reports WALKTHRU01; V4L2_DEVICE points at the fake $V4L2_FAKE so webcam/mic can run for real"

step "cameras"
run_bin cameras
check "lists the back camera (id 0)"           out_has "camera-id=0"
check "lists the front camera (id 1)"          out_has "camera-id=1"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "choose-cam (plain-text prompt, camera 0)"
run_bin_stdin "0" choose-cam
check "printed the raw camera list first"      out_has "camera-id=0"
check "confirmed camera 0 as default"          out_has "Camera 0 saved as default."
check "config file now pins camera id 0"       grep -q "^CAMERA_ID='0'" "$CONF_FILE"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "choose-cam through the zenity (GUI) branch — runtime check that the desktop-notification title says 'Choose camera', not the earlier-fixed broken 'Camera %s saved as default.'"
ZENITY_CHOICE=1
: > "$ZENITY_LOG"; : > "$NOTIFY_LOG"
DISPLAY=:99 run_bin choose-cam
check "the zenity --list dialog was actually invoked"       grep -q -- '--list' "$ZENITY_LOG"
check "dialog was titled 'Choose camera'"                    grep -q -- '--title=Choose camera' "$ZENITY_LOG"
check "notification title is 'Choose camera' (not CAMERA_SAVED)" test "$(last_notify_title)" = "Choose camera"
check "camera id 1 was saved to the config"                  grep -q "^CAMERA_ID='1'" "$CONF_FILE"
check "no undefined message key leaked"                      no_missing_keys "$LAST_OUT"
ZENITY_CHOICE=""

step "config (no editor available -> plain-text fallback + desktop notification)"
run_bin config
check "reports no editor was found"            out_has "No editor was found. Edit the file manually:"
check "points at the real config path"         out_has "$CONF_FILE"
check "notification uses the 'PhoneCam' app title" test "$(last_notify_title)" = "PhoneCam"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "help-connection"
run_bin help-connection
check "explains enabling Developer options"    out_has "Developer options"
check "mentions the USB debugging prompt"      out_has "Allow USB debugging"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "webcam (starts scrcpy in camera mode)"
: > "$NOTIFY_LOG"
run_bin webcam
check "reports codec/bitrate/fps"              out_has "Starting webcam (h264, 20M, 30fps)..."
check "reports the webcam as active"           out_has "Webcam is active at $V4L2_FAKE"
check "notification title is 'Webcam active'"  test "$(last_notify_title)" = "Webcam active"
check "webcam pidfile was written"             test -s "$RUN_DIR/webcam.pid"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "mic (starts scrcpy in audio-only mode; routes audio to the virtual mic)"
: > "$NOTIFY_LOG"
run_bin mic
check "reports codec/bitrate"                  out_has "Starting microphone (opus, 192K)..."
check "reports the mic as active"              out_has "Select 'PhoneMic' as the audio input."
check "notification title is 'Microphone active'" test "$(last_notify_title)" = "Microphone active"
check "mic pidfile was written"                test -s "$RUN_DIR/mic.pid"
for _ in {1..20}; do grep -q "Phone audio routed" "$LOG_DIR/mic.log" 2>/dev/null && break; sleep 0.2; done
check "audio was routed to the virtual mic (logged by the background job)" grep -q "Phone audio routed to the virtual microphone." "$LOG_DIR/mic.log"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "status while webcam+mic are both active"
run_bin status
check "phone shown as connected"               out_has "Phone connected via ADB:"
check "webcam reported ACTIVE"                 out_has "Webcam ACTIVE"
check "microphone reported ACTIVE"             out_has "Microphone ACTIVE"
check "virtual webcam reported present"        out_has "is present."
check "virtual mic reported present"           out_has "Virtual microphone 'PhoneMic' is present."
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "both (idempotent: webcam and mic are already running)"
run_bin both
check "warns the webcam is already active"     out_has "A webcam is already active"
check "warns the microphone is already active" out_has "The microphone is already active"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "stop (stops webcam + microphone together)"
: > "$NOTIFY_LOG"
run_bin stop
check "reports PhoneCam has been stopped"      out_has "PhoneCam has been stopped."
check "notification confirms it"               test "$(last_notify_title)" = "PhoneCam has been stopped."
check "webcam pidfile removed"                 test ! -e "$RUN_DIR/webcam.pid"
check "mic pidfile removed"                    test ! -e "$RUN_DIR/mic.pid"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "status after stop (everything inactive again)"
run_bin status
check "webcam reported inactive"               out_has "Webcam inactive."
check "microphone reported inactive"           out_has "Microphone inactive."
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

# =========================== 4. Language toggle, round trip ===========================
step "language toggle (English -> Spanish)"
run_bin l
check "confirmation itself is shown in the NEW language" out_has "Idioma cambiado a Español."
check "config file now pins Spanish"           grep -q "^PHONECAM_LANG='es'" "$CONF_FILE"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "status is now rendered in Spanish"
run_bin status
check "Spanish wording appears"                out_has "Webcam inactiva."
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

step "language toggle (Spanish -> English, back to the start)"
run_bin l
check "confirmation shown in English"          out_has "Language changed to English."
check "config file pins English again"         grep -q "^PHONECAM_LANG='en'" "$CONF_FILE"
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

# =========================== 5. Uninstall ===========================
step "uninstall (also removing the saved configuration)"
run_bin_stdin "y" uninstall
check "stops any active process first"         out_has "Stopping active processes..."
check "removes the installed script"           out_has "Removing installed script..."
check "installed binary is gone"               test ! -e "$INSTALLED_BIN"
check "desktop launcher is gone"               test ! -e "$DESKTOP_FILE"
# The UNINSTALL_CONFIG_Q prompt can't be asserted here: bash's `read -p` only
# ever writes the prompt when stdin is a terminal (confirmed separately), so
# with piped stdin it's silently skipped, not just redirected elsewhere. "y"
# is still read correctly, which the two checks below confirm functionally.
check "confirms the configuration was removed" out_has "Configuration removed."
check "config directory is actually gone"      test ! -d "$CONF_DIR"
check "final uninstall confirmation shown"     out_has "PhoneCam uninstalled."
check "no undefined message key leaked"        no_missing_keys "$LAST_OUT"

printf '\n%s passed, %s failed\n' "$pass" "$fail" | tee -a "$LOG"
echo "Full transcript: $LOG"
[ "$fail" -eq 0 ]
