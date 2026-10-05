#!/usr/bin/env bash
# User simulation with a REAL PulseAudio server (private instance) and a stateful fake phone.
# Unlike the other suites, pactl is not mocked: the virtual sink/microphone are created, routed,
# recorded and removed for real. The kernel's v4l2loopback cannot be loaded from a test, so the
# video side is checked through the install commands and the device file the capture writes to.
# Optional: PHONECAM_REAL_SCRCPY=/path/to/scrcpy replays every argument line the script produced
# against the real scrcpy parser (it must stop at "no ADB device", never at an option error).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"

skip() { printf 'skip - %s\n' "$1"; exit 0; }
[ "$EUID" -ne 0 ] || skip "run as a normal user (phonecam install/uninstall refuse root)"
for tool in pulseaudio pactl pacat parec python3 flock; do
    command -v "$tool" >/dev/null 2>&1 || skip "needs '$tool'"
done

TMP_DIR="$(mktemp -d)"
cleanup() {
    trap - EXIT
    bash "$SCRIPT" stop >/dev/null 2>&1
    pulseaudio --kill >/dev/null 2>&1
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" PHONECAM_LANG=en
export PHONE_DIR="$TMP_DIR/phone" FAKE_DEV="$TMP_DIR/dev" ARGS_LOG="$TMP_DIR/scrcpy.args"
export PATH="$TMP_DIR/bin:/usr/bin:/bin"
export PHONECAM_START_GRACE=1 PHONECAM_DISPLAY_WAIT=0
export PULSE_RUNTIME_PATH="$TMP_DIR/pulse" PULSE_STATE_PATH="$TMP_DIR/pulse-state"
export PULSE_SERVER="unix:$PULSE_RUNTIME_PATH/native"
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "$HOME/.config/phonecam" "$XDG_RUNTIME_DIR" "$PHONE_DIR" "$FAKE_DEV" "$TMP_DIR/bin" "$TMP_DIR/audio" "$PULSE_RUNTIME_PATH" "$PULSE_STATE_PATH"
chmod 700 "$XDG_RUNTIME_DIR"

# ---- Private PulseAudio: the default sink stands in for the speakers the real scrcpy would play on.
pulseaudio -n --daemonize=yes --exit-idle-time=-1 --log-target="file:$TMP_DIR/pulse.log" \
    -L "module-native-protocol-unix socket=$PULSE_RUNTIME_PATH/native auth-anonymous=1" \
    -L "module-null-sink sink_name=auto_null" >/dev/null 2>&1
for _ in $(seq 50); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done
pactl info >/dev/null 2>&1 || { echo "not ok - private PulseAudio did not start (see pulse.log)" >&2; exit 1; }
pactl set-default-sink auto_null

# ---- Fake phone. State is plain files under $PHONE_DIR so a test can plug, unplug or downgrade it.
printf 'FAKEPHONE01\n' > "$PHONE_DIR/serial"
printf '34\r\n' > "$PHONE_DIR/api"            # real adb shell output ends in CRLF
printf '2\n' > "$PHONE_DIR/stay_on"
printf 'Awake\n' > "$PHONE_DIR/wakefulness"
cat > "$TMP_DIR/bin/adb" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PHONE_DIR/adb.log"
serial="$(cat "$PHONE_DIR/serial")"
case "${1:-}" in
    start-server|kill-server) exit 0 ;;
    devices)
        echo "List of devices attached"
        [ -e "$PHONE_DIR/connected" ] && printf '%s\tdevice\n' "$serial"
        exit 0 ;;
    -s)
        if [ "${2:-}" != "$serial" ] || [ ! -e "$PHONE_DIR/connected" ]; then
            echo "error: device '${2:-}' not found" >&2; exit 1
        fi
        shift 2
        [ "${1:-}" = shell ] || exit 0
        shift
        case "${1:-}" in
            getprop) [ "${2:-}" = ro.build.version.sdk ] && cat "$PHONE_DIR/api" ;;
            settings)
                case "${2:-}" in
                    get) cat "$PHONE_DIR/stay_on" ;;
                    put) printf '%s\n' "${5:-}" > "$PHONE_DIR/stay_on" ;;
                esac ;;
            dumpsys) printf '  mWakefulness=%s\r\n' "$(cat "$PHONE_DIR/wakefulness")" ;;
            input) printf 'Asleep\n' > "$PHONE_DIR/wakefulness" ;;
            cmd) printf 'Asleep\n' > "$PHONE_DIR/wakefulness" ;;
        esac ;;
