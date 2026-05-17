#!/bin/bash
# merge-gate.sh - PreToolUse hook for Bash.
# Blocks "git merge" of a task branch unless a passing review verdict exists.
# This is the HARD GATE that prevents skipping reviews even under context drift.
#
# Detection of "is this a git merge command" is parser-backed (calls
# parser/cli.mjs). That walks all command positions and yields a clean
# basename + argv per command, so chained forms (`cd repo && git merge X`)
# and command substitution / wrapper forms are handled uniformly.
#
# Verdict-file lookup and task-id slug extraction remain string-based on the
# branch name - those are intentional, the branch name is a stable identifier.
#
# Matcher: Bash
# Exit codes:
#   0 - Merge allowed (review passed) or not a merge command
#   2 - Merge blocked (no review, review failed, parser internal failure)

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLI="$PLUGIN_ROOT/parser/cli.mjs"

# Read JSON input from stdin
INPUT=$(cat)

# Only inspect Bash tool calls.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Run the parser. We pass the full envelope on stdin; cli.mjs reads
# tool_input.command itself. Internal failure (exit != 0) is fail-closed.
if ! CLI_OUTPUT=$(printf '%s' "$INPUT" | node "$CLI" 2>/dev/null); then
    echo "MERGE BLOCKED: parser CLI internal failure (fail-closed)" >&2
    exit 2
fi

VERDICT=$(printf '%s' "$CLI_OUTPUT" | jq -r '.verdict // "ERROR"')

# Parser-rejected commands (wrappers, malformed input, shell keywords, etc.)
# fall to other hooks - merge-gate is specifically about git merge in a
# well-formed command line. We can't safely inspect rejected forms.
if [ "$VERDICT" != "ok" ]; then
    exit 0
fi

# Scan commands[] for any entry whose basename == "git" and argv[1] == "merge".
MERGE_TARGET=""
while IFS= read -r cmd; do
    BASENAME=$(printf '%s' "$cmd" | jq -r '.basename')
    SUBCMD=$(printf '%s' "$cmd" | jq -r '.argv[1] // ""')
    if [ "$BASENAME" = "git" ] && [ "$SUBCMD" = "merge" ]; then
        # First positional argument after `merge` is the branch.
        # `git merge` may take flags before the branch; walk argv looking
        # for the first non-flag token after "merge".
        ARGC=$(printf '%s' "$cmd" | jq -r '.argv | length')
        i=2
        while [ "$i" -lt "$ARGC" ]; do
            ARG=$(printf '%s' "$cmd" | jq -r --argjson i "$i" '.argv[$i]')
            case "$ARG" in
                -*)
                    # Flag, skip.
                    ;;
                *)
                    MERGE_TARGET="$ARG"
                    break
                    ;;
            esac
            i=$((i + 1))
        done
        break
    fi
done < <(printf '%s' "$CLI_OUTPUT" | jq -c '.commands[]')

# No git merge in the command line - allow.
if [ -z "$MERGE_TARGET" ]; then
    # Edge case: `git merge` with no branch name. Original hook blocked this
    # "for safety". Preserve that behaviour ONLY when the parser saw a git
    # merge with no positional target.
    HAD_MERGE=$(printf '%s' "$CLI_OUTPUT" | \
        jq -r '[.commands[] | select(.basename == "git" and (.argv[1] // "") == "merge")] | length')
    if [ "$HAD_MERGE" != "0" ]; then
        echo "Cannot determine branch being merged. Merge blocked for safety." >&2
        exit 2
    fi
    exit 0
fi

# Extract task ID from branch name.
# Format: execute/task-{id}-{slug}-{uuid}
# Branch name is a stable identifier; regex-on-string is correct here.
TASK_ID=$(printf '%s' "$MERGE_TARGET" | sed -nE 's|^execute/task-([^-]+)-.*|\1|p')

if [ -z "$TASK_ID" ]; then
    # Not a task branch (e.g. `git merge main`). Only task branches require
    # review.
    exit 0
fi

# Check for review verdict.
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

# Check verdict status.
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

# Both reviews passed - allow merge.
exit 0
