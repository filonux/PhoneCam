#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" SCRIPT
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
unset DISPLAY WAYLAND_DISPLAY

source "$SCRIPT"
CURRENT_LANG=en
mkdir -p "$RUN_DIR"

pass=0
fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
check_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
gone(){ ! kill -0 "$1" 2>/dev/null; }
# Run code in a fresh shell that has sourced the script; $2.. are its positional args.
in_child(){ local code="$1"; shift; bash -c 'source "$SCRIPT"; CURRENT_LANG=en; '"$code" _ "$@"; }

# ---------- agent_claim ----------------------------------------------------------
rm -f "$PID_AGENT"
rc=0; agent_claim || rc=$?
check_eq 'agent_claim succeeds when no agent is running' "$rc" 0
check_eq 'agent_claim records the calling shell as the agent' "$(pidfile_pid "$PID_AGENT")" "$BASHPID"

check 'agent_claim leaves no lock held afterwards' bash -c 'exec 5>>"$1" && flock -n 5' _ "$RUN_DIR/agent.lock"

rc=0; agent_claim || rc=$?
check_eq 'agent_claim lets the current owner claim again' "$rc" 0

/bin/sleep 300 & live=$!
write_pidfile "$PID_AGENT" "$live"
rc=0; agent_claim || rc=$?
check_eq 'agent_claim refuses while another agent is alive' "$rc" 2
check_eq 'agent_claim keeps the live agent recorded' "$(pidfile_pid "$PID_AGENT")" "$live"

printf '%s 1\n' "$live" > "$PID_AGENT"
rc=0; agent_claim || rc=$?
check_eq 'agent_claim ignores a pidfile whose start time differs' "$rc" 0

/bin/sleep 300 & dead=$!
write_pidfile "$PID_AGENT" "$dead"
kill "$dead"; wait "$dead" 2>/dev/null || true
rc=0; agent_claim || rc=$?
check_eq 'agent_claim replaces the pidfile of a dead agent' "$rc" 0
check_eq 'agent_claim records itself over the dead agent' "$(pidfile_pid "$PID_AGENT")" "$BASHPID"

# Six real processes race for the slot; the winner stays alive so the others must lose.
rm -f "$PID_AGENT"
racers=()
for i in 1 2 3 4 5 6; do
    in_child 'rc=0; agent_claim || rc=$?; printf "%s\n" "$rc" > "$1"; /bin/sleep 2' "$TMP_DIR/race.$i" &
    racers+=("$!")
done
for pid in "${racers[@]}"; do wait "$pid"; done
check_eq 'concurrent claims produce exactly one winner' "$(cat "$TMP_DIR"/race.* | grep -c '^0$')" 1
check_eq 'concurrent claims make every loser report exit 2' "$(cat "$TMP_DIR"/race.* | grep -c '^2$')" 5

# ---------- run_agent ----------------------------------------------------------
STUBS='agent_tray_icon(){ echo TRAY; }; agent_watcher_loop(){ printf "LOOP %s %s\n" "$BASHPID" "$(pidfile_pid "$PID_AGENT")"; }; '
write_pidfile "$PID_AGENT" "$live"
out="$(in_child "$STUBS"'run_agent; echo "rc=$?"')"
check 'run_agent announces that another agent is running' grep -Fq "$(t AGENT_ALREADY)" <<<"$out"
check 'run_agent returns 0 so systemd does not restart-loop' grep -Fxq 'rc=0' <<<"$out"
check 'run_agent starts neither tray nor watcher when refused' bash -c '! grep -Eq "^(TRAY|LOOP)" <<<"$1"' _ "$out"
check_eq 'run_agent leaves the live agent recorded when refused' "$(pidfile_pid "$PID_AGENT")" "$live"

rm -f "$PID_AGENT"
out="$(in_child "$STUBS"'run_agent; echo "rc=$?"')"
check 'run_agent starts tray and watcher when it owns the slot' bash -c 'grep -Fxq TRAY <<<"$1" && grep -Eq "^LOOP [0-9]+ [0-9]+$" <<<"$1"' _ "$out"
read -r _ loop_pid recorded <<<"$(grep '^LOOP ' <<<"$out")"
check_eq 'run_agent registers its own pid before the watcher loop' "$recorded" "$loop_pid"
check 'run_agent removes its pidfile on exit' test ! -e "$PID_AGENT"

