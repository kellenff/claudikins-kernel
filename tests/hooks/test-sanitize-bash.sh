#!/usr/bin/env bash
# tests/hooks/test-sanitize-bash.sh — integration tests for the parser-backed
# sanitize-bash hook. Verifies:
#   - every output is valid JSON
#   - rewrite branch returns decision=approve (NOT decision=allow)
#   - git commit (bare) rewrites to inject --no-edit
#   - rm -rf / and rm -rf ~ block
#   - parser-bypass corpus entries block at the hook
#   - both stdin and CLAUDE_HOOK_INPUT envelopes are accepted
#   - parser CLI failure fails closed (decision=block)
#
# Run from the project root:
#   bash tests/hooks/test-sanitize-bash.sh
# Exit 0 on all PASS; non-zero if any assertion FAILED.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$PROJECT_DIR" || exit 2
# shellcheck source=tests/hooks/lib.sh
source tests/hooks/lib.sh

HOOK="$PROJECT_DIR/hooks/sanitize-bash.sh"
CLI="$PROJECT_DIR/parser/cli.mjs"

if [ ! -x "$HOOK" ]; then
    echo "FAIL: hook not executable: $HOOK" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Test 1: every output is valid JSON for a range of tricky inputs.
# ---------------------------------------------------------------------------
test_json_valid() {
    local cmd="$1"
    pipe_to_hook "$HOOK" "$cmd" --env --camel
    TEST_LABEL="json-valid: $cmd"
    if printf '%s' "$HOOK_STDOUT" | jq -e . >/dev/null 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS  %s\n' "$TEST_LABEL"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s (invalid JSON)\n' "$TEST_LABEL"
        printf '      stdout: %s\n' "$HOOK_STDOUT"
    fi
}
test_json_valid 'ls'
test_json_valid 'git status'
test_json_valid 'echo "with \"quotes\""'
test_json_valid "echo 'with single quotes'"
test_json_valid 'echo a b c'

# ---------------------------------------------------------------------------
# Test 2: approve for normal commands.
# ---------------------------------------------------------------------------
TEST_LABEL="approve ls -la"
pipe_to_hook "$HOOK" 'ls -la' --env --camel
assert_stdout_jq '.decision == "approve"'

# ---------------------------------------------------------------------------
# Test 3: git commit (no -m) → rewrite to add --no-edit, decision=approve.
# ---------------------------------------------------------------------------
TEST_LABEL="git commit → rewrite decision"
pipe_to_hook "$HOOK" 'git commit' --env --camel
assert_stdout_jq '.decision == "approve"'
TEST_LABEL="git commit → rewrite payload"
assert_stdout_jq '.updatedInput.command == "git commit --no-edit"'

# ---------------------------------------------------------------------------
# Test 4: git commit -m "..." → pass through (no rewrite).
# ---------------------------------------------------------------------------
TEST_LABEL='git commit -m → pass-through decision'
pipe_to_hook "$HOOK" 'git commit -m "fix"' --env --camel
assert_stdout_jq '.decision == "approve"'
TEST_LABEL='git commit -m → no updatedInput'
assert_stdout_jq '(.updatedInput // null) == null'

# ---------------------------------------------------------------------------
# Test 5: git commit --no-edit (already present) → pass through.
# ---------------------------------------------------------------------------
TEST_LABEL='git commit --no-edit → pass-through'
pipe_to_hook "$HOOK" 'git commit --no-edit' --env --camel
assert_stdout_jq '.decision == "approve"'
assert_stdout_jq '(.updatedInput // null) == null'

# ---------------------------------------------------------------------------
# Test 6: rm -rf / and rm -rf ~ block; rm -rf /tmp/foo approves.
# ---------------------------------------------------------------------------
TEST_LABEL='rm -rf / → block'
pipe_to_hook "$HOOK" 'rm -rf /' --env --camel
assert_stdout_jq '.decision == "block"'