esac
exit 0
SH

# Fake scrcpy: accepts only options that exist in FAKE_SCRCPY_VERSION (table taken from the real
# cli.c of each release), applies the real cross-option rules, then behaves like the phone's side.
cat > "$TMP_DIR/bin/scrcpy" <<'SH'
#!/bin/bash
ver="${FAKE_SCRCPY_VERSION:-3.3.3}"
vge() { [ "$(printf '%s\n%s\n' "$1" "$ver" | sort -V | head -n1)" = "$1" ]; }
die() { echo "ERROR: $*" >&2; exit 1; }
if [ "${1:-}" = --version ]; then printf 'scrcpy %s <https://github.com/Genymobile/scrcpy>\n' "$ver"; exit 0; fi
printf '%s\n' "$*" >> "$ARGS_LOG"
serial="" list=0 vsrc="" cam_id="" cam_facing="" v4l2="" no_video=0 no_audio=0 no_control=0 req_audio=0 asrc=""
while [ $# -gt 0 ]; do
    case "$1" in
        -s) serial="$2"; shift ;;
        --list-cameras) list=1 ;;
        --video-source=camera) vsrc=camera ;;
        --camera-id=*) cam_id="${1#*=}" ;;
        --camera-facing=front|--camera-facing=back|--camera-facing=external) cam_facing="${1#*=}" ;;
        --camera-size=*x*|--camera-fps=*|--video-bit-rate=*|--audio-bit-rate=*) ;;
        --video-codec=h264|--video-codec=h265|--video-codec=av1) ;;
        --audio-codec=opus|--audio-codec=aac|--audio-codec=flac|--audio-codec=raw) ;;
        --v4l2-sink=*) v4l2="${1#*=}" ;;
        --no-playback) ;;
        --no-audio) no_audio=1 ;;
        --no-video) no_video=1 ;;
        --no-control) no_control=1 ;;
        --require-audio) req_audio=1 ;;
        --no-window) vge 2.5 || die "Unknown option: $1" ;;
        --audio-source=mic) asrc=mic ;;
        --audio-source=mic-*|--audio-source=voice-*) vge 3.2 || die "Unknown audio source: $1"; asrc="${1#*=}" ;;
        --turn-screen-off|--stay-awake) [ "$no_control" -eq 0 ] || die "Cannot request that with control disabled" ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
[ -n "$cam_id" ] && [ -n "$cam_facing" ] && die "Cannot specify both --camera-id and --camera-facing"
[ -e "$PHONE_DIR/connected" ] || die "Could not find any ADB device"
[ "$list" -eq 1 ] && [ -z "$serial" ] && die "Multiple devices"
if [ "$list" -eq 1 ]; then
    printf '%s\n' '[server] INFO: List of cameras:' \
        '    --camera-id=0    (back, 4080x3072, fps=[15, 24, 30, 60])' '        - 4080x3072' \
        '    --camera-id=1    (front, 3840x2160, fps=[15, 24, 30])' '        - 3840x2160'
    exit 0
fi
[ "$serial" = "$(cat "$PHONE_DIR/serial")" ] || die "Device not found: $serial"
api="$(tr -d '\r' < "$PHONE_DIR/api")"
trap '[ -z "${apid:-}" ] || kill -TERM -- -"$apid" 2>/dev/null; exit 0' TERM INT
echo "INFO: scrcpy $ver"
if [ "$vsrc" = camera ]; then
    [ "$api" -ge 31 ] || die "Camera mirroring requires Android 12"
    [ -n "$v4l2" ] || die "No output (neither playback nor v4l2 sink)"
    [ -w "$v4l2" ] || die "Could not open v4l2 sink: $v4l2"
    exec 3>>"$v4l2"
    n=0
    while :; do n=$((n + 1)); printf 'frame %d\n' "$n" >&3; sleep 0.2 & wait $!; done
fi
if [ "$no_video" -eq 1 ]; then
    [ "$req_audio" -eq 0 ] || [ "$api" -ge 30 ] || die "Audio forwarding requires Android 11"
    setsid bash -c 'while :; do cat "$1"; done | exec "$2" -p --rate=48000 --channels=2 --format=s16le --latency-msec=50' _ "$TONE_RAW" "$TMP_DIR/audio/scrcpy" &
    apid=$!
    wait "$apid"
    exit 0
