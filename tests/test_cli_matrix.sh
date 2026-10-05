#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
export RUN_DIR="$TMP_DIR/run/phonecam" LOG_DIR="$TMP_DIR/logs"
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
export CONF_DIR CONF_FILE
mkdir -p "$CONF_DIR" "$RUN_DIR" "$LOG_DIR"

source "$SCRIPT"

CALL_LOG="$TMP_DIR/calls.log"
: > "$CALL_LOG"
record(){ printf '%s\n' "$*" >> "$CALL_LOG"; }

# Replace side-effecting commands so this suite tests main() dispatch semantics.
load_config(){ record load_config; }
load_language_preference(){ record load_language_preference; }
cmd_install(){ record "cmd_install:$NONINTERACTIVE"; return 0; }
cmd_uninstall(){ record cmd_uninstall; return 0; }
gui_menu(){ record gui_menu; return 0; }
start_webcam(){ record start_webcam; return 0; }
start_mic(){ record start_mic; return 0; }
start_both(){ record start_both; return 0; }
stop_all(){ record stop_all; return 0; }
status(){ record status; return 0; }
list_cameras(){ record list_cameras; return 0; }
choose_camera_gui(){ record choose_camera_gui; return 0; }
open_config_editor(){ record open_config_editor; return 0; }
toggle_language(){ record toggle_language; return 0; }
show_connection_help(){ record show_connection_help; return 0; }
run_agent(){ record run_agent; return 0; }
usage(){ record usage; return 0; }

