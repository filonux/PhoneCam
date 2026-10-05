#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
export SCRCPY_PID_LOG="$TMP_DIR/scrcpy.pids"
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
  [ ! -s "$TMP_DIR/adb-daemon.pid" ] || kill "$(cat "$TMP_DIR/adb-daemon.pid")" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/run/phonecam" "$TMP_DIR/logs" "$TMP_DIR/v4l2"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
export RUN_DIR="$TMP_DIR/run/phonecam" LOG_DIR="$TMP_DIR/logs"
export SCRCPY_LOG="$TMP_DIR/scrcpy.log" PACTL_LOG="$TMP_DIR/pactl.log" ADB_STATE_FILE="$TMP_DIR/adb-state" ADB_API=35 ADB_STAY=0 ADB_LOG="$TMP_DIR/adb.log"
printf '%s\n' 0 > "$ADB_STATE_FILE"; : > "$ADB_LOG"
export ADB_STATE=connected

cat > "$TMP_DIR/bin/adb" <<'SH'
#!/bin/sh
if [ -n "${ADB_SPAWN_DAEMON:-}" ] && [ ! -e "$ADB_SPAWN_DAEMON" ]; then
  /bin/sleep 120 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$ADB_SPAWN_DAEMON"
fi
case "${1:-}" in
  start-server) exit 0 ;;
  devices)
    case "$ADB_STATE" in
      none) printf 'List of devices attached\n' ;;
      multi) printf 'List of devices attached\nSERIAL1\tdevice\nSERIAL2\tdevice\n' ;;
      *) printf 'List of devices attached\nSERIAL1\tdevice\n' ;;
    esac
    ;;
  -s)
    serial="$2"; shift 2
    { [ "$serial" = SERIAL1 ] && [ "$ADB_STATE" != none ]; } || { [ "$serial" = SERIAL2 ] && [ "$ADB_STATE" = multi ]; } || exit 1
    [ "${1:-}" = shell ] || exit 0
    shift
    case "${1:-}" in
      getprop) [ "${2:-}" = ro.build.version.sdk ] && printf '%s\n' "${ADB_API:-35}" ;;
      settings)
        case "${2:-}" in
          get) printf '%s\n' "${ADB_STAY:-0}" ;;
          put) printf '%s\n' "${5:-}" > "$ADB_STATE_FILE"; ADB_STAY="${5:-0}"; export ADB_STAY ;;
        esac
        ;;
      cmd) printf '%s\n' "cmd $*" >> "$ADB_LOG" ;;
      input) printf '%s\n' "input $*" >> "$ADB_LOG" ;;
      dumpsys) printf 'mWakefulness=Awake\n' ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
cat > "$TMP_DIR/bin/scrcpy" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then printf 'scrcpy %s\n' "${SCRCPY_VERSION:-3.0}"; exit 0; fi
case "${SCRCPY_VERSION:-3.0}" in 2.[34]*) case " $* " in *' --no-window '*) echo 'scrcpy: unknown option --no-window' >&2; exit 1 ;; esac ;; esac
printf '%s\n' "$$" >> "$SCRCPY_PID_LOG"
for arg in "$@"; do
  [ "$arg" = --list-cameras ] && { printf '%s\n' 'INFO: List of cameras:' '--camera-id=0  back' '--camera-id=1  front'; exit 0; }
done
printf '%s\n' "$*" >> "$SCRCPY_LOG"
if [ -n "${SCRCPY_EXIT_AFTER:-}" ]; then /bin/sleep "$SCRCPY_EXIT_AFTER"; echo 'ERROR: Could not open video device' >&2; exit 1; fi
/bin/sleep 1000 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
SH
cat > "$TMP_DIR/bin/pactl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PACTL_LOG"
case "${1:-}:${2:-}:${3:-}" in
  list:short:sinks) printf '1\tPhoneMicSink\n' ;;
  list:short:sources) printf '2\tPhoneMic\n' ;;
  list:short:modules) printf '10\tmodule-null-sink\t sink_name=PhoneMicSink\n11\tmodule-remap-source\t source_name=PhoneMic\n' ;;
  list:sink-inputs:) printf 'Sink Input #44\n application.process.binary = "scrcpy"\n' ;;
  load-module|move-sink-input|unload-module*) exit 0 ;;