fi
die "Nothing to do"
SH
chmod +x "$TMP_DIR/bin/adb" "$TMP_DIR/bin/scrcpy"
export TONE_RAW="$TMP_DIR/tone.raw"
python3 - "$TONE_RAW" <<'PY'
import array, math, sys
samples = array.array('h')
for i in range(48000):
    v = int(9000 * math.sin(2 * math.pi * 440 * i / 48000))
    samples.extend((v, v))
open(sys.argv[1], 'wb').write(samples.tobytes())
PY
cp "$(command -v pacat)" "$TMP_DIR/audio/scrcpy"   # a pulse client whose binary name is "scrcpy", as the real one
export TMP_DIR

touch "$FAKE_DEV/video42"
cat > "$HOME/.config/phonecam/phonecam.conf" <<EOF_CONF
PHONECAM_LANG='en'
CAMERA_FACING='front'
CAMERA_SIZE='1920x1080'
CAMERA_FPS='30'
V4L2_DEVICE='$FAKE_DEV/video42'
MIC_SINK_NAME='PhoneMicSink'
MIC_SOURCE_NAME='PhoneMic'
AUTO_MODE='both'
KEEP_AWAKE='true'
EOF_CONF
RUN_DIR="$XDG_RUNTIME_DIR/phonecam"

# ---- Helpers
FAILS=0
check() { local label="$1" out; shift; if out="$("$@" 2>&1)"; then printf 'ok - %s\n' "$label"; else printf 'not ok - %s\n%s\n' "$label" "$out" >&2; FAILS=$((FAILS + 1)); fi; }
pc() { timeout --kill-after=5s 45s bash "$SCRIPT" "$@"; }
run_pc() { LAST_RC=0; LAST_OUT="$(pc "$@" 2>&1)" || LAST_RC=$?; }
has() { [[ "$LAST_OUT" == *"$1"* ]]; }
plug() { : > "$PHONE_DIR/connected"; }
unplug() { rm -f "$PHONE_DIR/connected"; }
pa_short() { pactl list short "$1" | awk -v n="$2" '$2 == n { print $1; found = 1 } END { exit !found }'; }
pa_count_modules() { pactl list short modules | awk -v w="$1" 'index($0, w) { c++ } END { print c + 0 }'; }
pa_source_prop() { LC_ALL=C pactl list sources | awk -v n="$1" -v k="$2" '/^Source #/ { hit = 0 } $1 == "Name:" && $2 == n { hit = 1 } hit && index($0, k) { print; exit }'; }
wait_for() { local n="$1" i; shift; for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.2; done; return 1; }
peak_of() { python3 -c 'import array,sys; a=array.array("h"); d=open(sys.argv[1],"rb").read(); a.frombytes(d[:len(d)//2*2]); print(max((abs(x) for x in a), default=0))' "$1"; }
record_mic() { rm -f "$TMP_DIR/rec.raw"; timeout 2 parec -d "$1" --rate=48000 --channels=1 --format=s16le --raw > "$TMP_DIR/rec.raw" 2>/dev/null || [ "$?" -eq 124 ]; }
mic_is_loud() { record_mic PhoneMic && [ "$(peak_of "$TMP_DIR/rec.raw")" -gt 1000 ]; }
mic_is_silent() { record_mic PhoneMic && [ "$(peak_of "$TMP_DIR/rec.raw")" -lt 50 ]; }
mic_routed() { local sink; sink="$(pa_short sinks PhoneMicSink)" && pactl list short sink-inputs | awk -v s="$sink" '$2 == s { f = 1 } END { exit !f }'; }
scrcpy_alive() { pidfile_alive "$RUN_DIR/$1.pid"; }
pidfile_alive() { local pid; read -r pid _ < "$1" && kill -0 "$pid" 2>/dev/null; }
no_scrcpy_left() { ! pgrep -u "$(id -u)" -x scrcpy >/dev/null; }
set_conf() { sed -i "/^$1=/d" "$HOME/.config/phonecam/phonecam.conf"; printf "%s='%s'\n" "$1" "$2" >> "$HOME/.config/phonecam/phonecam.conf"; }

# ---- 1. A user without a phone gets guidance, not a half-started capture
run_pc status
check 'without a phone, status explains that none is authorized' has 'No authorized phone detected.'
run_pc webcam
check 'without a phone, webcam refuses and points to USB debugging' has "Enable 'USB debugging'"
check 'without a phone, no webcam process is left behind' test ! -e "$RUN_DIR/webcam.pid"