TEST_LABEL='rm -rf ~ → block'
pipe_to_hook "$HOOK" 'rm -rf ~' --env --camel
assert_stdout_jq '.decision == "block"'

TEST_LABEL='rm -r / → block'
pipe_to_hook "$HOOK" 'rm -r /' --env --camel
assert_stdout_jq '.decision == "block"'

TEST_LABEL='rm -rf /tmp/foo → approve'
pipe_to_hook "$HOOK" 'rm -rf /tmp/foo' --env --camel
assert_stdout_jq '.decision == "approve"'

# ---------------------------------------------------------------------------
# Test 7: parser-bypass corpus → block at the hook (parser-level reject).
# We require each line to result in decision=block.
# ---------------------------------------------------------------------------
# Corpus entries use \n / \t surrogates per tests/fixtures/README.md; translate
# them to real newline / tab bytes with `printf '%b'` before feeding the hook,
# matching the convention used by tests/cli-corpus-smoke.sh.
translate_surrogates() {
    # shellcheck disable=SC2059
    printf '%b' "$1"
}

check_bypass_blocked() {
    local raw="$1"
    local category="${2:-uncategorised}"
    local line
    line=$(translate_surrogates "$raw")
    TEST_LABEL="bypass-corpus[$category]: $raw"
    pipe_to_hook "$HOOK" "$line" --env --camel
    if printf '%s' "$HOOK_STDOUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS  %s\n' "$TEST_LABEL"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s (not blocked)\n' "$TEST_LABEL"
        printf '      stdout: %s\n' "$HOOK_STDOUT"
    fi
}
corpus_each tests/fixtures/bypass-corpus-parser.txt check_bypass_blocked

# ---------------------------------------------------------------------------
# Test 8: stdin path also works (camelCase envelope on stdin, no env var).
# ---------------------------------------------------------------------------
TEST_LABEL='stdin envelope → approve ls'
pipe_to_hook "$HOOK" 'ls' --camel
assert_stdout_jq '.decision == "approve"'

TEST_LABEL='stdin envelope (snake_case) → approve'
pipe_to_hook "$HOOK" 'ls'
assert_stdout_jq '.decision == "approve"'

TEST_LABEL='stdin envelope → git commit rewrite'
pipe_to_hook "$HOOK" 'git commit'
assert_stdout_jq '.decision == "approve"'
assert_stdout_jq '.updatedInput.command == "git commit --no-edit"'

# ---------------------------------------------------------------------------
# Test 9: never returns "allow" (only approve or block).
# ---------------------------------------------------------------------------
test_no_allow() {
    local cmd="$1"
    pipe_to_hook "$HOOK" "$cmd" --env --camel
    TEST_LABEL="no-allow: $cmd"
    if printf '%s' "$HOOK_STDOUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s (got decision=allow)\n' "$TEST_LABEL"
    else
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS  %s\n' "$TEST_LABEL"
    fi
}
test_no_allow 'git commit'
test_no_allow 'git status'
test_no_allow 'rm -rf /'
test_no_allow 'ls -la'

# ---------------------------------------------------------------------------
# Test 10: parser CLI failure → fail-closed (decision=block).
# Temporarily move the CLI out of the way; restore unconditionally via trap.
# ---------------------------------------------------------------------------
BACKUP="$CLI.bak.$$"
restore_cli() {
    if [ -f "$BACKUP" ]; then
        mv "$BACKUP" "$CLI"
    fi
}
trap restore_cli EXIT

if [ -f "$CLI" ]; then
    mv "$CLI" "$BACKUP"
    TEST_LABEL='parser missing → fail-closed (block)'
    pipe_to_hook "$HOOK" 'ls' --env --camel
    assert_stdout_jq '.decision == "block"'
    restore_cli
    trap - EXIT
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL  parser CLI not found at %s, cannot run fail-closed test\n' "$CLI"
fi

# ---------------------------------------------------------------------------
report_results