esac
SH
cat > "$TMP_DIR/bin/zenity" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP_DIR/bin"/*
export PATH="$TMP_DIR/bin:/usr/bin:/bin"

source "$SCRIPT"
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
RUN_DIR="$TMP_DIR/run/phonecam"
LOG_DIR="$TMP_DIR/logs"
V4L2_DEVICE="$TMP_DIR/v4l2/video42"
MIC_SINK_NAME=PhoneMicSink
MIC_SOURCE_NAME=PhoneMic
PID_WEBCAM="$RUN_DIR/webcam.pid"
PID_MIC="$RUN_DIR/mic.pid"
PID_ROUTE="$RUN_DIR/route.pid"
PID_AGENT="$RUN_DIR/agent.pid"
touch "$V4L2_DEVICE"
printf '%s\n' "PHONECAM_LANG=en" > "$CONF_FILE"
load_config

pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# Real capture cycles: assert lifecycle, command contract, idempotence and cleanup.
mic_line(){ awk '/--no-video/ { line = $0 } END { print line }' "$SCRCPY_LOG"; }
check 'webcam starts' start_webcam
check 'webcam pidfile identifies active process' is_running "$PID_WEBCAM"
check 'webcam source is camera' grep -q -- '--video-source=camera' "$SCRCPY_LOG"
check 'webcam forwards V4L2 sink' grep -q -- "--v4l2-sink=$V4L2_DEVICE" "$SCRCPY_LOG"
second="$(start_webcam 2>&1)"; check 'webcam start is idempotent' grep -qi 'already active' <<<"$second"
check 'webcam stop returns success' stop_webcam_only
check 'webcam pidfile removed' test ! -f "$PID_WEBCAM"

stop_webcam_only >/dev/null 2>&1
ORIGINAL_PREPARE_LOG=$(declare -f prepare_log_file)
prepare_log_file(){ atomic_write_file "$1" 600 </dev/null && printf '%s\n' prepared-before-redirection >> "$1"; }
check 'webcam starts with atomic log preparation hook' start_webcam
check 'webcam log keeps atomically prepared content' grep -Fxq 'prepared-before-redirection' "$LOG_DIR/webcam.log"
stop_webcam_only >/dev/null 2>&1
unset -f prepare_log_file
eval "$ORIGINAL_PREPARE_LOG"

check 'microphone starts' start_mic
check 'microphone pidfile identifies active process' is_running "$PID_MIC"
for _ in $(seq 1 50); do grep -q '^move-sink-input 44 PhoneMicSink$' "$PACTL_LOG" && break; /bin/sleep 0.1; done
check 'microphone audio is routed to the virtual sink' grep -q '^move-sink-input 44 PhoneMicSink$' "$PACTL_LOG"
check 'microphone disables video' grep -q -- '--no-video' "$SCRCPY_LOG"
check 'microphone requires audio' grep -q -- '--require-audio' "$SCRCPY_LOG"
check 'microphone selects requested audio source' grep -q -- '--audio-source=mic' "$SCRCPY_LOG"
check 'microphone never enables phone control' grep -q -- '--no-control' <<<"$(mic_line)"
check 'microphone opens no window on scrcpy 2.5 or newer' grep -q -- '--no-window' <<<"$(mic_line)"
check 'microphone stop returns success' stop_mic_only
check 'microphone pidfile removed' test ! -f "$PID_MIC"
check 'audio route pidfile cleaned' test ! -f "$PID_ROUTE"

# scrcpy 2.3.1-2.4 reject --no-window and open no window without video: the microphone must still start there.
export SCRCPY_VERSION=2.4; : > "$SCRCPY_LOG"
check 'microphone starts on scrcpy 2.4' start_mic
if grep -q -- '--no-window' <<<"$(mic_line)"; then bad 'microphone omits --no-window before scrcpy 2.5'; else ok 'microphone omits --no-window before scrcpy 2.5'; fi
check 'microphone disables phone control on scrcpy 2.4' grep -q -- '--no-control' <<<"$(mic_line)"
stop_mic_only >/dev/null 2>&1; unset SCRCPY_VERSION

