#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
chmod 755 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/bin" "$TMP_DIR/run" "$TMP_DIR/logs"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" PATH="$TMP_DIR/bin:$PATH"
export PHONECAM_DISPLAY_WAIT=0   # a real user manager, if any, must not feed or delay the agents started here
cat > "$TMP_DIR/bin/apt" <<'EOF_APT'
#!/bin/sh
printf '%s\n' "$*" >> "$APT_LOG"
exit 0
EOF_APT
cat > "$TMP_DIR/bin/apt-cache" <<'EOF_APT_CACHE'
#!/bin/sh
exit 0
EOF_APT_CACHE
cat > "$TMP_DIR/bin/adb" <<'EOF_ADB'
#!/bin/sh
exit 0
EOF_ADB
cat > "$TMP_DIR/bin/pactl" <<'EOF_PACTL'
#!/bin/sh
exit 0
EOF_PACTL
cat > "$TMP_DIR/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
EOF_SYSTEMCTL
cat > "$TMP_DIR/bin/modprobe" <<'EOF_MODPROBE'
#!/bin/sh
exit 0
EOF_MODPROBE
cat > "$TMP_DIR/bin/lsmod" <<'EOF_LSMOD'
#!/bin/sh
exit 1
EOF_LSMOD
cat > "$TMP_DIR/bin/getent" <<'EOF_GETENT'
#!/bin/sh
exit 2
EOF_GETENT
for x in apt apt-cache adb pactl systemctl modprobe lsmod getent; do chmod +x "$TMP_DIR/bin/$x"; done
export APT_LOG="$TMP_DIR/apt.log" SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"

