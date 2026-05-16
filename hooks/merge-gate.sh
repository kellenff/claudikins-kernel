#!/bin/bash
# merge-gate.sh - PreToolUse hook for Bash
# Blocks "git merge" unless review verdict exists with PASS status.
# This is the HARD GATE that prevents skipping reviews even under context drift.
#
# Matcher: Bash
# Exit codes:
#   0 - Merge allowed (review passed) or not a merge command
#   2 - Merge blocked (no review or review failed)

# Tool detection: prefer ripgrep (PCRE2, cross-platform) when available;
# otherwise fall back to BSD/GNU-portable grep -E + sed -nE. Never use grep -P
# (PCRE) directly - BSD grep on macOS does not support it.
if command -v rg >/dev/null 2>&1; then
    HAVE_RG=1
else
    HAVE_RG=0
fi

# match_pcre PCRE_PATTERN ERE_PATTERN INPUT
#   Returns 0 if INPUT matches the pattern, 1 otherwise.
match_pcre() {
    if [ "$HAVE_RG" = "1" ]; then
        printf '%s' "$3" | rg -qP "$1"
    else
        printf '%s' "$3" | grep -qE "$2"
    fi
}

# extract_pcre PCRE_PATTERN_WITH_K ERE_PATTERN_WITH_CAPTURE INPUT
#   Prints the first match. PCRE uses \K to fix the match start;
#   ERE uses a capture group (\1) consumed by sed.
extract_pcre() {
    if [ "$HAVE_RG" = "1" ]; then
        printf '%s' "$3" | rg -oP "$1" | head -n1
    else
        printf '%s' "$3" | sed -nE "s/.*${2}.*/\1/p" | head -n1
    fi
}

# Read JSON input from stdin
INPUT=$(cat)

# Extract the command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Check if this is a git merge command
if ! match_pcre \
    '(^git\s+merge|[|;&]\s*git\s+merge)' \
    '(^git[[:space:]]+merge|[|;&][[:space:]]*git[[:space:]]+merge)' \
    "$COMMAND"; then
    # Not a merge command - allow
    exit 0
fi

# Extract branch name being merged (if present)
# Patterns: "git merge branch-name", "git merge origin/branch"
MERGE_BRANCH=$(extract_pcre \
    'git\s+merge\s+\K[^\s;|&]+' \
    'git[[:space:]]+merge[[:space:]]+([^[:space:];|&]+)' \
    "$COMMAND")

if [ -z "$MERGE_BRANCH" ]; then
    echo "Cannot determine branch being merged. Merge blocked for safety." >&2
    exit 2
fi

# Extract task ID from branch name
# Format: execute/task-{id}-{slug}-{uuid}
TASK_ID=$(extract_pcre \
    'task-\K[^-]+' \
    'task-([^-]+)' \
    "$MERGE_BRANCH")

if [ -z "$TASK_ID" ]; then
    # Not a task branch - might be a regular merge, allow it
    # (Only task branches require review)
    exit 0
fi

# Check for review verdict
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
REVIEW_DIR="$PROJECT_DIR/.claude/reviews"
VERDICT_FILE="$REVIEW_DIR/${TASK_ID}/verdict.json"

if [ ! -f "$VERDICT_FILE" ]; then
    echo "MERGE BLOCKED: No review verdict found for task ${TASK_ID}" >&2
    echo "" >&2
    echo "Required: $VERDICT_FILE" >&2
    echo "" >&2
    echo "You MUST run spec-reviewer and code-reviewer before merging." >&2
    echo "Both must PASS for merge to proceed." >&2
    exit 2
fi

# Check verdict status
SPEC_STATUS=$(jq -r '.spec_review // "MISSING"' "$VERDICT_FILE")
CODE_STATUS=$(jq -r '.code_review // "MISSING"' "$VERDICT_FILE")

if [ "$SPEC_STATUS" != "PASS" ]; then
    echo "MERGE BLOCKED: Spec review did not pass" >&2
    echo "" >&2
    echo "Spec review status: $SPEC_STATUS" >&2
    echo "Code review status: $CODE_STATUS" >&2
    echo "" >&2
    echo "Fix the spec review issues before merging." >&2
    exit 2
fi

if [ "$CODE_STATUS" != "PASS" ] && [ "$CODE_STATUS" != "CONCERNS_ACCEPTED" ]; then
    echo "MERGE BLOCKED: Code review did not pass" >&2
    echo "" >&2
    echo "Spec review status: $SPEC_STATUS" >&2
    echo "Code review status: $CODE_STATUS" >&2
    echo "" >&2
    echo "Fix the code review issues or explicitly accept concerns before merging." >&2
    exit 2
fi

# Both reviews passed - allow merge
exit 0