# Every audio source but plain "mic" needs scrcpy 3.2: older versions are refused before ADB, the audio devices or scrcpy are touched.
AUDIO_SOURCE=mic-camcorder; export SCRCPY_VERSION=3.1; : > "$SCRCPY_LOG"; : > "$PACTL_LOG"
check 'audio_source_supported accepts plain mic on scrcpy 3.1' audio_source_supported mic
if audio_source_supported voice-call; then bad 'audio_source_supported refuses voice sources on scrcpy 3.1'; else ok 'audio_source_supported refuses voice sources on scrcpy 3.1'; fi
real_adb_serial="$(declare -f adb_serial)"
adb_serial(){ : > "$TMP_DIR/adb-touched"; printf '%s\n' SERIAL1; }
if refused_out="$(start_mic 2>&1)"; then bad 'microphone start fails for mic-camcorder on scrcpy 3.1'; else ok 'microphone start fails for mic-camcorder on scrcpy 3.1'; fi
unset -f adb_serial
eval "$real_adb_serial"
check 'refusal message names scrcpy 3.2' grep -q 'scrcpy 3\.2' <<<"$refused_out"
check 'refusal message names the unsupported source' grep -q 'mic-camcorder' <<<"$refused_out"
check 'refusal message links the scrcpy releases' grep -q 'Genymobile/scrcpy/releases' <<<"$refused_out"
check 'refusal launches no scrcpy' test ! -s "$SCRCPY_LOG"
check 'refusal leaves no microphone pidfile' test ! -f "$PID_MIC"
check 'refusal happens before ADB and the audio devices' test ! -e "$TMP_DIR/adb-touched" -a ! -s "$PACTL_LOG"
stop_mic_only >/dev/null 2>&1
export SCRCPY_VERSION=3.2
check 'audio_source_supported accepts mic-camcorder on scrcpy 3.2' audio_source_supported mic-camcorder
check 'microphone starts with mic-camcorder on scrcpy 3.2' start_mic
check 'microphone passes the extra audio source to scrcpy 3.2' grep -q -- '--audio-source=mic-camcorder' <<<"$(mic_line)"
stop_mic_only >/dev/null 2>&1; unset SCRCPY_VERSION; AUDIO_SOURCE=mic

# Combined mode has its own success contract: both captures must start and stop together.
check 'combined mode starts both captures' start_both
check 'combined mode has both pidfiles' test -f "$PID_WEBCAM" -a -f "$PID_MIC"
check 'combined mode records camera source' grep -q -- '--video-source=camera' "$SCRCPY_LOG"
check 'combined mode records audio source' grep -q -- '--audio-source=mic' "$SCRCPY_LOG"
check 'stop_all stops combined capture' stop_all
check 'combined mode pidfiles are removed' test ! -f "$PID_WEBCAM" -a ! -f "$PID_MIC"