# ---- 2. Plug in the phone
plug
run_pc status
check 'after plugging in, status lists the phone serial' has 'FAKEPHONE01'
check 'status says the virtual microphone is created on first use' has "created the first time you use the microphone"
run_pc cameras
check 'cameras are listed in the real scrcpy format (back)' has '--camera-id=0'
check 'cameras are listed in the real scrcpy format (front)' has '--camera-id=1'

# ---- 3. Microphone: the virtual sink + source are created, audio is routed and really recorded
run_pc mic
check 'mic start succeeds' test "$LAST_RC" -eq 0
check 'mic start reports the virtual microphone name' has "'PhoneMic' as the audio input"
check 'virtual sink PhoneMicSink exists in PulseAudio' pa_short sinks PhoneMicSink
check 'virtual source PhoneMic exists in PulseAudio' pa_short sources PhoneMic
check 'virtual source is described as PhoneMic (the name apps list)' bash -c '[[ "$1" == *"\"PhoneMic\""* ]]' _ "$(pa_source_prop PhoneMic device.description)"
check 'virtual source is not a "Monitor of" device (apps hide those)' bash -c '[[ "$1" == *"n/a"* ]]' _ "$(pa_source_prop PhoneMic 'Monitor of Sink:')"
check 'the phone audio stream ends up on PhoneMicSink' wait_for 100 mic_routed
check 'the router logs that it moved the stream' wait_for 100 grep -q 'routed to the virtual microphone' "$HOME/.local/share/phonecam/logs/mic.log"
check 'real audio reaches the virtual microphone (non-silent recording)' mic_is_loud
check 'mic pidfile points to a live process' scrcpy_alive mic
check 'mic runs without a window and without video' grep -q -- '--no-window --no-video --no-control --require-audio --audio-source=mic' "$ARGS_LOG"
run_pc status
check 'status reports the microphone as active' has 'Microphone ACTIVE'

# ---- 4. Webcam on top of the running microphone
run_pc webcam
check 'webcam start succeeds' test "$LAST_RC" -eq 0
check 'webcam pidfile points to a live process' scrcpy_alive webcam
check 'webcam writes frames to the v4l2 device path' wait_for 50 grep -q '^frame ' "$FAKE_DEV/video42"
check 'webcam uses the configured size, fps and front camera' grep -q -- '--camera-facing=front --camera-size=1920x1080 --camera-fps=30' "$ARGS_LOG"
check 'webcam never sends scrcpy options that need control' bash -c '! grep -E -- "--(turn-screen-off|stay-awake)" "$1"' _ "$ARGS_LOG"
check 'keep-awake is applied over adb while capturing' bash -c '[ "$(cat "$1/stay_on")" = 7 ]' _ "$PHONE_DIR"
run_pc webcam
check 'a second webcam start does not spawn another process' has 'already active'

# ---- 5. Stop everything
run_pc stop
check 'stop reports PhoneCam stopped' has 'PhoneCam has been stopped.'
check 'stop leaves no scrcpy process' wait_for 25 no_scrcpy_left
check 'stop removes the capture pidfiles' bash -c '[ ! -e "$1/webcam.pid" ] && [ ! -e "$1/mic.pid" ]' _ "$RUN_DIR"
check 'stop restores the phone original stay-awake value' bash -c '[ "$(cat "$1/stay_on")" = 2 ]' _ "$PHONE_DIR"
check 'virtual microphone stays available but silent after stop' mic_is_silent

# ---- 6. Repeated start/stop must not pile up virtual devices
for _ in 1 2 3; do pc mic >/dev/null 2>&1; pc stop >/dev/null 2>&1; done
check 'three more mic cycles keep exactly one null-sink module' bash -c '[ "$(pactl list short modules | awk "index(\$0, \"sink_name=PhoneMicSink\") { c++ } END { print c + 0 }")" -eq 1 ]'
check 'three more mic cycles keep exactly one remap-source module' bash -c '[ "$(pactl list short modules | awk "index(\$0, \"source_name=PhoneMic\") { c++ } END { print c + 0 }")" -eq 1 ]'

