#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/run"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" PACTL_LOG="$TMP_DIR/pactl.log"
# A Spanish desktop session: this is what makes a real pactl translate its headers.
unset LC_ALL LC_MESSAGES
export LANG=es_ES.UTF-8

# Fake pactl that follows gettext precedence (LC_ALL > LC_MESSAGES > LANG) and
# translates the sink-input header as PulseAudio/PipeWire do in Spanish.
cat > "$TMP_DIR/bin/pactl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PACTL_LOG"
case "${1:-}:${2:-}" in
  list:sink-inputs)
    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in es*) header='Entrada del destino' ;; *) header='Sink Input' ;; esac
    printf '%s #12\n\tapplication.process.binary = "firefox"\n' "$header"
    printf '%s #44\n\tapplication.process.binary = "scrcpy"\n' "$header"
    ;;
  move-sink-input) exit 0 ;;
esac
SH
chmod +x "$TMP_DIR/bin/pactl"
export PATH="$TMP_DIR/bin:$PATH"

source "$SCRIPT"

pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
assert_eq(){ local name="$1" expected="$2" actual="$3"; if [ "$expected" = "$actual" ]; then ok "$name"; else bad "$name (expected=[$expected] actual=[$actual])"; fi; }

# normalize_language: case, region, encoding and modifier forms; anything else yields nothing.
assert_eq 'normalize_language accepts lowercase en' en "$(normalize_language en)"
assert_eq 'normalize_language accepts uppercase EN' en "$(normalize_language EN)"
assert_eq 'normalize_language accepts mixed-case Es' es "$(normalize_language Es)"
assert_eq 'normalize_language accepts en_US' en "$(normalize_language en_US)"
assert_eq 'normalize_language accepts es_ES.UTF-8' es "$(normalize_language es_ES.UTF-8)"
assert_eq 'normalize_language accepts es-MX' es "$(normalize_language es-MX)"
assert_eq 'normalize_language accepts es.UTF-8' es "$(normalize_language es.UTF-8)"
assert_eq 'normalize_language accepts es_ES@euro' es "$(normalize_language es_ES@euro)"
assert_eq 'normalize_language rejects auto' '' "$(normalize_language auto)"
assert_eq 'normalize_language rejects fr_FR.UTF-8' '' "$(normalize_language fr_FR.UTF-8)"
assert_eq 'normalize_language rejects C' '' "$(normalize_language C)"
assert_eq 'normalize_language rejects empty input' '' "$(normalize_language '')"
assert_eq 'normalize_language rejects a longer word starting with es' '' "$(normalize_language esperanto)"

# End to end: the stored preference wins, and an unknown one falls back to the system locale.
lang_for(){ ( PHONECAM_LANG="$1"; LC_ALL="" LC_MESSAGES="" LANG="$2"; set_language_context; printf '%s' "$CURRENT_LANG" ) 2>/dev/null; }
assert_eq 'PHONECAM_LANG=EN overrides a Spanish locale' en "$(lang_for EN es_ES.UTF-8)"
assert_eq 'PHONECAM_LANG=es_ES.UTF-8 overrides an English locale' es "$(lang_for es_ES.UTF-8 en_US.UTF-8)"
assert_eq 'unrecognized PHONECAM_LANG falls back to a Spanish locale' es "$(lang_for fr es_ES.UTF-8)"
assert_eq 'unrecognized PHONECAM_LANG falls back to English on C.UTF-8' en "$(lang_for fr C.UTF-8)"
assert_eq 'auto follows a bare es.UTF-8 locale' es "$(lang_for auto es.UTF-8)"

# pactl output is parsed, so it must be requested in the C locale.
check 'the fake pactl translates when the locale is not forced' grep -q 'Entrada del destino' <(pactl list sink-inputs)
check 'the fake pactl speaks English under LC_ALL=C' grep -q '^Sink Input #44' <(LC_ALL=C pactl list sink-inputs)

route_with(){ ( source "$1"; MIC_SINK_NAME=PhoneMicSink; sleep(){ :; }; route_audio_to_mic ) >/dev/null 2>&1; }
: > "$PACTL_LOG"
check 'route_audio_to_mic finds the scrcpy stream in a Spanish session' route_with "$SCRIPT"
check 'only the scrcpy stream was moved to the virtual sink' grep -Fxq 'move-sink-input 44 PhoneMicSink' "$PACTL_LOG"
check 'the unrelated stream was left alone' test "$(grep -c 'move-sink-input 12 ' "$PACTL_LOG")" -eq 0

# Mutation: without LC_ALL=C the same run must fail, or this suite proves nothing.
mutant="$TMP_DIR/phonecam-no-lc-all.sh"
sed 's/LC_ALL=C pactl list sink-inputs/pactl list sink-inputs/' "$SCRIPT" > "$mutant"
check 'mutant really lacks LC_ALL=C on the sink-input listing' test "$(grep -c 'LC_ALL=C pactl list sink-inputs' "$mutant")" -eq 0
: > "$PACTL_LOG"
if route_with "$mutant"; then bad 'route_audio_to_mic fails without LC_ALL=C under Spanish pactl'; else ok 'route_audio_to_mic fails without LC_ALL=C under Spanish pactl'; fi
check 'the mutant never moved any stream' test "$(grep -c 'move-sink-input' "$PACTL_LOG")" -eq 0

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
