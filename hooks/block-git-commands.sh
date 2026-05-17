#!/bin/bash
# block-git-commands.sh — PreToolUse hook for babyclaude agent.
#
# Blocks ANY Bash command where `git` appears in command position.
# This is the babyclaude-scoped enforcement layer: even otherwise-allowlisted
# git commands (status/diff/log) are forbidden inside babyclaude, because the
# orchestrator owns all git operations.
#
# Implementation: defers to parser/cli.mjs (the static lexical analyser) and
# inspects the resulting commands[] for any basename == "git".
#
#   - Parser verdict "reject"            → exit 2 (any parser-class bypass)
#   - Parser verdict "ok" + git basename → exit 2 (policy block)
#   - Parser internal failure (exit 1)   → exit 2 (fail-closed)
#   - Anything else                      → exit 0
#
# Exit 2 with a stderr message is the Claude Code contract for "block the
# tool call and surface this text back to the agent".
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLI="$PLUGIN_ROOT/parser/cli.mjs"

DENY_MSG="Git commands are not permitted. You work in an isolated worktree - the orchestrator handles all git operations (commit, merge, push)."

INPUT=$(cat)

# Only interested in Bash tool calls. Any other tool: pass through.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Run the parser. We capture stdout separately from rc so we can distinguish
# "parser failed internally" (rc != 0, fail closed) from "parser emitted JSON".
CLI_OUTPUT=$(printf '%s' "$INPUT" | node "$CLI" 2>/dev/null) || {
    echo "$DENY_MSG" >&2
    echo "Parser internal failure — failing closed." >&2
    exit 2
}

# Defensive: parser succeeded but emitted no/garbage stdout.
if [ -z "$CLI_OUTPUT" ]; then
    echo "$DENY_MSG" >&2
    echo "Parser produced empty output — failing closed." >&2
    exit 2
fi

VERDICT=$(printf '%s' "$CLI_OUTPUT" | jq -r '.verdict // "ERROR"')

# Any parser-class bypass (wrapper, subshell, meta-command, etc.) → block.
# The parser's reject reasons cover meta_command_bash/sh/env/eval,
# wrapper_form_$(/subshell/redirect_<, argv_wrapper_substring, var_as_command,
# shell_keyword_*, malformed_input — all of which are bypass attempts that
# could be smuggling a git invocation past a basename check.
if [ "$VERDICT" = "reject" ]; then
    REASON=$(printf '%s' "$CLI_OUTPUT" | jq -r '.reject_reason // "unknown"')
    echo "$DENY_MSG" >&2
    echo "Parser rejected: $REASON" >&2
    exit 2
fi

# Parser OK — inspect surfaced basenames. Any `git` in command position blocks.
if printf '%s' "$CLI_OUTPUT" | jq -e '[.commands[].basename] | any(. == "git")' >/dev/null 2>&1; then
    echo "$DENY_MSG" >&2
    exit 2
fi

exit 0