# tray-status/tray-exit are inline in main(), not delegated to a stubbed
# function, so they need their own fake yad/systemctl/kill.
YAD_LOG="$TMP_DIR/yad.log" SYSTEMCTL_LOG="$TMP_DIR/systemctl.log" KILL_LOG="$TMP_DIR/kill.log"
: > "$YAD_LOG"; : > "$SYSTEMCTL_LOG"; : > "$KILL_LOG"
yad(){ printf '%s\n' "$*" >> "$YAD_LOG"; }
systemctl(){ printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"; return "${SYSTEMCTL_RC:-0}"; }
kill(){ printf '%s\n' "$*" >> "$KILL_LOG"; }

pass=0
fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
assert_dispatch(){
    local cmd="$1" expected="$2"; shift 2
    : > "$CALL_LOG"
    main "$cmd" "$@"
    grep -Fxq "$expected" "$CALL_LOG"
}

check 'install dispatch' assert_dispatch install 'load_language_preference'
check 'install default is interactive' grep -Fxq 'cmd_install:0' "$CALL_LOG"
: > "$CALL_LOG"; main install --yes
check 'install --yes enables noninteractive mode' grep -Fxq 'cmd_install:1' "$CALL_LOG"
check 'uninstall dispatch' assert_dispatch uninstall 'load_config'
check 'uninstall handler invoked' grep -Fxq 'cmd_uninstall' "$CALL_LOG"
check 'menu dispatch' assert_dispatch menu gui_menu
check 'webcam dispatch' assert_dispatch webcam start_webcam
check 'mic dispatch' assert_dispatch mic start_mic
check 'both dispatch' assert_dispatch both start_both
check 'stop dispatch' assert_dispatch stop stop_all
check 'status dispatch' assert_dispatch status status
check 'cameras dispatch' assert_dispatch cameras list_cameras
check 'choose-cam dispatch' assert_dispatch choose-cam choose_camera_gui
check 'config dispatch' assert_dispatch config open_config_editor
check 'l dispatch' assert_dispatch l toggle_language
check 'lang dispatch' assert_dispatch lang toggle_language
check 'language dispatch' assert_dispatch language toggle_language
check 'help-connection dispatch' assert_dispatch help-connection show_connection_help
check 'ayuda dispatch' assert_dispatch ayuda show_connection_help
check 'help-conexion dispatch' assert_dispatch help-conexion show_connection_help
check 'agent dispatch' assert_dispatch agent run_agent

: > "$CALL_LOG"; : > "$YAD_LOG"; main tray-status
check 'tray-status dispatch' grep -Fxq status "$CALL_LOG"
check 'tray-status opens yad text-info' grep -Fq -- '--text-info' "$YAD_LOG"

SYSTEMCTL_RC=0; : > "$SYSTEMCTL_LOG"; : > "$KILL_LOG"; main tray-exit
check 'tray-exit stops the user service' grep -Fxq -- '--user stop phonecam-agent.service' "$SYSTEMCTL_LOG"
check 'tray-exit skips kill when systemctl succeeds and no agent is alive' test ! -s "$KILL_LOG"

# systemctl stop returns 0 for a loaded-but-inactive unit; an agent started by hand must still stop.
SYSTEMCTL_RC=0; write_pidfile "$PID_AGENT" $$; : > "$KILL_LOG"; main tray-exit
check 'tray-exit stops an agent running outside systemd even when systemctl succeeds' grep -Fxq "$$" "$KILL_LOG"

SYSTEMCTL_RC=1; write_pidfile "$PID_AGENT" $$; : > "$SYSTEMCTL_LOG"; : > "$KILL_LOG"; main tray-exit
check 'tray-exit falls back to kill when systemctl fails' grep -Fxq "$$" "$KILL_LOG"

# A stale or foreign pidfile must never turn tray-exit into a kill of an unrelated process.
printf '%s 0\n' "$$" > "$PID_AGENT"; : > "$KILL_LOG"; tray_rc=0; main tray-exit || tray_rc=$?
check 'tray-exit fails when the pidfile is stale' test "$tray_rc" -ne 0
check 'tray-exit ignores a pidfile whose start time no longer matches' bash -c '! grep -Fxq -- "$1" "$2"' _ "$$" "$KILL_LOG"
/bin/sleep 30 & other=$!; printf '%s %s\n' "$other" "$(proc_start_time "$other")" > "$PID_AGENT"; : > "$KILL_LOG"; tray_rc=0; main tray-exit || tray_rc=$?
check 'tray-exit fails when the pidfile belongs to another program' test "$tray_rc" -ne 0
check 'tray-exit ignores a live pidfile that belongs to another program' bash -c '! grep -Fxq -- "$1" "$2"' _ "$other" "$KILL_LOG"
builtin kill "$other" 2>/dev/null || true; wait "$other" 2>/dev/null || true

: > "$CALL_LOG"; main version >"$TMP_DIR/version.out"
check 'version prints current version' grep -Fq "PhoneCam $PHONECAM_VERSION" "$TMP_DIR/version.out"
: > "$CALL_LOG"; main --version >"$TMP_DIR/version2.out"
check '--version prints current version' grep -Fq "PhoneCam $PHONECAM_VERSION" "$TMP_DIR/version2.out"
for h in -h --help help; do
    : > "$CALL_LOG"; main "$h"
    check "$h loads language preference" grep -Fxq load_language_preference "$CALL_LOG"
    check "$h dispatches usage" grep -Fxq usage "$CALL_LOG"
done

# Unknown command is handled by a child process because main() exits 1.
set +e
bash "$SCRIPT" definitely-not-a-command >"$TMP_DIR/unknown.out" 2>&1
rc=$?
set -e
check 'unknown command returns failure' test "$rc" -eq 1
check 'unknown command reports error' grep -Fq 'Unknown command' "$TMP_DIR/unknown.out"
printf "PHONECAM_LANG='es'\n" > "$CONF_FILE"
LC_ALL=C bash "$SCRIPT" definitely-not-a-command >"$TMP_DIR/unknown-es.out" 2>&1 || rc=$?
check 'unknown command error uses the saved language' grep -Fq 'Comando desconocido' "$TMP_DIR/unknown-es.out"
check 'unknown command usage uses the saved language' grep -Fq 'usa tu Android' "$TMP_DIR/unknown-es.out"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