run_cycle() {
    local lang="$1"
    local isolated="$TMP_DIR/cycle-$lang"
    rm -rf "$isolated"
    mkdir -p "$isolated"
    cat > "$isolated/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$1"
lang="$2"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
HOME="$TMP_DIR/home with spaces"
XDG_RUNTIME_DIR="$TMP_DIR/run"
export HOME XDG_RUNTIME_DIR
mkdir -p "$HOME/.config/phonecam" "$TMP_DIR/run" "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/apt" <<'EOF_APT'
#!/bin/sh
exit 0
EOF_APT
cat > "$TMP_DIR/bin/apt-cache" <<'EOF_APT_CACHE'
#!/bin/sh
exit 0
EOF_APT_CACHE
cat > "$TMP_DIR/bin/pactl" <<'EOF_PACTL'
#!/bin/sh
exit 0
EOF_PACTL
cat > "$TMP_DIR/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/bin/sh
exit 0
EOF_SYSTEMCTL
cat > "$TMP_DIR/bin/modprobe" <<'EOF_MODPROBE'
#!/bin/sh
exit 0
EOF_MODPROBE
cat > "$TMP_DIR/bin/lsmod" <<'EOF_LSMOD'
#!/bin/sh
exit 1
EOF_LSMOD
cat > "$TMP_DIR/bin/getent" <<'EOF_GETENT'
#!/bin/sh
exit 2
EOF_GETENT
for x in apt apt-cache pactl systemctl modprobe lsmod getent; do chmod +x "$TMP_DIR/bin/$x"; done
PATH="$TMP_DIR/bin:/usr/bin:/bin"
export PATH
source "$SCRIPT"
FAKE_DEV="$TMP_DIR/dev"; mkdir -p "$FAKE_DEV"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$FAKE_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
cat > "$HOME/.config/phonecam/phonecam.conf" <<EOF_CONF
PHONECAM_LANG="$lang"
CAMERA_FACING="back"
V4L2_DEVICE="/dev/video42"
EOF_CONF
ensure_scrcpy_installed() { return 0; }
sudo_atomic_write_file() {
    local dest="$1" mode="${2:-644}" mapped
    mapped="$TMP_DIR/etc/${dest#/etc/}"
    mkdir -p "$(dirname "$mapped")"
    cat > "$mapped" || return 1
    chmod "$mode" "$mapped" || return 1
}
sudo() { "$@"; }
main install --yes
check_installed() {
    test -x "$INSTALLED_BIN" && cmp -s "$SCRIPT" "$INSTALLED_BIN" &&
    grep -Fq "Exec=\"$INSTALLED_BIN\" menu" "$DESKTOP_FILE" &&
    grep -Fq 'GenericName[en]=Android phone as webcam and microphone' "$DESKTOP_FILE" &&
    grep -Fq 'GenericName[es]=Móvil Android como webcam y micrófono' "$DESKTOP_FILE" &&
    grep -Fq 'Comment[en]=Use your Android as a webcam and/or microphone over USB' "$DESKTOP_FILE" &&
    grep -Fq 'Comment[es]=Usa tu Android como webcam y/o micrófono por USB' "$DESKTOP_FILE" &&
    grep -Fq "ExecStart=\"$INSTALLED_BIN\" agent" "$SYSTEMD_SERVICE_FILE" &&
    grep -Fq "CAMERA_FACING=\"back\"" "$CONF_FILE" &&
    grep -Fq "PHONECAM_LANG=\"$lang\"" "$CONF_FILE" &&
    grep -Fq 'options v4l2loopback video_nr=42' "$TMP_DIR/etc/modprobe.d/phonecam-v4l2loopback.conf" &&
    grep -Fxq 'v4l2loopback' "$TMP_DIR/etc/modules-load.d/phonecam-v4l2loopback.conf"
}
check_installed
set_config CAMERA_FACING front
main install --yes
source "$CONF_FILE"
test "$CAMERA_FACING" = front
if [ "$lang" = en ]; then
    grep -c '^# Added by the PhoneCam installer$' "$HOME/.profile" | grep -Fxq 1
else
    grep -c '^# Añadido por el instalador de PhoneCam$' "$HOME/.profile" | grep -Fxq 1
fi
bash "$INSTALLED_BIN" uninstall <<<y
test ! -e "$INSTALLED_BIN"
test ! -e "$DESKTOP_FILE"
test ! -e "$ICON_FILE"
test ! -e "$SYSTEMD_SERVICE_FILE"
test ! -e "$CONF_FILE"
# A lone copy of the script (no assets/ beside it) installs the embedded icon.
mkdir -p "$TMP_DIR/lone"; cp "$SCRIPT" "$TMP_DIR/lone/phonecam.sh"
SELF_PATH="$TMP_DIR/lone/phonecam.sh"; ICON_SOURCE="$TMP_DIR/lone/no-asset.png"
main install --yes
test "$(head -c 4 "$ICON_FILE" | tail -c 3)" = PNG
bash "$INSTALLED_BIN" uninstall <<<y
test ! -e "$ICON_FILE"
HARNESS
    chmod 755 "$isolated" "$isolated/harness.sh"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || return 1
        runuser -u nobody -- "$isolated/harness.sh" "$SCRIPT" "$lang"
    else
        "$isolated/harness.sh" "$SCRIPT" "$lang"
    fi
}

pass=0 fail=0
ok(){ pass=$((pass+1)); echo "ok - $1"; }
bad(){ fail=$((fail+1)); echo "not ok - $1" >&2; }

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    if bash "$SCRIPT" uninstall >/dev/null 2>&1; then bad 'uninstall root guard'; else ok 'uninstall root guard'; fi
    if bash "$SCRIPT" install --yes >/dev/null 2>&1; then bad 'install root guard'; else ok 'install root guard'; fi
fi
cycle_out="$TMP_DIR/install-cycle.out"
for lang in en es; do
    cycle_out="$TMP_DIR/install-cycle-$lang.out"
    if run_cycle "$lang" >"$cycle_out" 2>&1; then
        ok "non-root $lang install/reinstall/uninstall lifecycle"
    else
        cat "$cycle_out" >&2
        bad "non-root $lang install/reinstall/uninstall lifecycle"
    fi
