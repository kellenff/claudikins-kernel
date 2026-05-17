#!/bin/bash
# git-branch-guard.sh — PreToolUse hook for /execute
# Parser-backed allowlist of git subcommands; rejects others by exit 2.
#
# Matcher: Bash (only checks bash commands)
# Exit codes:
#   0 - Command allowed
#   2 - Command blocked (parser reject OR disallowed git subcommand)
#
# Implementation: thin shim over parser/cli.mjs. The parser does all the
# lexical bypass detection (wrapper shells, command substitution, eval,
# var-as-command, shell keywords, etc.). This shim then walks the parsed
# commands[] and applies the git-subcommand allowlist policy.
#
# Fails closed: any internal failure (parser missing, parser crash,
# malformed CLI output) → exit 2.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_FILE="$PROJECT_DIR/.claude/execute-state.json"
CLI="$PLUGIN_ROOT/parser/cli.mjs"

# Allowlist of git subcommands safe during task execution.
ALLOWED_GIT_SUBCMDS="add status diff log show ls-files check-ignore rev-parse symbolic-ref commit"
# Read-only git config flags.
ALLOWED_CONFIG_FLAGS="--get --list --get-all --get-regexp"

INPUT=$(cat)

# Only enforce on Bash tool calls.
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only enforce during executing state.
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi
STATUS=$(jq -r '.status // ""' "$STATE_FILE" 2>/dev/null || echo "")
if [ "$STATUS" != "executing" ]; then
    exit 0
fi

# Fail closed if the parser is missing or unreadable.
if [ ! -f "$CLI" ]; then
    echo "BLOCKED: parser CLI not found at $CLI (fail-closed)" >&2
    exit 2
fi

# Run the parser. The parser exits 0 for both ok and reject verdicts;
# exit 1 signals an internal CLI failure (e.g. no input). Either way,
# a missing/empty output is treated as fail-closed.
CLI_OUTPUT=$(printf '%s' "$INPUT" | node "$CLI" 2>/dev/null) || {
    echo "BLOCKED: parser CLI internal failure (fail-closed)" >&2
    exit 2
}

if [ -z "$CLI_OUTPUT" ]; then
    echo "BLOCKED: parser CLI returned no output (fail-closed)" >&2
    exit 2
fi

VERDICT=$(echo "$CLI_OUTPUT" | jq -r '.verdict // "ERROR"' 2>/dev/null || echo "ERROR")

# Parser rejected the input → block.
if [ "$VERDICT" = "reject" ]; then
    REASON=$(echo "$CLI_OUTPUT" | jq -r '.reject_reason // "unknown"')
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .toolInput.command // ""')
    echo "BLOCKED: parser rejected command — reason: $REASON" >&2
    echo "Command: $COMMAND" >&2
    exit 2
fi

if [ "$VERDICT" != "ok" ]; then
    echo "BLOCKED: unexpected parser verdict: $VERDICT (fail-closed)" >&2
    exit 2
fi

# Parser verdict ok — walk commands[] and enforce git allowlist.
BLOCK_REASON=""
BLOCKED_SUBCMD=""

while IFS= read -r cmd; do
    BASENAME=$(echo "$cmd" | jq -r '.basename // ""')
    if [ "$BASENAME" != "git" ]; then
        continue   # non-git in command position is out of scope here
    fi

    SUBCMD=$(echo "$cmd" | jq -r '.argv[1] // ""')

    # Allowlisted plain subcommand?
    if echo " $ALLOWED_GIT_SUBCMDS " | grep -q " $SUBCMD "; then
        continue
    fi

    # Special-case git config — allow only read flags.
    if [ "$SUBCMD" = "config" ]; then
        FLAG=$(echo "$cmd" | jq -r '.argv[2] // ""')
        if echo " $ALLOWED_CONFIG_FLAGS " | grep -q " $FLAG "; then
            continue
        fi
        BLOCKED_SUBCMD="config $FLAG"
        BLOCK_REASON="git config write operation (only read flags allowed: $ALLOWED_CONFIG_FLAGS)"
        break
    fi

    BLOCKED_SUBCMD="$SUBCMD"
    BLOCK_REASON="git subcommand '$SUBCMD' not in allowlist"
    break
done < <(echo "$CLI_OUTPUT" | jq -c '.commands[]')

if [ -n "$BLOCK_REASON" ]; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .toolInput.command // ""')
    echo "BLOCKED: $BLOCK_REASON" >&2
    echo "" >&2
    echo "Command: $COMMAND" >&2
    echo "Subcommand: $BLOCKED_SUBCMD" >&2
    echo "" >&2
    echo "Allowed git subcommands: $ALLOWED_GIT_SUBCMDS" >&2
    echo "Read-only git config flags: $ALLOWED_CONFIG_FLAGS" >&2
    echo "" >&2
    echo "If you need other git operations, complete your task first." >&2
    exit 2
fi

exit 0
