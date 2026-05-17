#!/usr/bin/env bash
# tests/hooks/test-git-branch-guard.sh — integration test for the
# parser-backed git-branch-guard hook.
#
# Asserts:
#   1. Allowlisted git subcommands → exit 0.
#   2. Disallowed git subcommands → exit 2.
#   3. Non-git commands → exit 0 (out of scope).
#   4. Every parser-bypass-corpus entry → exit 2 (parser-level reject).
#   5. Hook-bypass-corpus entries → exit 2 where the parser surfaces git as
#      a basename (the unicode-homoglyph category is a documented limitation
#      and is allowed to slip; noted but not failed).
#   6. Parser CLI missing → fail closed (exit 2).
#
# Honours $CLAUDE_PROJECT_DIR if set; otherwise resolves relative to this
# script. Restores any pre-existing .claude/execute-state.json on exit.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$PROJECT_DIR" || exit 2

# shellcheck source=tests/hooks/lib.sh
source tests/hooks/lib.sh

HOOK="$PROJECT_DIR/hooks/git-branch-guard.sh"

# Force-enable executing state for the duration of the test. Stash any
# pre-existing state file so we don't trample the developer's workflow.
ORIG_STATE=""
HAD_ORIG_STATE=0
if [ -f .claude/execute-state.json ]; then
    ORIG_STATE=$(cat .claude/execute-state.json)
    HAD_ORIG_STATE=1
fi
cleanup() {
    if [ "$HAD_ORIG_STATE" -eq 1 ]; then
        printf '%s' "$ORIG_STATE" > .claude/execute-state.json
    else
        rm -f .claude/execute-state.json
    fi
    # Restore parser if a fail-closed test moved it.
    if [ -f parser/cli.mjs.test-bak ]; then
        mv parser/cli.mjs.test-bak parser/cli.mjs
    fi
}
trap cleanup EXIT
mkdir -p .claude
echo '{"status":"executing"}' > .claude/execute-state.json

# Translate corpus surrogates: literal "\n" -> real newline, "\t" -> real
# tab. The fixtures store multi-line bypass attempts as single-line
# surrogates (see tests/fixtures/README.md §"Line format"). The harness
# must un-escape before feeding the parser, otherwise here-doc, line-
# continuation, and embedded-newline entries are sent verbatim and the
# parser sees a benign single-line string.
translate_surrogates() {
    # shellcheck disable=SC2059
    printf '%b' "$1"
}

# ---------------------------------------------------------------------------
# Test 1: allowlisted git subcommands → exit 0
# ---------------------------------------------------------------------------
echo "--- Test 1: allowlisted git subcommands → exit 0"
ALLOWED_CMDS=(
    'git add file.txt'
    'git status'
    'git diff --stat'
    'git log --oneline -5'
    'git show HEAD'
    'git ls-files'
    'git check-ignore -v build/'
    'git rev-parse HEAD'
    'git symbolic-ref HEAD'
    'git commit -m "ok"'
    'git config --get user.email'
    'git config --list'
    'git config --get-all remote.origin.fetch'
    'git config --get-regexp ^user\.'
)
for cmd in "${ALLOWED_CMDS[@]}"; do
    TEST_LABEL="allow: $cmd"
    pipe_to_hook "$HOOK" "$cmd"
    assert_exit 0
done

# ---------------------------------------------------------------------------
# Test 2: disallowed git subcommands → exit 2
# ---------------------------------------------------------------------------
echo "--- Test 2: disallowed git subcommands → exit 2"
BLOCKED_CMDS=(
    'git push origin main'
    'git merge feature'
    'git checkout main'
    'git rebase main'
    'git stash'
    'git cherry-pick abc123'
    'git reset --hard HEAD'
    'git clean -fd'
    'git branch -d topic'
    'git tag v1.0.0'
    'git fetch origin'
    'git pull'
    'git revert HEAD'
    'git switch main'
    'git config user.email me@example.com'
)
for cmd in "${BLOCKED_CMDS[@]}"; do
    TEST_LABEL="block: $cmd"
    pipe_to_hook "$HOOK" "$cmd"
    assert_exit 2
done

