#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/phonecam.sh"
TMP_DIR="$(mktemp -d)"
chmod 755 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
export HOME="$TMP_DIR/home" XDG_RUNTIME_DIR="$TMP_DIR/run" PATH="$TMP_DIR/bin:$PATH"
for stub in pactl systemctl; do printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/$stub"; chmod +x "$TMP_DIR/bin/$stub"; done

source "$SCRIPT"

pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok - %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'not ok - %s\n' "$1" >&2; }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
refuse(){ local name="$1"; shift; if "$@"; then bad "$name"; else ok "$name"; fi; }

# Fresh 777 tree per run so the unprivileged uninstall user can delete what root created.
fresh_home(){ rm -rf "$TMP_DIR/home" "$TMP_DIR/run"; mkdir -p "$TMP_DIR/home/.config/phonecam" "$TMP_DIR/run"; printf "AUTO_MODE='off'\n" > "$TMP_DIR/home/.config/phonecam/phonecam.conf"; chmod -R 777 "$TMP_DIR/home" "$TMP_DIR/run"; }
# runuser resets HOME for the target user, so the isolated paths are passed on explicitly.
run_as_user(){ if [ "$(id -u)" -eq 0 ]; then runuser -u nobody -- env HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH="$PATH" "$@"; else "$@"; fi; }
[ "$(id -u)" -ne 0 ] || command -v runuser >/dev/null 2>&1 || { echo 'runuser is required to drop root for the uninstall cases' >&2; exit 1; }

# ---------- Yes/no answers: either language, any case, whole words ----------
answers(){ ask_yn '?' "$2" <<< "$1" >/dev/null 2>&1; }
for word in y Y yes YES Yes s S si SI Si sí Sí; do
    check "ask_yn takes '$word' as yes" answers "$word" n
done
for word in n N no NO nunca yess ss; do
    refuse "ask_yn takes '$word' as no" answers "$word" y
done
check 'ask_yn empty answer keeps a yes default' answers '' y
refuse 'ask_yn empty answer keeps a no default' answers '' n
check_c_locale(){ LC_ALL=C bash -c 'source "$1"; ask_yn "?" n <<< "$2" >/dev/null 2>&1' _ "$SCRIPT" "$1"; }
check 'ask_yn takes an uppercase accented SÍ as yes in the C locale' check_c_locale 'SÍ'
check 'ask_yn takes an accented sí as yes in the C locale' check_c_locale 'sí'

# ---------- Uninstall: the "remove configuration" prompt uses the same rule ----------
config_survives(){ fresh_home; run_as_user bash "$SCRIPT" uninstall <<< "$1" >/dev/null 2>&1; [ -d "$TMP_DIR/home/.config/phonecam" ]; }
refuse 'uninstall removes the configuration when answered sí' config_survives 'sí'
refuse 'uninstall removes the configuration when answered yes' config_survives 'yes'
check 'uninstall keeps the configuration when answered n' config_survives 'n'
check 'uninstall keeps the configuration on an empty answer' config_survives ''

# ---------- PHONECAM_LANG in the environment outranks the stored preference ----------
lang_conf(){ fresh_home; printf "PHONECAM_LANG='%s'\n" "$1" > "$TMP_DIR/home/.config/phonecam/phonecam.conf"; }
help_out(){ env -u PHONECAM_LANG -u LC_MESSAGES LC_ALL="$1" "${@:2}" bash "$SCRIPT" help 2>&1; }
lang_conf en
check 'PHONECAM_LANG=es in the environment beats an English config' grep -q 'Uso:' <(help_out C PHONECAM_LANG=es)
check 'the stored English preference applies without the variable' grep -q 'Usage:' <(help_out C)
check 'PHONECAM_LANG=auto in the environment follows a Spanish locale over a stored English' grep -q 'Uso:' <(help_out es_ES.UTF-8 PHONECAM_LANG=auto)
plain_var_lang(){ env -u PHONECAM_LANG LC_ALL=C bash -c 'PHONECAM_LANG=es; source "$1"; load_language_preference; printf %s "$CURRENT_LANG"' _ "$SCRIPT"; }
check 'an unexported PHONECAM_LANG left by an earlier source does not override the config' test "$(plain_var_lang)" = en
toggle_out(){ env -u PHONECAM_LANG LC_ALL=C PHONECAM_LANG=es bash "$SCRIPT" l 2>&1; }
check 'the language toggle replaces an environment override for the rest of the run' grep -q 'Language changed to English' <(toggle_out)
check 'the language toggle stores the opposite of the forced language' grep -Fxq "PHONECAM_LANG='en'" "$TMP_DIR/home/.config/phonecam/phonecam.conf"

# ---------- zenity error dialogs: & < > must not reach the Pango markup parser raw ----------
export ZENITY_ARGS="$TMP_DIR/zenity.args"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "$ZENITY_ARGS"\ncase "$1" in --forms) printf "%%s\\n" "${ZENITY_RESULT:-}" ;; esac\n' > "$TMP_DIR/bin/zenity"; chmod +x "$TMP_DIR/bin/zenity"
escaped(){ ( shopt -"$1" patsub_replacement 2>/dev/null; markup_escape 'a < b & c > d &lt;' ); }
for mode in s u; do
    check "markup_escape escapes & < > and only once with patsub_replacement -$mode" test "$(escaped "$mode")" = 'a &lt; b &amp; c &gt; d &amp;lt;'
done
check 'markup_escape keeps line breaks' test "$(markup_escape $'x<\ny&')" = $'x&lt;\ny&amp;'
dialog_text(){ : > "$ZENITY_ARGS"; ( source "$1"; run_gui_action bash -c 'echo "cost <5 & more"; exit 3' ) >/dev/null 2>&1 || :; grep -- '^--text=' "$ZENITY_ARGS"; }
check 'run_gui_action escapes markup in the error dialog text' test "$(dialog_text "$SCRIPT")" = '--text=cost &lt;5 &amp; more'
mutant="$TMP_DIR/phonecam-raw-dialog.sh"
sed 's/\$(markup_escape "\$out")/$out/' "$SCRIPT" > "$mutant"
check 'without the escape the same dialog gets the raw markup characters' test "$(dialog_text "$mutant")" = '--text=cost <5 & more'
: > "$ZENITY_ARGS"; run_gui_action true; run_gui_action bash -c 'exit 4' || :
check 'run_gui_action shows no dialog on success or on a silent failure' test ! -s "$ZENITY_ARGS"
: > "$ZENITY_ARGS"; gui_error 460 'plain text'
check 'gui_error passes the kind, the width and the text to zenity' test "$(grep -c -Fx -e '--error' -e '--width=460' -e '--text=plain text' "$ZENITY_ARGS")" -eq 3
form_dialog(){ : > "$ZENITY_ARGS"; ( export DISPLAY=:0 ZENITY_RESULT="$1"; advanced_settings_gui ) >/dev/null 2>&1 || :; grep -- '^--text=' "$ZENITY_ARGS" | tail -1; }
check 'a form field holding the separator opens the error dialog' grep -q "^--text=Nothing was saved: a field contains the '|'" <(form_dialog 'back|1920x1080|30|balanced|mic|opus|192K|ask|false|true|extra')
form_dialog 'back|1080p|30|balanced|mic|opus|192K|ask|false|true' >/dev/null || :
check 'a badly formatted form field opens the error dialog naming the field' grep -q '^Resolution: use WIDTHxHEIGHT' "$ZENITY_ARGS"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
