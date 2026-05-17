#!/usr/bin/env bash
# Top-level test runner for claudikins-kernel.
#
# Orchestrates every check in the right order. Hard steps fail the run;
# the drift check is soft (warning only). Reports a summary banner at the
# end and exits with the aggregated HARD-step status.
#
# Usage:
#   tests/run.sh
#
# Honours $CLAUDE_PROJECT_DIR if set; otherwise resolves the project root
# relative to this script.

set -uo pipefail
# Note: no -e — we want to capture exit codes ourselves, not bail on first fail.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$PROJECT_DIR" || exit 2

OVERALL=0
SECTIONS=()

run_section() {
    local label="$1"; shift
    echo "============================================================"
    echo "  $label"
    echo "============================================================"
    if "$@"; then
        SECTIONS+=("PASS  $label")
    else
        SECTIONS+=("FAIL  $label")
        OVERALL=1
    fi
    echo
}

# 1. HARD: shellcheck (severity=error; warnings are surfaced but non-fatal,
#    matching the task spec wording "Exit non-zero on any shellcheck error")
run_section "shellcheck" \
    shellcheck -S error \
        hooks/*.sh \
        tests/run.sh \
        tests/cli-corpus-smoke.sh \
        tests/hooks/lib.sh \
        tools/check-shell-quote-version.sh

# 2. HARD: parser unit tests
run_section "parser unit tests" node --test tests/parser/cli.test.mjs

# 3. HARD: CLI corpus smoke
run_section "CLI corpus smoke" tests/cli-corpus-smoke.sh

# 4. HARD: hook integration tests (none yet; Batch 4 will add)
# shellcheck disable=SC2329  # invoked indirectly via run_section "$@"
hook_tests_ok() {
    local found=0 fail=0 test
    for test in tests/hooks/test-*.sh; do
        [ -f "$test" ] || continue
        found=$((found + 1))
        if bash "$test"; then
            echo "  PASS  $test"
        else
            echo "  FAIL  $test"
            fail=$((fail + 1))
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "  (no hook integration tests found — skipped)"
    fi
    [ "$fail" -eq 0 ]
}
run_section "hook integration tests" hook_tests_ok

# 5. SOFT: drift check (warning only)
echo "============================================================"
echo "  shell-quote upstream drift (soft)"
echo "============================================================"
if tools/check-shell-quote-version.sh; then
    SECTIONS+=("PASS  shell-quote drift (no drift)")
else
    rc=$?
    SECTIONS+=("WARN  shell-quote drift (rc=$rc)")
    echo "WARN: drift check returned $rc — non-fatal"
fi
echo

# Summary
echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
for line in "${SECTIONS[@]}"; do
    echo "  $line"
done

if [ "$OVERALL" -eq 0 ]; then
    echo
    echo "ALL HARD CHECKS PASSED"
else
    echo
    echo "SOME HARD CHECKS FAILED"
fi

exit "$OVERALL"
