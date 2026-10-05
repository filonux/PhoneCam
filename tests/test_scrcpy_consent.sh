#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" SCRIPT
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
unset DISPLAY WAYLAND_DISPLAY
source "$SCRIPT"
CURRENT_LANG=en

command -v script >/dev/null 2>&1 || { echo 'not ok - util-linux script(1) is required to allocate a pseudo-terminal' >&2; exit 1; }

# run_agent_action/run_gui_action capture the command output, so a terminal prompt raised
# inside them would be invisible. They give it stdin from /dev/null, so [ -t 0 ] is false
# and no prompt is raised. The probe runs on a pseudo-terminal and records what is asked.
cat > "$TMP_DIR/probe.sh" <<'EOF_PROBE'
set -uo pipefail
source "$SCRIPT"
CURRENT_LANG=en
ask_yn(){ echo "ASK_YN"; return 1; }
check_scrcpy_version(){ return 1; }
notify(){ echo "NOTIFY: $2"; }
zenity(){ echo "ZENITY: $*"; return 1; }
case "$1" in
    agent)  run_agent_action ensure_scrcpy_installed ;;
    gui)    run_gui_action ensure_scrcpy_installed ;;
    direct) ensure_scrcpy_installed ;;
esac
echo "rc=$?"
EOF_PROBE

on_tty(){ timeout 20 script -qec "bash '$TMP_DIR/probe.sh' $1" /dev/null </dev/null | tr -d '\r'; }

pass=0
fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

no_prompt="$(t SCRCPY_NO_PROMPT "$(basename "$SELF_PATH")")"
cancelled="$(t SCRCPY_CANCELLED)"

direct="$(on_tty direct)"
check 'control: without a wrapper the terminal prompt is reached' grep -Fxq ASK_YN <<<"$direct"

agent="$(on_tty agent)"
check 'agent action never prompts on the terminal' bash -c '! grep -Fxq ASK_YN <<<"$1"' _ "$agent"
check 'agent action reports the missing consent channel' grep -Fq "$no_prompt" <<<"$agent"

gui="$(on_tty gui)"
check 'gui action never prompts on the terminal' bash -c '! grep -Fxq ASK_YN <<<"$1"' _ "$gui"
check 'gui action shows the missing consent channel in a dialog' grep -Fq "ZENITY: --error" <<<"$gui"
check 'gui action dialog carries the reason' grep -Fq "$no_prompt" <<<"$gui"

export DISPLAY=:99
agent_gui="$(on_tty agent)"
check 'with a display the agent asks through a dialog instead' grep -Fq 'ZENITY: --question' <<<"$agent_gui"
check 'declining the dialog cancels the download' grep -Fq "$cancelled" <<<"$agent_gui"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