done

# lsmod lists v4l2loopback first and keeps writing for a while: a grep -q reader quits at that line and, under pipefail,
# the SIGPIPE lsmod then gets reads as "module not loaded", so a reinstall would skip the reload.
run_reload_case() {
    local d="$TMP_DIR/reload"
    rm -rf "$d"
    mkdir -p "$d"
    cat > "$d/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$1"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" MODPROBE_LOG="$TMP_DIR/modprobe.log"
mkdir -p "$HOME/.config/phonecam" "$XDG_RUNTIME_DIR" "$TMP_DIR/bin"
for x in apt apt-cache pactl systemctl; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$x"; done
printf '#!/bin/sh\nexit 2\n' > "$TMP_DIR/bin/getent"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$MODPROBE_LOG"\n' > "$TMP_DIR/bin/modprobe"
cat > "$TMP_DIR/bin/lsmod" <<'EOF_LSMOD'
#!/bin/sh
printf 'v4l2loopback           40960  0\n'
i=0
while [ "$i" -lt 5 ]; do sleep 0.05; head -c 3000 /dev/zero | tr '\0' x; echo; i=$((i + 1)); done
EOF_LSMOD
chmod +x "$TMP_DIR"/bin/*
PATH="$TMP_DIR/bin:/usr/bin:/bin"
source "$SCRIPT"
FAKE_DEV="$TMP_DIR/dev"; mkdir -p "$FAKE_DEV"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$FAKE_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
ensure_scrcpy_installed() { return 0; }
sudo_atomic_write_file() { cat > /dev/null; }
sudo() { "$@"; }
main install --yes > "$TMP_DIR/install.out" 2>&1
grep -Fxq -- '-r v4l2loopback' "$MODPROBE_LOG"
HARNESS
    chmod 755 "$d" "$d/harness.sh"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || return 1
        runuser -u nobody -- "$d/harness.sh" "$SCRIPT"
    else
        "$d/harness.sh" "$SCRIPT"
    fi
}
if run_reload_case > "$TMP_DIR/reload.out" 2>&1; then
    ok 'reinstall reloads v4l2loopback although lsmod keeps writing after its line'
else
    cat "$TMP_DIR/reload.out" >&2
    bad 'reinstall reloads v4l2loopback although lsmod keeps writing after its line'
fi

# `phonecam l` before `phonecam install` creates the config file: it must carry the commented template (in the language just
# chosen), because install leaves an existing file untouched.
run_seed_case() {
    local d="$TMP_DIR/seed"
    rm -rf "$d"
    mkdir -p "$d"
    cat > "$d/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$1"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
unset PHONECAM_LANG
export LC_ALL=C HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMP_DIR/bin"
for x in apt apt-cache pactl systemctl modprobe; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$x"; done
printf '#!/bin/sh\nexit 2\n' > "$TMP_DIR/bin/getent"
chmod +x "$TMP_DIR"/bin/*
PATH="$TMP_DIR/bin:/usr/bin:/bin"
source "$SCRIPT"
FAKE_DEV="$TMP_DIR/dev"; mkdir -p "$FAKE_DEV"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$FAKE_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
ensure_scrcpy_installed() { return 0; }
sudo_atomic_write_file() { cat > /dev/null; }
sudo() { "$@"; }
test ! -e "$CONF_FILE"
main l > "$TMP_DIR/lang.out" 2>&1
grep -Fxq "PHONECAM_LANG='es'" "$CONF_FILE"
grep -Fq '#  PhoneCam - configuración' "$CONF_FILE"
main install --yes > "$TMP_DIR/install.out" 2>&1
test "$(grep -c '^PHONECAM_LANG=' "$CONF_FILE")" = 1
grep -Fxq "PHONECAM_LANG='es'" "$CONF_FILE"
grep -Fq '#  PhoneCam - configuración' "$CONF_FILE"
grep -Fxq 'CAMERA_FACING="back"        # back | front | external' "$CONF_FILE"
grep -Fxq 'V4L2_DEVICE="/dev/video42"' "$CONF_FILE"
HARNESS
    chmod 755 "$d" "$d/harness.sh"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || return 1
        runuser -u nobody -- "$d/harness.sh" "$SCRIPT"
    else
        "$d/harness.sh" "$SCRIPT"
    fi
}
if run_seed_case > "$TMP_DIR/seed.out" 2>&1; then
    ok 'language toggled before install leaves the commented template, and install keeps it'
else
    cat "$TMP_DIR/seed.out" >&2
    bad 'language toggled before install leaves the commented template, and install keeps it'
fi

# The installer must not take /dev/video42 for granted: when another device owns it and v4l2loopback is not loaded, it moves
# to the next free node (within 20), rewrites V4L2_DEVICE and loads the module there. Nodes are faked, so a real one changes nothing.
# Arguments: busy nodes, module loaded (yes|no), config present (yes|no), expected node number or "fail".
run_node_case() {
    local d="$TMP_DIR/node"
    rm -rf "$d"
    mkdir -p "$d"
    cat > "$d/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$1" busy="$2" loaded="$3" has_conf="$4" expect="$5"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PHONECAM_LANG=en HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" MODPROBE_LOG="$TMP_DIR/modprobe.log"
mkdir -p "$HOME/.config/phonecam" "$XDG_RUNTIME_DIR" "$TMP_DIR/bin"
for x in apt apt-cache pactl systemctl; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$x"; done
printf '#!/bin/sh\nexit 2\n' > "$TMP_DIR/bin/getent"
printf '#!/bin/sh\nprintf "%%s\\\\n" "$*" >> "$MODPROBE_LOG"\n' > "$TMP_DIR/bin/modprobe"
if [ "$loaded" = yes ]; then printf '#!/bin/sh\necho "v4l2loopback           40960  0"\n' > "$TMP_DIR/bin/lsmod"; else printf '#!/bin/sh\nexit 1\n' > "$TMP_DIR/bin/lsmod"; fi
chmod +x "$TMP_DIR"/bin/*
PATH="$TMP_DIR/bin:/usr/bin:/bin"
source "$SCRIPT"
FAKE_DEV="$TMP_DIR/dev"; mkdir -p "$FAKE_DEV"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$FAKE_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
for n in $busy; do : > "$FAKE_DEV/video$n"; done
ensure_scrcpy_installed() { return 0; }
sudo_atomic_write_file() {
    local dest="$1" mode="${2:-644}" mapped
    mapped="$TMP_DIR/etc/${dest#/etc/}"
    mkdir -p "$(dirname "$mapped")"
    cat > "$mapped"
    chmod "$mode" "$mapped"
}
sudo() { "$@"; }
if [ "$has_conf" = yes ]; then printf 'V4L2_DEVICE="/dev/video42"\n' > "$CONF_FILE"; fi
rc=0
( main install --yes ) > "$TMP_DIR/install.out" 2>&1 || rc=$?
modprobe_conf="$TMP_DIR/etc/modprobe.d/phonecam-v4l2loopback.conf"
if [ "$expect" = fail ]; then
    test "$rc" -eq 1
    grep -Fq 'No free /dev/video device was found near /dev/video42.' "$TMP_DIR/install.out"
    test ! -e "$modprobe_conf"
    test ! -s "$MODPROBE_LOG"
    exit 0
fi
test "$rc" -eq 0
grep -Fq " video_nr=$expect " "$modprobe_conf"
tail -n 1 "$MODPROBE_LOG" | grep -Fq "video_nr=$expect "
test "$(grep -c '^V4L2_DEVICE=' "$CONF_FILE")" = 1
( source "$CONF_FILE"; test "$V4L2_DEVICE" = "/dev/video$expect" )
if [ "$expect" = 42 ]; then
    if grep -Fq 'already in use' "$TMP_DIR/install.out"; then exit 1; fi
else
    grep -Fq '/dev/video42 is already in use by another device.' "$TMP_DIR/install.out"
    grep -Fq "Using /dev/video$expect instead." "$TMP_DIR/install.out"
fi
HARNESS
    chmod 755 "$d" "$d/harness.sh"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || return 1
        runuser -u nobody -- "$d/harness.sh" "$SCRIPT" "$@"
    else
        "$d/harness.sh" "$SCRIPT" "$@"
    fi
}
node_case() {
    local label="$1"; shift
    if run_node_case "$@" > "$TMP_DIR/node.out" 2>&1; then ok "$label"; else cat "$TMP_DIR/node.out" >&2; bad "$label"; fi
}
node_case 'node 42 taken by another device: install moves to 43 and rewrites V4L2_DEVICE' '42' no yes 43
node_case 'nodes 42 and 43 taken: install skips both and uses 44' '42 43' no yes 44
node_case 'node 42 taken on a fresh install: the new config already names 43' '42' no no 43
node_case 'node 42 owned by our own loaded v4l2loopback: reinstall keeps 42' '42' yes yes 42
node_case 'nodes 42 to 61 taken: install still finds 62, the last candidate' "$(seq -s ' ' 42 61)" no yes 62
node_case 'nodes 42 to 62 taken: install fails before touching modprobe.d or the module' "$(seq -s ' ' 42 62)" no yes fail

# `systemctl --user enable --now` leaves an already running agent untouched, on the old code: an install must stop the agent
# right before it, after the unit file is rewritten and reloaded. The order is read from the log of systemctl calls.
run_order_case() {
    local d="$TMP_DIR/order"
    rm -rf "$d"
    mkdir -p "$d"
    cat > "$d/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$1"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PHONECAM_LANG=en HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMP_DIR/bin"
for x in apt apt-cache pactl modprobe lsmod; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$x"; done
printf '#!/bin/sh\nexit 2\n' > "$TMP_DIR/bin/getent"
printf '#!/bin/sh\nprintf "%%s\\\\n" "$*" >> "$SYSTEMCTL_LOG"\n' > "$TMP_DIR/bin/systemctl"
chmod +x "$TMP_DIR"/bin/*
PATH="$TMP_DIR/bin:/usr/bin:/bin"
source "$SCRIPT"
FAKE_DEV="$TMP_DIR/dev"; mkdir -p "$FAKE_DEV"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$FAKE_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
ensure_scrcpy_installed() { return 0; }
sudo_atomic_write_file() { cat > /dev/null; }
sudo() { "$@"; }
main install --yes > "$TMP_DIR/install.out" 2>&1
main install --yes >> "$TMP_DIR/install.out" 2>&1
awk '{ l[NR] = $0 }
     END { n = 0
           for (i = 1; i <= NR; i++) if (l[i] == "--user enable --now phonecam-agent.service") {
               n++
               if (i < 3 || l[i-1] != "--user stop phonecam-agent.service" || l[i-2] != "--user daemon-reload") exit 1
           }
           exit (n == 2 ? 0 : 1) }' "$SYSTEMCTL_LOG"
HARNESS
    chmod 755 "$d" "$d/harness.sh"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || return 1
        runuser -u nobody -- "$d/harness.sh" "$SCRIPT"
    else
        "$d/harness.sh" "$SCRIPT"
    fi
}
if run_order_case > "$TMP_DIR/order.out" 2>&1; then
    ok 'install and reinstall stop the agent right before systemctl enable --now, after daemon-reload'
else
    cat "$TMP_DIR/order.out" >&2
    bad 'install and reinstall stop the agent right before systemctl enable --now, after daemon-reload'
fi

# A hand-started agent stuck in a slow `adb devices` honours SIGTERM only once adb returns. If the install did not wait for it,
# the unit's new agent would find the slot taken, exit 0 ("already running") and systemd would not restart it: no agent at all.
# The fake systemctl starts the new agent on `enable --now` as the unit would, and releases the slow adb 1.5 s after `stop`.
run_handstart_case() {
    local d="$TMP_DIR/handstart"
    rm -rf "$d"
    mkdir -p "$d"
    cat > "$d/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$1"
TMP_DIR="$(mktemp -d)"
old="" ; new=""
cleanup() { kill "$old" 2>/dev/null || true; kill "$new" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
export PHONECAM_LANG=en HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
export ADB_HOLD="$TMP_DIR/adb.hold" ADB_FLAG="$TMP_DIR/adb.flag" NEW_PID="$TMP_DIR/new.pid" NEW_OUT="$TMP_DIR/new.out"
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMP_DIR/bin"
for x in apt apt-cache pactl modprobe lsmod; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$x"; done
printf '#!/bin/sh\nexit 2\n' > "$TMP_DIR/bin/getent"
cat > "$TMP_DIR/bin/adb" <<'EOF_ADB'
#!/bin/sh
: > "$ADB_FLAG"
i=0
while [ -e "$ADB_HOLD" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
exit 0
EOF_ADB
cat > "$TMP_DIR/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
    '--user stop phonecam-agent.service') ( sleep 1.5; rm -f "$ADB_HOLD" ) > /dev/null 2>&1 & ;;
    '--user enable --now phonecam-agent.service')
        nohup bash "$HOME/.local/bin/phonecam" agent > "$NEW_OUT" 2>&1 < /dev/null &
        echo $! > "$NEW_PID" ;;
esac
exit 0
EOF_SYSTEMCTL
chmod +x "$TMP_DIR"/bin/*
PATH="$TMP_DIR/bin:/usr/bin:/bin"
source "$SCRIPT"
FAKE_DEV="$TMP_DIR/dev"; mkdir -p "$FAKE_DEV"
v4l2_node_exists() { case "$1" in /dev/*) [ -e "$FAKE_DEV/${1#/dev/}" ];; *) [ -e "$1" ];; esac; }
ensure_scrcpy_installed() { return 0; }
sudo_atomic_write_file() { cat > /dev/null; }
sudo() { "$@"; }
: > "$ADB_HOLD"
bash "$SCRIPT" agent > "$TMP_DIR/old.out" 2>&1 & old=$!
for _i in $(seq 1 100); do [ "$(pidfile_pid "$PID_AGENT" 2>/dev/null)" = "$old" ] && [ -e "$ADB_FLAG" ] && break; sleep 0.05; done
test "$(pidfile_pid "$PID_AGENT")" = "$old"
test -e "$ADB_FLAG"
main install --yes > "$TMP_DIR/install.out" 2>&1
new="$(cat "$NEW_PID")"
wait "$old" 2>/dev/null || true
for _i in $(seq 1 50); do [ "$(pidfile_pid "$PID_AGENT" 2>/dev/null)" = "$new" ] && break; sleep 0.1; done
test "$(pidfile_pid "$PID_AGENT")" = "$new"
kill -0 "$new"
HARNESS
    chmod 755 "$d" "$d/harness.sh"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        command -v runuser >/dev/null 2>&1 || return 1
        runuser -u nobody -- "$d/harness.sh" "$SCRIPT"
    else
        "$d/harness.sh" "$SCRIPT"
    fi
}
if run_handstart_case > "$TMP_DIR/handstart.out" 2>&1; then
    ok 'reinstall waits for a slow hand-started agent to exit, so the new agent takes over instead of finding the slot taken'
else
    cat "$TMP_DIR/handstart.out" >&2
    bad 'reinstall waits for a slow hand-started agent to exit, so the new agent takes over instead of finding the slot taken'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
