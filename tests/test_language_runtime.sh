#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
cleanup() {
    if [ -f "$TMP_DIR/scrcpy.pids" ]; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            kill "$pid" 2>/dev/null || true
        done < "$TMP_DIR/scrcpy.pids"
        while read -r pid; do
            [ -n "$pid" ] || continue
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$pid" 2>/dev/null || break
                /bin/sleep 0.05
            done
            kill -9 "$pid" 2>/dev/null || true
        done < "$TMP_DIR/scrcpy.pids"
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/run" "$TMP_DIR/logs"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run"
source "$SCRIPT"
CONF_DIR="$HOME/.config/phonecam"
CONF_FILE="$CONF_DIR/phonecam.conf"
RUN_DIR="$TMP_DIR/run/phonecam"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
assert_eq(){ local name="$1" expected="$2" actual="$3"; if [ "$expected" = "$actual" ]; then ok "$name"; else bad "$name (expected=$expected actual=$actual)"; fi; }
assert_contains(){ local name="$1" haystack="$2" needle="$3"; if [[ "$haystack" == *"$needle"* ]]; then ok "$name"; else bad "$name (missing=$needle)"; fi; }

# Locale contract: LC_ALL wins; otherwise LC_MESSAGES decides; non-Spanish defaults to English.
assert_eq 'LC_ALL overrides Spanish' en "$(LC_ALL=C LC_MESSAGES=es_ES.UTF-8 LANG=es_ES.UTF-8 bash -c 'source "$1"; detect_system_language' _ "$SCRIPT")"
assert_eq 'LC_MESSAGES selects Spanish' es "$(LC_ALL= LC_MESSAGES=es_ES.UTF-8 LANG=en_US.UTF-8 bash -c 'source "$1"; detect_system_language' _ "$SCRIPT" 2>/dev/null)"
assert_eq 'non-Spanish locale defaults to English' en "$(LC_ALL= LC_MESSAGES=C LANG=en_GB.UTF-8 bash -c 'source "$1"; detect_system_language' _ "$SCRIPT")"

# Runtime preference: auto follows locale, explicit values override it, and toggle persists.
printf '%s\n' 'PHONECAM_LANG=auto' > "$CONF_FILE"
auto_lang="$(HOME="$HOME" LC_ALL= LC_MESSAGES=es_ES.UTF-8 LANG=en_US.UTF-8 bash -c 'source "$1"; CONF_DIR="$2"; CONF_FILE="$3"; RUN_DIR="$4"; LOG_DIR="$5"; load_config >/dev/null 2>&1; printf "%s" "$CURRENT_LANG"' _ "$SCRIPT" "$CONF_DIR" "$CONF_FILE" "$RUN_DIR" "$LOG_DIR" 2>/dev/null)"
assert_eq 'auto preference follows Spanish locale' es "$auto_lang"
set_config PHONECAM_LANG en
set_language_context
assert_eq 'explicit English preference' en "$CURRENT_LANG"
toggle_language >/dev/null
assert_eq 'toggle English -> Spanish' es "$CURRENT_LANG"
grep -Fxq "PHONECAM_LANG='es'" "$CONF_FILE" && ok 'Spanish toggle persisted' || bad 'Spanish toggle persisted'
toggle_language >/dev/null
assert_eq 'toggle Spanish -> English' en "$CURRENT_LANG"
grep -Fxq "PHONECAM_LANG='en'" "$CONF_FILE" && ok 'English toggle persisted' || bad 'English toggle persisted'

# Runtime lookup must still return the selected language; catalog completeness is tested separately.
load_messages
assert_eq 'message catalog loaded at runtime' true "$(if [ "${#MSG_EN[@]}" -ge 200 ]; then printf true; else printf false; fi)"
CURRENT_LANG=en
write_default_config 42
assert_contains 'default config is translated to English' "$(cat "$CONF_FILE")" '#  PhoneCam - configuration'
if grep -Fq 'configuración' "$CONF_FILE"; then bad 'English default config has no Spanish prose'; else ok 'English default config has no Spanish prose'; fi
CURRENT_LANG=es
write_default_config 43
assert_contains 'default config is translated to Spanish' "$(cat "$CONF_FILE")" '#  PhoneCam - configuración'
if grep -Fq '#  PhoneCam - configuration' "$CONF_FILE"; then bad 'Spanish default config has no English header'; else ok 'Spanish default config has no English header'; fi
en_msg="$(CURRENT_LANG=en t PHONE_DETECTED SERIAL1)"; es_msg="$(CURRENT_LANG=es t PHONE_DETECTED SERIAL1)"; expected=$'Phone detected (SERIAL1).\nWhat would you like to start now?|Teléfono detectado (SERIAL1).\n¿Qué quieres iniciar ahora?'; assert_eq 'runtime message switches language' "$expected" "${en_msg}|${es_msg}"
assert_eq 'language_name names the active language' 'English|Español' "$(CURRENT_LANG=en language_name)|$(CURRENT_LANG=es language_name)"

# Differential capture contract: with identical machine configuration, English and
# Spanish must produce byte-for-byte identical scrcpy argv for webcam, mic and both.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/v4l2"
cat > "$TMP_DIR/bin/adb" <<'SH'
#!/bin/sh
case "${1:-}" in
    devices)
        printf 'List of devices attached\nSERIAL1\tdevice\n'
        ;;
    -s)
        [ "${2:-}" = SERIAL1 ] || exit 1
        shift 2
        [ "${1:-}" = shell ] || exit 0
        shift
        case "${1:-}" in
            getprop) [ "${2:-}" = ro.build.version.sdk ] && printf '35\n' ;;
            *) exit 0 ;;
        esac
        ;;
    *) exit 0 ;;