# Several phones and a graphical session: combined mode asks once and both captures use that phone.
cat > "$TMP_DIR/bin/zenity" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$ZENITY_LOG"
[ "${ZENITY_PICK:-}" = cancel ] && exit 1
case "$*" in *--hide-column*) [ -z "${ZENITY_MODE:-}" ] || { printf '%s\n' "$ZENITY_MODE"; exit 0; } ;; esac
printf 'SERIAL%s\n' "$(wc -l < "$ZENITY_LOG")"
SH
export ZENITY_LOG="$TMP_DIR/zenity.log"; ADB_STATE=multi; : > "$ZENITY_LOG"; : > "$SCRCPY_LOG"
asked(){ grep -c -- '--list' "$ZENITY_LOG" || :; }
DISPLAY=:0 start_both >/dev/null 2>&1
check 'combined mode asks for the phone once' test "$(asked)" -eq 1
check 'combined mode captures video and audio from one phone' test "$(grep -oE '^-s [A-Z0-9]+' "$SCRCPY_LOG" | sort -u | wc -l)" -eq 1
DISPLAY=:0 start_both >/dev/null 2>&1
check 'combined mode asks nothing when both captures already run' test "$(asked)" -eq 1
stop_all >/dev/null 2>&1; : > "$ZENITY_LOG"
if ZENITY_PICK=cancel DISPLAY=:0 start_both >/dev/null 2>&1; then bad 'a cancelled phone choice fails combined mode'; else ok 'a cancelled phone choice fails combined mode'; fi
check 'a cancelled phone choice is asked once' test "$(asked)" -eq 1
check 'a cancelled phone choice starts no capture' test ! -f "$PID_WEBCAM" -a ! -f "$PID_MIC"
: > "$ZENITY_LOG"; : > "$SCRCPY_LOG"
DISPLAY=:0 start_webcam SERIAL2 >/dev/null 2>&1; DISPLAY=:0 start_mic SERIAL2 >/dev/null 2>&1
check 'the webcam start uses the phone it is given' grep -Eq -- '^-s SERIAL2 .*--video-source=camera' "$SCRCPY_LOG"
check 'the microphone start uses the phone it is given' grep -Eq -- '^-s SERIAL2 .*--no-video' "$SCRCPY_LOG"
check 'a given phone is not asked about again' test "$(asked)" -eq 0
# The agent hands the phone it follows to every start: with two phones it must not ask again, nor pick another one.
phones_used(){ grep -oE '^-s [A-Z0-9]+' "$SCRCPY_LOG" | sort -u | tr '\n' ' ' || :; }
stop_all >/dev/null 2>&1; : > "$ZENITY_LOG"; : > "$SCRCPY_LOG"
for mode in webcam mic both; do AUTO_MODE=$mode DISPLAY=:0 agent_handle_new_device SERIAL2 >/dev/null 2>&1 || :; stop_all >/dev/null 2>&1; done
check 'automatic agent modes ask nothing' test "$(asked)" -eq 0
check 'automatic agent modes use the phone the agent follows' test "$(phones_used)" = '-s SERIAL2 '
dialog_asked=""; dialog_serials=""
for mode in webcam mic both; do
  : > "$ZENITY_LOG"; : > "$SCRCPY_LOG"
  ZENITY_MODE=$mode AUTO_MODE=ask DISPLAY=:0 agent_handle_new_device SERIAL2 >/dev/null 2>&1 || :; wait $! || :
  dialog_asked+="$(asked) "; dialog_serials+="$(phones_used)"; stop_all >/dev/null 2>&1
done
check 'agent asks only for the mode, not for the phone again' test "$dialog_asked" = '1 1 1 '
check 'each mode chosen in the agent dialog uses the phone it showed' test "$dialog_serials" = '-s SERIAL2 -s SERIAL2 -s SERIAL2 '
stop_all >/dev/null 2>&1; ADB_STATE=connected; printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/zenity"

# Combined start must fail if one independently required component fails.
real_webcam="$(declare -f start_webcam)"
real_mic="$(declare -f start_mic)"
start_webcam(){ return 1; }
start_mic(){ return 0; }
if start_both >/dev/null 2>&1; then bad 'both propagates component failure'; else ok 'both propagates component failure'; fi
unset -f start_webcam start_mic
eval "$real_webcam"
eval "$real_mic"

# A capture that died by itself leaves a stale pidfile and the keep-awake override on the phone: both stop paths must clear them.
died(){ kill "$1"; for _ in $(seq 1 50); do is_running "$2" || return 0; /bin/sleep 0.1; done; return 1; }
KEEP_AWAKE=true
start_webcam >/dev/null 2>&1; dead_pid="$(pidfile_pid "$PID_WEBCAM")"
check 'keep-awake override is set while the webcam runs' grep -Fxq 7 "$ADB_STATE_FILE"
check 'webcam process ends on its own' died "$dead_pid" "$PID_WEBCAM"
stale_out="$(stop_webcam_only 2>&1)"
check 'stop_webcam_only reports a webcam whose process already ended' grep -q 'was not active' <<<"$stale_out"
check 'stop_webcam_only removes a stale webcam pidfile' test ! -f "$PID_WEBCAM"
check 'stop_webcam_only restores keep-awake after the process ended' grep -Fxq 0 "$ADB_STATE_FILE"
check 'stop_webcam_only clears the keep-awake saved value' test ! -f "$RUN_DIR/keepawake.saved"
start_mic >/dev/null 2>&1; dead_pid="$(pidfile_pid "$PID_MIC")"
check 'microphone process ends on its own' died "$dead_pid" "$PID_MIC"
stale_out="$(stop_mic_only 2>&1)"
check 'stop_mic_only reports a microphone whose process already ended' grep -q 'was not active' <<<"$stale_out"
check 'stop_mic_only removes a stale microphone pidfile' test ! -f "$PID_MIC"
check 'stop_mic_only restores keep-awake after the process ended' grep -Fxq 0 "$ADB_STATE_FILE"