# ---------- agent_cleanup / agent_tray_stop --------------------------------------
write_pidfile "$PID_AGENT" "$live"
in_child 'agent_cleanup'
check_eq 'agent_cleanup keeps a pidfile owned by another agent' "$(pidfile_pid "$PID_AGENT")" "$live"
in_child 'write_pidfile "$PID_AGENT" "$BASHPID"; agent_cleanup'
check 'agent_cleanup removes the pidfile it owns' test ! -e "$PID_AGENT"

/bin/sleep 300 & TRAY_PID=$!
tray=$TRAY_PID
until [ "$(cat "/proc/$tray/comm" 2>/dev/null)" = sleep ]; do /bin/sleep 0.01; done   # a signal that lands before the exec is lost
agent_tray_stop
wait "$tray" 2>/dev/null || true
check 'agent_tray_stop terminates the tray process' gone "$tray"
check_eq 'agent_tray_stop clears TRAY_PID' "$TRAY_PID" ''
TRAY_PID=''; check 'agent_tray_stop accepts an empty TRAY_PID' agent_tray_stop
TRAY_PID=2147483; check 'agent_tray_stop accepts a pid that no longer exists' agent_tray_stop; TRAY_PID=''

# ---------- agent_stop -----------------------------------------------------------
systemctl(){ printf '%s\n' "$*" >> "$TMP_DIR/systemctl.log"; return "${SYSTEMCTL_RC:-0}"; }
bash -c 'while :; do /bin/sleep 0.1; done' & outside=$!
write_pidfile "$PID_AGENT" "$outside"
t0=$SECONDS
rc=0; SYSTEMCTL_RC=0 agent_stop || rc=$?
stop_secs=$((SECONDS - t0))
wait "$outside" 2>/dev/null || true
check 'agent_stop stops an agent running outside systemd when systemctl succeeds' gone "$outside"
# the stopped fake agent never removes its pidfile: the wait for the slot to free must not run to its 12 s bound
check 'agent_stop does not wait out its bound when the stopped agent leaves a stale pidfile' test "$stop_secs" -lt 6
check 'agent_stop asks systemd to stop the user service' grep -Fxq -- '--user stop phonecam-agent.service' "$TMP_DIR/systemctl.log"

# an agent whose parent never reaps it stays a zombie once killed; the slot is free all the same (as agent_claim sees it)
python3 -c 'import os, time
pid = os.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", "while :; do /bin/sleep 0.1; done"])
print(pid, flush=True)
time.sleep(60)' > "$TMP_DIR/zombie.pid" & zparent=$!
for _i in $(seq 1 50); do [ -s "$TMP_DIR/zombie.pid" ] && break; /bin/sleep 0.1; done
zombie=$(cat "$TMP_DIR/zombie.pid")
write_pidfile "$PID_AGENT" "$zombie"
t0=$SECONDS
rc=0; SYSTEMCTL_RC=0 agent_stop || rc=$?
stop_secs=$((SECONDS - t0))
kill "$zparent" 2>/dev/null || true
wait "$zparent" 2>/dev/null || true
check 'agent_stop does not wait out its bound for a stopped agent left as a zombie' test "$stop_secs" -lt 6

bash -c 'while :; do /bin/sleep 0.1; done' & outside=$!
write_pidfile "$PID_AGENT" "$outside"
rc=0; SYSTEMCTL_RC=5 agent_stop || rc=$?
wait "$outside" 2>/dev/null || true
check_eq 'agent_stop reports success after stopping the agent itself' "$rc" 0

rm -f "$PID_AGENT"
rc=0; SYSTEMCTL_RC=5 agent_stop || rc=$?
check_eq 'agent_stop passes systemctl failure through when no agent is alive' "$rc" 5
rc=0; SYSTEMCTL_RC=0 agent_stop || rc=$?
check_eq 'agent_stop succeeds quietly when nothing is running' "$rc" 0