# ---- 7. Older scrcpy versions get only the options they know
set_conf AUDIO_SOURCE mic
for v in 2.3.1 2.4 2.5 3.1.0; do
    export FAKE_SCRCPY_VERSION="$v"
    : > "$ARGS_LOG"
    run_pc both
    check "scrcpy $v: both modes start" test "$LAST_RC" -eq 0
    check "scrcpy $v: webcam and mic are both alive" bash -c 'kill -0 "$(cut -d" " -f1 "$1/webcam.pid")" && kill -0 "$(cut -d" " -f1 "$1/mic.pid")"' _ "$RUN_DIR"
    case "$v" in
        2.3.1|2.4) check "scrcpy $v: --no-window is not sent" bash -c '! grep -q -- "--no-window" "$1"' _ "$ARGS_LOG" ;;
        *)         check "scrcpy $v: --no-window is sent" grep -q -- '--no-window' "$ARGS_LOG" ;;
    esac
    pc stop >/dev/null 2>&1
done
export FAKE_SCRCPY_VERSION=3.1.0
set_conf AUDIO_SOURCE mic-unprocessed
run_pc mic
check 'scrcpy 3.1: a 3.2+ audio source is refused before launching' has 'needs scrcpy 3.2 or newer'
check 'scrcpy 3.1: the refused source leaves no process behind' test ! -e "$RUN_DIR/mic.pid"
export FAKE_SCRCPY_VERSION=3.3.3
run_pc mic
check 'scrcpy 3.3: the same audio source is accepted' test "$LAST_RC" -eq 0
pc stop >/dev/null 2>&1
set_conf AUDIO_SOURCE mic

# ---- 8. An old Android is refused with a clear message
printf '30\r\n' > "$PHONE_DIR/api"
run_pc webcam
check 'Android 11: webcam is refused with the API requirement' has 'requires Android 12+'
run_pc mic
check 'Android 11: microphone still works (needs API 30)' test "$LAST_RC" -eq 0
pc stop >/dev/null 2>&1
printf '34\r\n' > "$PHONE_DIR/api"

# ---- 9. Unplugging mid-capture: the background agent stops everything by itself
: > "$TMP_DIR/agent.log"
unplug
bash "$SCRIPT" agent >> "$TMP_DIR/agent.log" 2>&1 &
AGENT_PID=$!
sleep 1
plug
check 'agent starts webcam and microphone when the phone is plugged in' wait_for 75 bash -c '[ -e "$1/webcam.pid" ] && [ -e "$1/mic.pid" ]' _ "$RUN_DIR"
check 'agent capture is really running' wait_for 3 mic_is_loud
unplug
check 'agent stops the capture after the phone is unplugged' wait_for 80 bash -c '[ ! -e "$1/webcam.pid" ] && [ ! -e "$1/mic.pid" ]' _ "$RUN_DIR"
kill "$AGENT_PID" 2>/dev/null
wait "$AGENT_PID" 2>/dev/null || [ "$?" -ge 128 ]
plug

