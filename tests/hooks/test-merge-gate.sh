#!/usr/bin/env bash
# tests/hooks/test-merge-gate.sh — integration tests for hooks/merge-gate.sh.
#
# Covers:
#   - Non-merge commands pass through.
#   - Non-task-branch merges pass through.
#   - Task-branch merges require a passing verdict.
#   - Missing verdicts / FAIL verdicts are blocked.
#   - Chained command forms (cd && git merge ...) are caught by the parser walker.
#   - Parser CLI internal failure → fail closed.

set -uo pipefail
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$PROJECT_DIR" || exit 2
# shellcheck source=tests/hooks/lib.sh
# shellcheck disable=SC1091
source tests/hooks/lib.sh

HOOK="$PROJECT_DIR/hooks/merge-gate.sh"

# Use a sentinel task-id that is highly unlikely to collide with real reviews.
TEST_TASK_ID="testmergegate99"
REVIEW_DIR="$PROJECT_DIR/.claude/reviews"
VERDICT_DIR="$REVIEW_DIR/$TEST_TASK_ID"
VERDICT_FILE="$VERDICT_DIR/verdict.json"

# Ensure baseline state - capture preexisting verdict if any (paranoia) so the
# cleanup trap restores cleanly even if the script is re-run interactively.
PRE_EXISTING_VERDICT=""
if [ -f "$VERDICT_FILE" ]; then
    PRE_EXISTING_VERDICT=$(cat "$VERDICT_FILE")
fi

cleanup() {
    if [ -n "$PRE_EXISTING_VERDICT" ]; then
        printf '%s' "$PRE_EXISTING_VERDICT" > "$VERDICT_FILE"
    else
        rm -f "$VERDICT_FILE"
        # Only remove the dir if we created it and it's empty.
        rmdir "$VERDICT_DIR" 2>/dev/null || true
    fi
    # Restore parser CLI if a test moved it aside.
    if [ -f "$PROJECT_DIR/parser/cli.mjs.test-bak" ]; then
        mv "$PROJECT_DIR/parser/cli.mjs.test-bak" "$PROJECT_DIR/parser/cli.mjs"
    fi
}
trap cleanup EXIT

mkdir -p "$VERDICT_DIR"
printf '{"spec_review":"PASS","code_review":"PASS"}\n' > "$VERDICT_FILE"

# ---------------------------------------------------------------------------
# Test 1: non-merge commands pass through (exit 0)
# ---------------------------------------------------------------------------
for line in 'git status' 'git push origin main' 'ls' 'echo hi'; do
    TEST_LABEL="non-merge passes: $line"
    pipe_to_hook "$HOOK" "$line"
    assert_exit 0
done

# ---------------------------------------------------------------------------
# Test 2: merge of a non-task branch passes through
# ---------------------------------------------------------------------------
TEST_LABEL="merge non-task branch (main) passes"
pipe_to_hook "$HOOK" 'git merge main'
assert_exit 0

TEST_LABEL="merge non-task branch (feature/foo) passes"
pipe_to_hook "$HOOK" 'git merge feature/foo'
assert_exit 0

# ---------------------------------------------------------------------------
# Test 3: task-branch merge with PASS verdicts → exit 0
# ---------------------------------------------------------------------------
TEST_LABEL="task branch with PASS spec + PASS code → allowed"
pipe_to_hook "$HOOK" "git merge execute/task-${TEST_TASK_ID}-foo-abc123"
assert_exit 0

# 3b: code_review = CONCERNS_ACCEPTED is also allowed (preserve original policy)
printf '{"spec_review":"PASS","code_review":"CONCERNS_ACCEPTED"}\n' > "$VERDICT_FILE"
TEST_LABEL="task branch with PASS spec + CONCERNS_ACCEPTED code → allowed"
pipe_to_hook "$HOOK" "git merge execute/task-${TEST_TASK_ID}-foo-abc123"
assert_exit 0