# A stale pidfile with a live unrelated process must never be killed.
/bin/sleep 30 & unrelated=$!
unrelated_start="$(proc_start_time "$unrelated")"
printf '%s %s\n' "$unrelated" "$unrelated_start" > "$PID_ROUTE"
check 'stale route pid does not kill unrelated process' stop_all
check 'stale route process remains alive after stop_all' kill -0 "$unrelated"
kill "$unrelated" 2>/dev/null || true
wait "$unrelated" 2>/dev/null || true

# A stop must never delete the pidfile of a capture started while it was still terminating the previous one: the hook lets the
# old scrcpy die and then starts a new capture, exactly where a concurrent start would land.
terminate_def="$(declare -f terminate_pid)"
eval "${terminate_def/terminate_pid/real_terminate_pid}"
RACE_RAN="$TMP_DIR/race-ran"
race_hook(){ real_terminate_pid "$@"; [ -e "$RACE_RAN" ] && return 0; : > "$RACE_RAN"; "$RACE_START" >/dev/null 2>&1; }
race_check(){
  local old_pid
  RACE_START="$2"; rm -f "$RACE_RAN"
  "$2" >/dev/null 2>&1; old_pid="$(pidfile_pid "$3")"
  terminate_pid(){ race_hook "$@"; }
  "$1" >/dev/null 2>&1
  unset -f terminate_pid; eval "$terminate_def"
  is_running "$3" && [ "$(pidfile_pid "$3")" != "$old_pid" ]
}
check 'stop_webcam_only keeps the pidfile of a webcam started while it was stopping' race_check stop_webcam_only start_webcam "$PID_WEBCAM"
stop_all >/dev/null 2>&1
check 'stop_mic_only keeps the pidfile of a microphone started while it was stopping' race_check stop_mic_only start_mic "$PID_MIC"
stop_all >/dev/null 2>&1
check 'stop_all keeps the pidfile of a webcam started while it was stopping' race_check stop_all start_webcam "$PID_WEBCAM"
stop_all >/dev/null 2>&1

# stop_pidfile_process contract: nothing recorded, a matching process, and a process the matcher rejects.
gone(){ ! grep -qs '^State:[[:space:]]*[^Z[:space:]]' "/proc/$1/status"; }
if stop_pidfile_process "$PID_WEBCAM" is_running; then bad 'stop_pidfile_process fails when no pidfile exists'; else ok 'stop_pidfile_process fails when no pidfile exists'; fi
start_webcam >/dev/null 2>&1; helper_pid="$(pidfile_pid "$PID_WEBCAM")"
check 'stop_pidfile_process stops the process a matching pidfile records' stop_pidfile_process "$PID_WEBCAM" is_running
check 'stop_pidfile_process leaves that process gone' gone "$helper_pid"
check 'stop_pidfile_process leaves neither pidfile nor claim behind' bash -c '[ ! -e "$1" ] && ! compgen -G "$2/*.pid.*" >/dev/null' _ "$PID_WEBCAM" "$RUN_DIR"
/bin/sleep 30 & unrelated=$!
printf '%s %s\n' "$unrelated" "$(proc_start_time "$unrelated")" > "$PID_WEBCAM"
if stop_pidfile_process "$PID_WEBCAM" is_running; then bad 'stop_pidfile_process refuses a process the matcher rejects'; else ok 'stop_pidfile_process refuses a process the matcher rejects'; fi
check 'stop_pidfile_process leaves a rejected process running' kill -0 "$unrelated"
check 'stop_pidfile_process still removes the rejected pidfile' test ! -e "$PID_WEBCAM"
kill "$unrelated" 2>/dev/null || true
wait "$unrelated" 2>/dev/null || true