# ---------- pidfile_matches_script: comm depends on how the script was launched ----
# Executing a "#!/bin/bash" script directly gives comm = script name, not "bash".
SELF_SAVE="$SELF_PATH"
comm_of(){ cat "/proc/$1/comm" 2>/dev/null; }
for name in phonecam-dev.sh phonecam-a-very-long-name.sh; do
    fake="$TMP_DIR/$name"
    printf '#!/bin/bash\nwhile :; do /bin/sleep 0.2; done\n' > "$fake"; chmod +x "$fake"
    "$fake" & fpid=$!
    until [ "$(comm_of "$fpid")" = "${name:0:15}" ]; do /bin/sleep 0.05; done
    SELF_PATH="$fake"
    write_pidfile "$TMP_DIR/fake.pid" "$fpid"
    check "matching on comm bash alone misses a directly executed $name" in_child '! pidfile_matches_process "$1" bash' "$TMP_DIR/fake.pid"
    check "pidfile_matches_script recognises a directly executed $name" pidfile_matches_script "$TMP_DIR/fake.pid"
    SELF_PATH="$SELF_SAVE"
    kill "$fpid" 2>/dev/null || true
    wait "$fpid" 2>/dev/null || true
done
/bin/sleep 300 & other=$!
write_pidfile "$TMP_DIR/other.pid" "$other"
check 'pidfile_matches_script rejects an unrelated live process' in_child '! pidfile_matches_script "$1"' "$TMP_DIR/other.pid"
kill "$other" 2>/dev/null || true
wait "$other" 2>/dev/null || true
write_pidfile "$TMP_DIR/self.pid" "$BASHPID"
check 'pidfile_matches_script accepts a bash interpreter process' pidfile_matches_script "$TMP_DIR/self.pid"

# ---------- End to end: real agents, no stubbed kill ------------------------------
mkdir -p "$TMP_DIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/adb"; chmod +x "$TMP_DIR/bin/adb"
export PATH="$TMP_DIR/bin:$PATH"
agent_ready(){ local i; for i in $(seq 1 50); do pidfile_matches_process "$PID_AGENT" && return 0; /bin/sleep 0.1; done; return 1; }
direct_copy="$TMP_DIR/phonecam-e2e.sh"
{ printf '#!/bin/bash\n'; tail -n +2 "$SCRIPT"; } > "$direct_copy"; chmod +x "$direct_copy"
rm -f "$PID_AGENT"
for launch in interpreter direct; do
    if [ "$launch" = direct ]; then
        "$direct_copy" agent > "$TMP_DIR/e2e.$launch.out" 2>&1 & agent=$!
        SELF_PATH="$direct_copy"
    else
        bash "$SCRIPT" agent > "$TMP_DIR/e2e.$launch.out" 2>&1 & agent=$!
    fi
    check "a real agent started by $launch registers itself" agent_ready
    check_eq "the agent registered by $launch is the launched process" "$(pidfile_pid "$PID_AGENT")" "$agent"

    dup_rc=0; bash "$SCRIPT" agent > "$TMP_DIR/dup.$launch.out" 2>&1 || dup_rc=$?
    check_eq "a second agent next to the $launch one exits 0" "$dup_rc" 0
    check "a second agent next to the $launch one reports that one is running" grep -Fq "$(t AGENT_ALREADY)" "$TMP_DIR/dup.$launch.out"
    check_eq "a second agent leaves the $launch pidfile alone" "$(pidfile_pid "$PID_AGENT")" "$agent"

    rc=0; SYSTEMCTL_RC=0 agent_stop || rc=$?
    for _i in $(seq 1 50); do gone "$agent" && break; /bin/sleep 0.1; done
    check "agent_stop terminates a real agent started by $launch" gone "$agent"
    check "a stopped agent started by $launch removes its own pidfile" test ! -e "$PID_AGENT"
    kill "$agent" 2>/dev/null || true   # a failed stop must not leave the agent running or hang wait
    wait "$agent" 2>/dev/null || true
    SELF_PATH="$SELF_SAVE"
done

kill "$live" 2>/dev/null || true
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
