#!/usr/bin/env bash
# sanitize-bash.sh — PreToolUse/Bash hook.
#
# Parser-backed shim. Approves, blocks, or rewrites Bash-tool commands via
# the JSON envelope shape defined by Claude Code:
#   {"decision":"approve"}                                       — pass through
#   {"decision":"approve","updatedInput":{"command":"..."}}      — rewrite
#   {"decision":"block","reason":"..."}                          — refuse
#
# Policy preserved from the previous regex-based hook:
#   1. `git commit` with no -m / --message / --no-edit etc. → inject --no-edit.
#   2. `rm -rf` (or -r / -fr variants) targeting /, ~, $HOME → block.
# Everything else either passes through or is rejected by the parser CLI
# (parser/cli.mjs) on the way in.
#
# Input precedence: stdin first (read once it is known not to be a TTY),
# falling back to the CLAUDE_HOOK_INPUT env var so the existing kernel
# call-convention keeps working.
#
# All JSON output is emitted via `jq -n` (or a fixed printf literal for the
# trivial approve case) — never via string interpolation.
#
# Fails closed: if the parser CLI cannot be invoked or errors out, we emit
# a block decision rather than letting an unparseable command through.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLI="$PLUGIN_ROOT/parser/cli.mjs"

emit_approve() { printf '{"decision":"approve"}\n'; }
emit_block()   { jq -n --arg r "$1" '{decision:"block", reason:$r}'; }
emit_rewrite() { jq -n --arg c "$1" '{decision:"approve", updatedInput:{command:$c}}'; }

# ---- read input (stdin > env) ---------------------------------------------
INPUT=""
if [ ! -t 0 ]; then
    INPUT=$(cat 2>/dev/null || true)
fi
if [ -z "$INPUT" ] && [ -n "${CLAUDE_HOOK_INPUT:-}" ]; then
    INPUT="$CLAUDE_HOOK_INPUT"
fi
if [ -z "$INPUT" ]; then
    emit_approve
    exit 0
fi

# Extract command — accept snake_case (preferred) and camelCase (legacy).
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .toolInput.command // ""' 2>/dev/null || true)
if [ -z "$COMMAND" ]; then
    emit_approve
    exit 0
fi

# ---- forward to parser CLI -------------------------------------------------
if [ ! -f "$CLI" ]; then
    emit_block "parser CLI missing (fail-closed)"
    exit 0
fi

CLI_OUTPUT=$(printf '%s' "$INPUT" | node "$CLI" 2>/dev/null) || {
    emit_block "parser CLI internal failure (fail-closed)"
    exit 0
}
if [ -z "$CLI_OUTPUT" ]; then
    emit_block "parser CLI returned empty output (fail-closed)"
    exit 0
fi

VERDICT=$(printf '%s' "$CLI_OUTPUT" | jq -r '.verdict // "ERROR"' 2>/dev/null || echo "ERROR")
if [ "$VERDICT" = "ERROR" ]; then
    emit_block "parser CLI returned invalid verdict (fail-closed)"
    exit 0
fi

if [ "$VERDICT" = "reject" ]; then
    REASON=$(printf '%s' "$CLI_OUTPUT" | jq -r '.reject_reason // "unknown"' 2>/dev/null || echo "unknown")
    emit_block "Parser rejected: $REASON"
    exit 0
fi

# ---- Rule 1: rm -rf on /, ~, $HOME → block --------------------------------
DANGER=$(printf '%s' "$CLI_OUTPUT" | jq -r '
  .commands[]
  | select(.basename == "rm")
  | .argv as $a
  | if ($a | any(. == "-rf" or . == "-r" or . == "-fr" or . == "-Rf" or . == "-fR" or . == "-rfR" or . == "-rRf"))
       and ($a | any(. == "/" or . == "~" or . == "$HOME" or . == "$HOME/"))
    then "DANGER"
    else empty
    end
' 2>/dev/null || true)
if [ -n "$DANGER" ]; then
    # shellcheck disable=SC2016
    emit_block 'Refusing to rm -rf on /, ~, or $HOME'
    exit 0
fi

# ---- Rule 2: git commit without -m / --message / --no-edit → rewrite ------
# Match the prior regex-based scope: single command, basename git, argv[1] == commit,
# no -m*, --message, --no-edit, or other message-source flags anywhere in argv.
GIT_COMMIT_NEEDS_NOEDIT=$(printf '%s' "$CLI_OUTPUT" | jq -r '
  if (.commands | length) == 1
     and (.commands[0].basename == "git")
     and ((.commands[0].argv | length) >= 2)
     and (.commands[0].argv[1] == "commit")
     and ((.commands[0].argv
           | any(startswith("-m")
                 or . == "--message"
                 or . == "--no-edit"
                 or . == "-c"
                 or . == "-C"
                 or . == "--reedit-message"
                 or . == "--reuse-message"
                 or . == "--squash"
                 or . == "--fixup"
                 or . == "--file"
                 or startswith("--file=")
                 or startswith("--message="))) | not)
  then "YES"
  else "NO"
  end
' 2>/dev/null || echo "NO")

if [ "$GIT_COMMIT_NEEDS_NOEDIT" = "YES" ]; then
    emit_rewrite "$COMMAND --no-edit"
    exit 0
fi

emit_approve