# scrcpy reports a busy v4l2 device or rejected camera settings a moment after launch: a start whose process dies within
# PHONECAM_START_GRACE must fail, say why, leave no pidfile and leave the phone's keep-awake setting alone.
export PHONECAM_START_GRACE=1 SCRCPY_EXIT_AFTER=0.5; KEEP_AWAKE=true; printf '%s\n' 0 > "$ADB_STATE_FILE"; : > "$PACTL_LOG"; rm -f "$RUN_DIR/keepawake.saved"
rc=0; early_out="$(start_webcam 2>&1)" || rc=$?
check 'webcam start fails when scrcpy dies right after launch' test "$rc" -ne 0
check 'early death message says scrcpy did not start' grep -q 'did not start correctly' <<<"$early_out"
check 'early death message quotes the scrcpy error' grep -q 'Could not open video device' <<<"$early_out"
check 'early death never announces the webcam as active' bash -c '! grep -q "is active" <<<"$1"' _ "$early_out"
check 'early death leaves no webcam pidfile' test ! -f "$PID_WEBCAM"
check 'early death leaves the phone keep-awake setting alone' grep -Fxq 0 "$ADB_STATE_FILE"
check 'early death saves no keep-awake value' test ! -f "$RUN_DIR/keepawake.saved"
rc=0; early_out="$(start_mic 2>&1)" || rc=$?
check 'microphone start fails when scrcpy dies right after launch' test "$rc" -ne 0
check 'early microphone death leaves no microphone pidfile' test ! -f "$PID_MIC"
check 'early microphone death starts no audio route' test ! -f "$PID_ROUTE"
check 'early microphone death routes no audio' bash -c '! grep -q "^move-sink-input" "$1"' _ "$PACTL_LOG"
check 'early microphone death leaves the phone keep-awake setting alone' grep -Fxq 0 "$ADB_STATE_FILE"
check 'early microphone death saves no keep-awake value' test ! -f "$RUN_DIR/keepawake.saved"
for grace in abc 08; do
  rc=0; PHONECAM_START_GRACE=$grace start_webcam >/dev/null 2>&1 || rc=$?
  check "grace value '$grace' is normalized and still detects an early death" test "$rc" -ne 0
done
rc=0; PHONECAM_START_GRACE=0 start_webcam >/dev/null 2>&1 || rc=$?
check 'a grace of 0 skips the post-launch check' test "$rc" -eq 0
stop_all >/dev/null 2>&1
unset SCRCPY_EXIT_AFTER
check 'webcam that survives the grace period starts' start_webcam
check 'webcam is still registered after the grace period' is_running "$PID_WEBCAM"
stop_all >/dev/null 2>&1
# A stop that lands inside the grace period ends the start quietly and kills what it launched.
export PHONECAM_START_GRACE=3
( start_webcam >"$TMP_DIR/mid.out" 2>&1 ) & mid_job=$!
for _ in $(seq 1 50); do [ -f "$PID_WEBCAM" ] && break; /bin/sleep 0.05; done
mid_scrcpy="$(pidfile_pid "$PID_WEBCAM")"; /bin/sleep 0.5; stop_webcam_only >/dev/null 2>&1
mid_rc=0; wait "$mid_job" || mid_rc=$?
check 'a stop inside the grace period ends the start with failure' test "$mid_rc" -ne 0
check 'a stop inside the grace period raises no start error' bash -c '! grep -q "did not start" "$1"' _ "$TMP_DIR/mid.out"
check 'a stop inside the grace period leaves no webcam pidfile' test ! -f "$PID_WEBCAM"
check 'a stop inside the grace period kills the launched scrcpy' gone "$mid_scrcpy"
export PHONECAM_START_GRACE=0

# A phone unplugged during a capture keeps the keep-awake override (the restore cannot reach it): the agent must restore it
# once the phone is back, and must leave it alone while a capture runs.
watch_phone(){
  ( agent_current_device(){ printf 'SERIAL1\n'; }; agent_handle_new_device(){ :; }; load_config(){ :; }
    sleep(){ /bin/sleep 0.1; }; agent_watcher_loop ) & watch_job=$!
  for _ in $(seq 1 "$2"); do grep -Fxq "$1" "$ADB_STATE_FILE" && break; /bin/sleep 0.1; done
  kill "$watch_job" 2>/dev/null; wait "$watch_job" 2>/dev/null
  grep -Fxq "$1" "$ADB_STATE_FILE"
}
KEEP_AWAKE=true; AUTO_MODE=off; printf '%s\n' 0 > "$ADB_STATE_FILE"
start_webcam >/dev/null 2>&1
ADB_STATE=none agent_handle_removed_device
check 'unplugging the phone leaves the keep-awake override in place' grep -Fxq 7 "$ADB_STATE_FILE"
check 'unplugging the phone keeps the value to restore' test -f "$RUN_DIR/keepawake.saved"
check 'agent restores the keep-awake override once the phone is back' watch_phone 0 30
check 'agent clears the saved keep-awake value after restoring it' test ! -f "$RUN_DIR/keepawake.saved"
start_webcam >/dev/null 2>&1
if watch_phone 0 12; then bad 'agent leaves the keep-awake override alone while a capture runs'; else ok 'agent leaves the keep-awake override alone while a capture runs'; fi
stop_all >/dev/null 2>&1