# ---------------------------------------------------------------------------
# Test 3: non-git commands → exit 0 (out of scope for this hook)
# ---------------------------------------------------------------------------
echo "--- Test 3: non-git commands → exit 0"
NONGIT_CMDS=(
    'ls -la'
    'cat file.txt'
    'node parser/cli.mjs'
    'jq . package.json'
    'rg foo'
)
for cmd in "${NONGIT_CMDS[@]}"; do
    TEST_LABEL="non-git: $cmd"
    pipe_to_hook "$HOOK" "$cmd"
    assert_exit 0
done

# ---------------------------------------------------------------------------
# Test 4: parser-bypass-corpus — every entry MUST be blocked
# ---------------------------------------------------------------------------
echo "--- Test 4: parser-bypass-corpus → exit 2"
check_parser_bypass() {
    local line="$1"
    local category="${2:-}"
    local cmd
    cmd=$(translate_surrogates "$line")
    TEST_LABEL="parser-bypass[$category]: $line"
    pipe_to_hook "$HOOK" "$cmd"
    assert_exit 2
}
corpus_each tests/fixtures/bypass-corpus-parser.txt check_parser_bypass

# ---------------------------------------------------------------------------
# Test 5: hook-bypass-corpus — for entries where the parser surfaces a
# command with `git` as its basename, the hook MUST exit 2. For entries
# where the parser surfaces a different basename (e.g. `g$IFSit`,
# `*git*`, `echo` because the literal `git` is hidden behind quoting,
# globbing, parameter expansion, comment-newline tricks, or unicode
# homoglyphs), the git-branch-guard is not the right enforcement layer
# — those bypasses surface as non-git basenames and are handled by
# downstream policy hooks. We record those as NOTEs and do not fail.
#
# This matches the corpus split documented in tests/fixtures/README.md:
# parser surfaces ok with `git` ⇒ git-branch-guard's responsibility;
# parser surfaces ok with non-git basename ⇒ a different hook's job.
# ---------------------------------------------------------------------------
echo "--- Test 5: hook-bypass-corpus (entries surfacing git as basename → exit 2)"
HOOK_SLIPS=0
check_hook_bypass() {
    local line="$1"
    local category="${2:-}"
    local cmd parser_out has_git_basename
    cmd=$(translate_surrogates "$line")
    TEST_LABEL="hook-bypass[$category]: $line"

    # Probe the parser to see whether any surfaced command has basename git.
    parser_out=$(jq -cn --arg c "$cmd" \
        '{version:1, tool_name:"Bash", tool_input:{command:$c}}' \
        | node "$PROJECT_DIR/parser/cli.mjs" 2>/dev/null || true)
    has_git_basename=$(printf '%s' "$parser_out" \
        | jq -r '(.commands // []) | map(.basename) | index("git") // "no"' \
        2>/dev/null || printf 'no')

    pipe_to_hook "$HOOK" "$cmd"

    if [ "$has_git_basename" = "no" ]; then
        # Parser did not surface a literal git basename — out of scope for
        # this hook. Record but don't fail.
        if [ "$HOOK_EXIT" -ne 2 ]; then
            HOOK_SLIPS=$((HOOK_SLIPS + 1))
            printf 'NOTE  %s  (non-git basename in parser output; exit=%s)\n' \
                "$TEST_LABEL" "$HOOK_EXIT"
        else
            PASS_COUNT=$((PASS_COUNT + 1))
            printf 'PASS  %s  (exit=2)\n' "$TEST_LABEL"
        fi
        return
    fi

    assert_exit 2
}
corpus_each tests/fixtures/bypass-corpus-hook.txt check_hook_bypass

# ---------------------------------------------------------------------------
# Test 6: parser CLI missing → fail closed (exit 2)
# ---------------------------------------------------------------------------
echo "--- Test 6: parser CLI missing → fail closed"
mv parser/cli.mjs parser/cli.mjs.test-bak
TEST_LABEL="fail-closed: parser CLI missing"
pipe_to_hook "$HOOK" 'git status'
assert_exit 2
mv parser/cli.mjs.test-bak parser/cli.mjs

echo
echo "Hook-bypass slips (non-git basename in parser output; out of scope here): $HOOK_SLIPS"
report_results