# ---- 10. v4l2loopback adapter: what the installer writes and loads (no kernel module needed)
cat > "$TMP_DIR/install_harness.sh" <<'HARNESS'
set -uo pipefail
source "$1"
sudo_atomic_write_file() {
    local dest="$1" mapped="$FAKE_ROOT/etc/${1#/etc/}"
    mkdir -p "$(dirname "$mapped")" && cat > "$mapped"
}
sudo() { "$@"; }
v4l2_node_exists() { [ -e "$FAKE_DEV/${1#/dev/}" ]; }
v4l2loopback_loaded() { [ -e "$FAKE_ROOT/loaded" ]; }
NONINTERACTIVE=1
cmd_install
HARNESS
FAKE_ROOT="$TMP_DIR/root"; export FAKE_ROOT
mkdir -p "$FAKE_ROOT"
rm -f "$FAKE_DEV/video42" "$HOME/.config/phonecam/phonecam.conf"
for tool in apt apt-cache systemctl getent; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$tool"; done
printf '#!/bin/sh\nexit 2\n' > "$TMP_DIR/bin/getent"
cat > "$TMP_DIR/bin/modprobe" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_ROOT/modprobe.log"
[ "${1:-}" = "-r" ] && exit 0
for a in "$@"; do case "$a" in video_nr=*) : > "$FAKE_DEV/video${a#video_nr=}"; : > "$FAKE_ROOT/loaded" ;; esac; done
SH
chmod +x "$TMP_DIR/bin"/*
INSTALL_RC=0
INSTALL_OUT="$(timeout 60 bash "$TMP_DIR/install_harness.sh" "$SCRIPT" 2>&1 < /dev/null)" || INSTALL_RC=$?
check 'installer finishes successfully' test "$INSTALL_RC" -eq 0
modconf="$FAKE_ROOT/etc/modprobe.d/phonecam-v4l2loopback.conf"
check 'installer writes the persistent v4l2loopback options' grep -Fxq 'options v4l2loopback video_nr=42 card_label="PhoneCam" exclusive_caps=1' "$modconf"
check 'installer loads the module at boot' grep -Fxq 'v4l2loopback' "$FAKE_ROOT/etc/modules-load.d/phonecam-v4l2loopback.conf"
check 'installer loads the module now with the same options' grep -Fxq 'v4l2loopback video_nr=42 card_label=PhoneCam exclusive_caps=1' "$FAKE_ROOT/modprobe.log"
check 'installer reports the virtual camera as created' bash -c '[[ "$1" == *"/dev/video42"* && "$1" == *"created"* ]]' _ "$INSTALL_OUT"
check 'default config points to the device the installer created' grep -Eq "^V4L2_DEVICE=[\"']/dev/video42[\"']" "$HOME/.config/phonecam/phonecam.conf"
check 'installed launcher starts the menu of the installed copy' grep -Fq "Exec=\"$HOME/.local/bin/phonecam\" menu" "$HOME/.local/share/applications/phonecam.desktop"
check 'installed copy is executable and identical to the script' bash -c 'cmp -s "$1" "$2" && [ -x "$1" ]' _ "$HOME/.local/bin/phonecam" "$SCRIPT"

# ---- 11. Uninstall removes the virtual audio devices from the real server
pc mic >/dev/null 2>&1
pc stop >/dev/null 2>&1
check 'before uninstall the virtual microphone exists' pa_short sources PhoneMic
sed -i "s|^V4L2_DEVICE=.*|V4L2_DEVICE='$FAKE_DEV/video42'|" "$HOME/.config/phonecam/phonecam.conf"
UNINSTALL_RC=0
UNINSTALL_OUT="$(printf 'n\n' | timeout 60 bash "$HOME/.local/bin/phonecam" uninstall 2>&1)" || UNINSTALL_RC=$?
check 'uninstall finishes successfully' test "$UNINSTALL_RC" -eq 0
check 'uninstall removes the virtual sink from PulseAudio' bash -c '! pactl list short sinks | awk "\$2 == \"PhoneMicSink\" { f = 1 } END { exit !f }"'
check 'uninstall removes the virtual source from PulseAudio' bash -c '! pactl list short sources | awk "\$2 == \"PhoneMic\" { f = 1 } END { exit !f }"'
check 'uninstall leaves unrelated PulseAudio devices alone' pa_short sinks auto_null
check 'uninstall removes the installed command and launcher' bash -c '[ ! -e "$1/.local/bin/phonecam" ] && [ ! -e "$1/.local/share/applications/phonecam.desktop" ]' _ "$HOME"
check 'uninstall keeps the configuration when the user answers no' test -f "$HOME/.config/phonecam/phonecam.conf"
check 'uninstall tells the user how to undo the v4l2loopback setup' bash -c '[[ "$1" == *"modprobe -r v4l2loopback"* ]]' _ "$UNINSTALL_OUT"

# ---- 12. Optional: every argument line produced above must satisfy the real scrcpy parser
if [ -n "${PHONECAM_REAL_SCRCPY:-}" ] && [ -x "${PHONECAM_REAL_SCRCPY:-}" ]; then
    printf '#!/bin/sh\nprintf "List of devices attached\\n"\n' > "$TMP_DIR/adb-none"
    chmod +x "$TMP_DIR/adb-none"
    real_args_ok() {
        local line out bad=0 checked=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            out="$(ADB="$TMP_DIR/adb-none" timeout 20 "$PHONECAM_REAL_SCRCPY" $line 2>&1)" || :
            checked=$((checked + 1))
            [[ "$out" == *"Could not find any ADB device"* ]] || { printf 'rejected: %s\n%s\n' "$line" "$out" >&2; bad=1; }
        done < <(sort -u "$ARGS_LOG")
        [ "$checked" -gt 0 ] && [ "$bad" -eq 0 ]
    }
    check 'real scrcpy accepts every distinct argument line the script generated' real_args_ok
fi

if [ "$FAILS" -ne 0 ]; then printf '%s check(s) failed\n' "$FAILS" >&2; exit 1; fi
printf '%s\n' 'ok - real-audio phone simulation complete'