# The graphical menu runs each action in a subshell: what "choose camera" and "advanced settings" save must reach the webcam started next.
cat > "$TMP_DIR/bin/zenity" <<'SH'
#!/bin/sh
case "$*" in
  *--hide-column*) IFS= read -r pick < "$MENU_SEQ"; tail -n +2 "$MENU_SEQ" > "$MENU_SEQ.tmp"; mv "$MENU_SEQ.tmp" "$MENU_SEQ"; printf '%s\n' "$pick" ;;
  *--forms*) printf '%s\n' 'back||60|balanced|mic|opus||ask|false|true' ;;
  *--list*) printf '%s\n' 1 ;;
esac
SH
export MENU_SEQ="$TMP_DIR/menu.seq"; printf '%s\n' choose_cam config webcam_start exit > "$MENU_SEQ"
CAMERA_ID=""; CAMERA_FPS=30; : > "$SCRCPY_LOG"
menu_session(){ DISPLAY=:0 gui_menu >/dev/null 2>&1; }
check 'menu session with a camera and frame-rate change ends cleanly' menu_session
check 'menu session stores the chosen camera id' grep -Fxq "CAMERA_ID='1'" "$CONF_FILE"
check 'menu session stores the chosen frame rate' grep -Fxq "CAMERA_FPS='60'" "$CONF_FILE"
check 'webcam started from the menu uses the camera chosen in the same session' grep -Eq -- '--camera-id=1( |$)' "$SCRCPY_LOG"
check 'webcam started from the menu uses the frame rate set in the same session' grep -Eq -- '--camera-fps=60( |$)' "$SCRCPY_LOG"
stop_all >/dev/null 2>&1

# The first adb call of a start or of a keep-awake change may start the adb server. That daemon must not inherit the lock fds:
# it would hold the lock for as long as it runs and every later start would answer "another start in progress".
lock_free(){ bash -c 'exec 9>>"$1" && flock -n 9' _ "$1"; }
spawn_adb_daemon(){ [ ! -s "$ADB_SPAWN_DAEMON" ] || kill "$(cat "$ADB_SPAWN_DAEMON")" 2>/dev/null || true; rm -f "$ADB_SPAWN_DAEMON"; }
export ADB_SPAWN_DAEMON="$TMP_DIR/adb-daemon.pid"; KEEP_AWAKE=true; PHONECAM_START_GRACE=0
rm -f "$ADB_SPAWN_DAEMON"; ( exec 9>>"$RUN_DIR/probe.lock"; flock -n 9; adb_run 5 start-server )
check 'the simulated adb daemon is spawned by the first adb call' test -s "$ADB_SPAWN_DAEMON"
check 'adb_run keeps the caller lock out of the adb server it starts' lock_free "$RUN_DIR/probe.lock"
spawn_adb_daemon; start_webcam >/dev/null 2>&1; stop_webcam_only >/dev/null 2>&1
check 'a webcam start leaves the start lock free of the adb server' lock_free "$RUN_DIR/webcam.lock"
check 'a second webcam start is not refused by a lock the adb server holds' start_webcam
stop_all >/dev/null 2>&1
spawn_adb_daemon; start_mic >/dev/null 2>&1; stop_mic_only >/dev/null 2>&1
check 'a microphone start leaves the start lock free of the adb server' lock_free "$RUN_DIR/mic.lock"
spawn_adb_daemon; printf '%s\n' 'SERIAL1 0' > "$RUN_DIR/keepawake.saved"; printf '%s\n' 7 > "$ADB_STATE_FILE"
phone_keep_awake_stop
check 'a keep-awake restore leaves its lock free of the adb server' lock_free "$RUN_DIR/keepawake.lock"
check 'a keep-awake restore through a fresh adb server still reaches the phone' grep -Fxq 0 "$ADB_STATE_FILE"
spawn_adb_daemon; unset ADB_SPAWN_DAEMON

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
