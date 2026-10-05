#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export PYTHONDONTWRITEBYTECODE=1
unset PHONECAM_LANG   # an exported value would override every stored preference under test
export PHONECAM_START_GRACE=0   # skips the post-launch liveness wait of each start; tests of that wait set their own
export PHONECAM_DISPLAY_WAIT=0   # the agent does not wait for a graphical session; tests of that wait set their own
run_suite() {
    local label="$1"; shift
    printf '== %s ==\n' "$label"
    timeout "${SUITE_TIMEOUT:-90}s" "$@"   # a hung suite fails here instead of stalling the run
}
run_suite localization python3 tests/test_localization.py
run_suite ui-aesthetics python3 tests/test_ui_aesthetics.py
run_suite function-inventory python3 tests/test_function_inventory.py
run_suite suite-quality python3 tests/test_suite_quality.py
run_suite portability python3 tests/test_portability.py
run_suite language-runtime bash tests/test_language_runtime.sh
run_suite locale-independence bash tests/test_locale_independence.sh
run_suite terminal-menu bash tests/test_terminal_menu.sh
run_suite cli-matrix bash tests/test_cli_matrix.sh
run_suite gui-dispatch bash tests/test_gui_dispatch.sh
run_suite user-simulation bash tests/test_user_simulation.sh
run_suite function-matrix bash tests/test_function_matrix.sh
run_suite agent-lifecycle bash tests/test_agent_lifecycle.sh
run_suite agent-session bash tests/test_agent_session.sh
run_suite scrcpy-consent bash tests/test_scrcpy_consent.sh
run_suite uninstall-modules bash tests/test_uninstall_modules.sh
run_suite review-fixes bash tests/test_review_fixes.sh
SUITE_TIMEOUT=180 run_suite capture-regression bash tests/test_capture_regression.sh   # 58-72 s measured: 90 s left no margin on a slow machine
run_suite edge-cases bash tests/test_edge_cases.sh
run_suite install-lifecycle bash tests/test_install_lifecycle.sh
SUITE_TIMEOUT=150 run_suite real-phone-simulation bash tests/test_real_phone_simulation.sh   # private PulseAudio + stateful fake phone; skips itself when pulseaudio is absent
run_suite walkthrough-en bash tests/walkthrough_en.sh
run_suite syntax bash -n script/phonecam.sh
for test_script in tests/*.sh; do
    run_suite "syntax-$test_script" bash -n "$test_script"
done
printf '%s\n' 'ALL TEST SUITES PASSED'