esac
SH
cat > "$TMP_DIR/bin/scrcpy" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
    printf 'scrcpy 3.0\n'
    exit 0
fi
printf '%s\n' "$$" >> "$SCRCPY_PIDS"
printf '%s\n' "$*" >> "$SCRCPY_LOG"
/bin/sleep 1000 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
SH
cat > "$TMP_DIR/bin/pactl" <<'SH'
#!/bin/sh
case "${1:-}:${2:-}:${3:-}" in
    list:short:sinks) printf '1\tPhoneMicSink\n' ;;
    list:short:sources) printf '2\tPhoneMic\n' ;;
    list:short:modules) printf '10\tmodule-null-sink\t sink_name=PhoneMicSink\n11\tmodule-remap-source\t source_name=PhoneMic\n' ;;
    list:sink-inputs:) printf 'Sink Input #44\n application.process.binary = "scrcpy"\n' ;;
    *) exit 0 ;;
esac
SH
cat > "$TMP_DIR/bin/nohup" <<'SH'
#!/bin/sh
exec "$@"
SH
cat > "$TMP_DIR/bin/timeout" <<'SH'
#!/bin/sh
shift
exec "$@"
SH
chmod +x "$TMP_DIR/bin"/*
PATH="$TMP_DIR/bin:$PATH"
export PATH SCRCPY_LOG="$TMP_DIR/scrcpy-language.log" SCRCPY_PIDS="$TMP_DIR/scrcpy.pids"
touch "$TMP_DIR/v4l2/video42"
V4L2_DEVICE="$TMP_DIR/v4l2/video42"
CAMERA_ID=""
CAMERA_FACING=front
CAMERA_SIZE=1280x720
CAMERA_FPS=60
VIDEO_QUALITY_PROFILE=max
AUDIO_SOURCE=mic
AUDIO_CODEC=aac
AUDIO_BITRATE=256K
TURN_SCREEN_OFF=true
KEEP_AWAKE=false
MIC_SINK_NAME=PhoneMicSink
MIC_SOURCE_NAME=PhoneMic
RUN_DIR="$TMP_DIR/run/phonecam"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"
PID_WEBCAM="$RUN_DIR/webcam.pid"
PID_MIC="$RUN_DIR/mic.pid"
PID_ROUTE="$RUN_DIR/route.pid"
export V4L2_DEVICE CAMERA_ID CAMERA_FACING CAMERA_SIZE CAMERA_FPS VIDEO_QUALITY_PROFILE AUDIO_SOURCE AUDIO_CODEC AUDIO_BITRATE TURN_SCREEN_OFF KEEP_AWAKE MIC_SINK_NAME MIC_SOURCE_NAME RUN_DIR LOG_DIR PID_WEBCAM PID_MIC PID_ROUTE
capture_lang_args(){
    local lang="$1" mode="$2"
    local log="$TMP_DIR/argv-$lang-$mode.log"
    : > "$SCRCPY_LOG"
    CURRENT_LANG="$lang"
    case "$mode" in
        webcam) start_webcam >/dev/null 2>&1 ;;
        mic) start_mic >/dev/null 2>&1 ;;
        both) start_both >/dev/null 2>&1 ;;
    esac
    cat "$SCRCPY_LOG" > "$log"
    stop_all >/dev/null 2>&1
}
for mode in webcam mic both; do
    capture_lang_args en "$mode"
    capture_lang_args es "$mode"
    assert_eq "scrcpy argv language-invariant: $mode" "$(cat "$TMP_DIR/argv-en-$mode.log")" "$(cat "$TMP_DIR/argv-es-$mode.log")"
done

# Machine values must remain language-invariant too.
CAMERA_ID=7
CAMERA_FACING=front
CAMERA_SIZE=1920x1080
CAMERA_FPS=30
VIDEO_QUALITY_PROFILE=balanced
AUDIO_SOURCE=mic
AUDIO_CODEC=opus
AUDIO_BITRATE=192K
TURN_SCREEN_OFF=true
KEEP_AWAKE=false
for lang in en es; do
    CURRENT_LANG="$lang"
    build_camera_args
    camera_args="${CAMERA_ARGS[*]}"
    signature="$camera_args|$(video_codec)|$(video_bitrate)|$CAMERA_FPS|$AUDIO_SOURCE|$AUDIO_CODEC|$AUDIO_BITRATE"
    printf '%s\n' "$signature" > "$TMP_DIR/signature-$lang"
done
assert_eq 'functional signature is language-invariant' "$(cat "$TMP_DIR/signature-en")" "$(cat "$TMP_DIR/signature-es")"

# CLI language switch uses the same persistence path as the GUI.
printf 'PHONECAM_LANG=en\n' > "$CONF_FILE"
bash "$SCRIPT" l >/dev/null 2>&1
grep -Fxq "PHONECAM_LANG='es'" "$CONF_FILE" && ok 'CLI L switch en -> es' || bad 'CLI L switch en -> es'
bash "$SCRIPT" l >/dev/null 2>&1
grep -Fxq "PHONECAM_LANG='en'" "$CONF_FILE" && ok 'CLI L switch es -> en' || bad 'CLI L switch es -> en'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
