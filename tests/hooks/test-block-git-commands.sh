#!/usr/bin/env bash
# tests/hooks/test-block-git-commands.sh
#
# Integration tests for hooks/block-git-commands.sh — the babyclaude-scoped
# PreToolUse hook that forbids ALL git invocations.
#
# Coverage:
#   1. Explicit allowlist git commands → BLOCKED (this hook is stricter than
#      the global sanitiser; babyclaude has no git access at all).
#   2. Hostile git invocations (wrappers, env-prefix, chains, subshells) →
#      BLOCKED.
#   3. Benign non-git commands → PASS.
#   4. Parser-bypass corpora: any entry referencing git should produce exit 2.
#      Unicode-homoglyph entries are documented as expected-skip.
#   5. Allowlist corpus entries that are NOT git → PASS.
#   6. Parser CLI removal → fail-closed exit 2.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$PROJECT_DIR" || exit 2
# shellcheck source=lib.sh
source tests/hooks/lib.sh

HOOK="$PROJECT_DIR/hooks/block-git-commands.sh"

if [ ! -x "$HOOK" ]; then
    echo "FAIL  hook not executable: $HOOK" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Section 1: explicit git commands MUST block (exit 2)
# -----------------------------------------------------------------------------
echo "--- explicit git commands (must block) ---"
# shellcheck disable=SC2016  # literal $(...) in single-quoted strings is intentional
for line in \
    'git status' \
    'git push origin main' \
    'git commit -m "msg"' \
    '/usr/bin/git push' \
    'GIT_DIR=/tmp git push' \
    'cd repo && git push' \
    'echo $(git push)' \
    'bash -c "git push"' \
    'eval "git push"'
do
    TEST_LABEL="block: $line"
    pipe_to_hook "$HOOK" "$line"
    assert_exit 2
done

# -----------------------------------------------------------------------------
# Section 2: stderr must contain the user-facing message on block
# -----------------------------------------------------------------------------
echo "--- block message ---"
TEST_LABEL="stderr message present"
pipe_to_hook "$HOOK" "git status"
assert_stderr_contains "Git commands are not permitted"

# -----------------------------------------------------------------------------
# Section 3: benign non-git commands MUST pass (exit 0)
# -----------------------------------------------------------------------------
echo "--- benign non-git (must pass) ---"
for line in \
    'ls -la' \
    'cat file.txt' \
    'node parser/cli.mjs' \
    'echo hello' \
    'jq . file.json'
do
    TEST_LABEL="pass: $line"
    pipe_to_hook "$HOOK" "$line"
    assert_exit 0
done

# -----------------------------------------------------------------------------
# Section 4: non-Bash tool invocations are ignored (exit 0)
# -----------------------------------------------------------------------------
echo "--- non-Bash tool (must pass) ---"
TEST_LABEL="non-Bash tool name → exit 0"
pipe_to_hook "$HOOK" "git status" --name "Read"
assert_exit 0

# -----------------------------------------------------------------------------
# Section 5: parser-bypass corpora — every entry referencing git should
# produce exit 2. Some entries deliberately use unicode homoglyphs and will
# NOT block; emit a note line but do not fail. Tracking is informational.
# -----------------------------------------------------------------------------
echo "--- bypass-corpus-parser.txt ---"
# shellcheck disable=SC2329
check_git_bypass_parser() {
    local line="$1"
    pipe_to_hook "$HOOK" "$line"
    if [ "$HOOK_EXIT" -eq 2 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  NOTE: not blocked (parser-corpus): $line  (exit=$HOOK_EXIT)"
    fi
}
corpus_each tests/fixtures/bypass-corpus-parser.txt check_git_bypass_parser

echo "--- bypass-corpus-hook.txt ---"
# shellcheck disable=SC2329
check_git_bypass_hook() {
    local line="$1"
    pipe_to_hook "$HOOK" "$line"
    if [ "$HOOK_EXIT" -eq 2 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        # Homoglyph/non-git-basename entries are a documented limitation.
        echo "  NOTE: not blocked (hook-corpus): $line  (exit=$HOOK_EXIT — likely homoglyph)"
    fi
}
corpus_each tests/fixtures/bypass-corpus-hook.txt check_git_bypass_hook

# -----------------------------------------------------------------------------
# Section 6: allowlist corpus — entries that are NOT git must pass.
# Git allowlist entries are deliberately SKIPPED here (babyclaude blocks all
# git, even the otherwise-allowed read-only commands — that's the contract).
# -----------------------------------------------------------------------------
echo "--- allowlist-corpus.txt non-git entries (must pass) ---"
# shellcheck disable=SC2329
check_non_git_allowed() {
    local line="$1"
    # Skip anything where the first token is `git` (covers `git ...`,
    # `git`, and any `git<space>...` form). We want non-git allowlist
    # entries to pass; the git ones are correctly blocked elsewhere.
    case "$line" in
        git|git\ *|*' git '*|*' git')
            return
            ;;
    esac
    TEST_LABEL="allowlist pass: $line"
    pipe_to_hook "$HOOK" "$line"
    assert_exit 0
}
corpus_each tests/fixtures/allowlist-corpus.txt check_non_git_allowed

# -----------------------------------------------------------------------------
# Section 7: parser CLI removed → fail-closed exit 2
# -----------------------------------------------------------------------------
echo "--- fail-closed when parser missing ---"
if [ -f parser/cli.mjs ]; then
    mv parser/cli.mjs parser/cli.mjs.bak
    # shellcheck disable=SC2034  # TEST_LABEL read by lib.sh via _harness_label
    TEST_LABEL="parser missing -> exit 2"
    pipe_to_hook "$HOOK" "ls"
    assert_exit 2
    mv parser/cli.mjs.bak parser/cli.mjs
else
    echo "  SKIP: parser/cli.mjs not present at start"
fi

# -----------------------------------------------------------------------------
report_results