# Reset to PASS/PASS for subsequent tests.
printf '{"spec_review":"PASS","code_review":"PASS"}\n' > "$VERDICT_FILE"

# ---------------------------------------------------------------------------
# Test 4: missing verdict file → exit 2
# ---------------------------------------------------------------------------
TEST_LABEL="task branch with no verdict file → blocked"
pipe_to_hook "$HOOK" 'git merge execute/task-doesnotexistxyz-foo-abc123'
assert_exit 2
assert_stderr_contains "No review verdict found"

# ---------------------------------------------------------------------------
# Test 5: FAIL spec verdict → exit 2
# ---------------------------------------------------------------------------
printf '{"spec_review":"FAIL","code_review":"PASS"}\n' > "$VERDICT_FILE"
TEST_LABEL="task branch with FAIL spec → blocked"
pipe_to_hook "$HOOK" "git merge execute/task-${TEST_TASK_ID}-foo-abc123"
assert_exit 2
assert_stderr_contains "Spec review did not pass"

# 5b: FAIL code verdict → blocked
printf '{"spec_review":"PASS","code_review":"FAIL"}\n' > "$VERDICT_FILE"
TEST_LABEL="task branch with FAIL code → blocked"
pipe_to_hook "$HOOK" "git merge execute/task-${TEST_TASK_ID}-foo-abc123"
assert_exit 2
assert_stderr_contains "Code review did not pass"

# Reset to PASS/PASS.
printf '{"spec_review":"PASS","code_review":"PASS"}\n' > "$VERDICT_FILE"

# ---------------------------------------------------------------------------
# Test 6: chained merge — parser walker should catch `cd repo && git merge X`
# ---------------------------------------------------------------------------
TEST_LABEL="chained: cd repo && git merge <task-branch> with PASS → allowed"
pipe_to_hook "$HOOK" "cd repo && git merge execute/task-${TEST_TASK_ID}-foo-abc123"
assert_exit 0

TEST_LABEL="chained: cd repo && git merge <task-branch> with missing verdict → blocked"
pipe_to_hook "$HOOK" "cd repo && git merge execute/task-doesnotexistxyz-foo-abc123"
assert_exit 2

TEST_LABEL="chained with semicolon: git status ; git merge <task-branch> with PASS → allowed"
pipe_to_hook "$HOOK" "git status ; git merge execute/task-${TEST_TASK_ID}-foo-abc123"
assert_exit 0

TEST_LABEL="chained with pipe-after: git merge main is not blocked"
pipe_to_hook "$HOOK" "git status | head -n1 ; git merge main"
assert_exit 0

# ---------------------------------------------------------------------------
# Test 7: non-Bash tool calls pass through
# ---------------------------------------------------------------------------
TEST_LABEL="non-Bash tool (Read) passes through"
pipe_to_hook "$HOOK" 'git merge execute/task-doesnotexistxyz-foo-abc123' --name Read
assert_exit 0

# ---------------------------------------------------------------------------
# Test 8: parser CLI internal failure → fail closed (exit 2)
# ---------------------------------------------------------------------------
mv "$PROJECT_DIR/parser/cli.mjs" "$PROJECT_DIR/parser/cli.mjs.test-bak"
TEST_LABEL="parser CLI missing → fail closed"
pipe_to_hook "$HOOK" 'git merge main'
assert_exit 2
assert_stderr_contains "parser CLI internal failure"
mv "$PROJECT_DIR/parser/cli.mjs.test-bak" "$PROJECT_DIR/parser/cli.mjs"

# ---------------------------------------------------------------------------
# Test 9: parser-rejected forms (subshells, var-as-command, etc.) → exit 0
# We don't want merge-gate to fight with other gates on rejected commands.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # TEST_LABEL read indirectly by lib.sh assert helpers
TEST_LABEL="parser-rejected (subshell wrapper) → pass through"
pipe_to_hook "$HOOK" '(git merge execute/task-doesnotexistxyz-foo-abc123)'
assert_exit 0

report_results
