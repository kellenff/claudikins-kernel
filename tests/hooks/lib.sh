#!/usr/bin/env bash
# tests/hooks/lib.sh — shared harness for Bash-driven hook integration tests.
#
# Sourced by tests/hooks/test-*.sh. Provides:
#   - pipe_to_hook         : invoke a hook with a Bash-tool envelope on stdin
#                            (or via CLAUDE_HOOK_INPUT) and capture stdout /
#                            stderr / exit.
#   - assert_exit          : assert HOOK_EXIT == expected.
#   - assert_stdout_jq     : assert a jq -e expression matches HOOK_STDOUT.
#   - assert_stderr_contains : assert HOOK_STDERR contains a literal substring.
#   - corpus_each          : iterate non-comment, non-blank lines of a corpus
#                            file, tracking the most recent `# category: <x>`
#                            annotation and calling a user-supplied function.
#   - report_results       : print PASS/FAIL summary; non-zero exit on failure.
#
# Globals (initialised below):
#   PASS_COUNT, FAIL_COUNT  : running tallies updated by the assert_* helpers.
#   HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT : last pipe_to_hook invocation.
#
# Intentionally NOT `set -e` aware on its own — callers control errexit. The
# helpers tolerate non-zero hook exits because we test those explicitly.

# shellcheck shell=bash

PASS_COUNT=0
FAIL_COUNT=0
HOOK_STDOUT=""
HOOK_STDERR=""
# Sentinel: -1 means "pipe_to_hook has not been called yet". assert_exit treats
# this as a hard test-author error rather than letting `assert_exit 0` silently
# pass against a stale value.
HOOK_EXIT=-1

# _harness_label — best-effort label for the most recent assertion, used by the
# assert_* helpers in their PASS/FAIL lines. Callers may set TEST_LABEL before
# an assertion to make output more legible; we fall back to a generic tag.
_harness_label() {
    if [ -n "${TEST_LABEL:-}" ]; then
        printf '%s' "$TEST_LABEL"
    else
        printf '%s' "assertion"
    fi
}

# pipe_to_hook <hook-path> <command-string> [--env] [--camel] [--name <tool>]
# Build the Bash-tool JSON envelope, feed it to <hook-path>, and capture
# stdout/stderr/exit into HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT.
pipe_to_hook() {
    if [ $# -lt 2 ]; then
        echo "pipe_to_hook: usage: pipe_to_hook <hook> <command> [--env] [--camel] [--name <tool>]" >&2
        return 2
    fi
    local hook_path="$1"
    local command_str="$2"
    shift 2

    local use_env=0
    local use_camel=0
    local tool_name="Bash"
    while [ $# -gt 0 ]; do
        case "$1" in
            --env)
                use_env=1
                shift
                ;;
            --camel)
                use_camel=1
                shift
                ;;
            --name)
                if [ $# -lt 2 ]; then
                    echo "pipe_to_hook: --name requires an argument" >&2
                    return 2
                fi
                tool_name="$2"
                shift 2
                ;;
            *)
                echo "pipe_to_hook: unknown arg: $1" >&2
                return 2
                ;;
        esac
    done

    local field="tool_input"
    if [ "$use_camel" -eq 1 ]; then
        field="toolInput"
    fi

    # Build {version:1, tool_name:<tn>, <field>:{command:<cmd>}} via jq so we
    # never have to think about shell-quoting the command string.
    local payload
    payload=$(jq -n \
        --arg cmd "$command_str" \
        --arg tn "$tool_name" \
        --arg fld "$field" \
        '{version: 1, tool_name: $tn} + {($fld): {command: $cmd}}')

    local stdout_file stderr_file
    stdout_file=$(mktemp)
    stderr_file=$(mktemp)

    if [ "$use_env" -eq 1 ]; then
        CLAUDE_HOOK_INPUT="$payload" "$hook_path" \
            </dev/null \
            >"$stdout_file" \
            2>"$stderr_file"
        HOOK_EXIT=$?
    else
        printf '%s' "$payload" | "$hook_path" \
            >"$stdout_file" \
            2>"$stderr_file"
        HOOK_EXIT=$?
    fi

    HOOK_STDOUT=$(cat "$stdout_file")
    HOOK_STDERR=$(cat "$stderr_file")
    rm -f "$stdout_file" "$stderr_file"
    return 0
}

# assert_exit <expected> — pass if HOOK_EXIT equals <expected>.
assert_exit() {
    local expected="$1"
    local label
    label=$(_harness_label)
    if [ "$HOOK_EXIT" = "-1" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s  (pipe_to_hook was not called before assert_exit)\n' "$label"
        return
    fi
    if [ "$HOOK_EXIT" = "$expected" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS  %s  (exit=%s)\n' "$label" "$HOOK_EXIT"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s  (expected exit=%s, got=%s)\n' \
            "$label" "$expected" "$HOOK_EXIT"
        if [ -n "$HOOK_STDERR" ]; then
            local truncated
            truncated=$(printf '%s' "$HOOK_STDERR" | head -c 400)
            printf '      stderr: %s\n' "$truncated"
        fi
    fi
}

# assert_stdout_jq <jq-expression> — pass if `jq -e <expr>` accepts HOOK_STDOUT.
assert_stdout_jq() {
    local expr="$1"
    local label
    label=$(_harness_label)
    if [ -z "$HOOK_STDOUT" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s  (stdout empty, expected jq: %s)\n' "$label" "$expr"
        return
    fi
    if printf '%s' "$HOOK_STDOUT" | jq -e "$expr" >/dev/null 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS  %s  (jq: %s)\n' "$label" "$expr"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL  %s  (jq mismatch: %s)\n' "$label" "$expr"
        local truncated
        truncated=$(printf '%s' "$HOOK_STDOUT" | head -c 400)
        printf '      stdout: %s\n' "$truncated"
    fi
}

# assert_stderr_contains <substring> — pass if HOOK_STDERR contains <substring>
# as a literal substring (no regex).
assert_stderr_contains() {
    local needle="$1"
    local label
    label=$(_harness_label)
    case "$HOOK_STDERR" in
        *"$needle"*)
            PASS_COUNT=$((PASS_COUNT + 1))
            printf 'PASS  %s  (stderr contains: %s)\n' "$label" "$needle"
            ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            printf 'FAIL  %s  (stderr missing: %s)\n' "$label" "$needle"
            local truncated
            truncated=$(printf '%s' "$HOOK_STDERR" | head -c 400)
            printf '      stderr: %s\n' "$truncated"
            ;;
    esac
}

# corpus_each <file> <fn> — for each non-comment, non-blank line of <file>,
# track the most recent `# category: <name>` annotation and invoke
# <fn> "<line>" "<category>".
corpus_each() {
    local file="$1"
    local fn="$2"
    if [ ! -f "$file" ]; then
        echo "corpus_each: no such file: $file" >&2
        return 2
    fi
    if ! declare -F "$fn" >/dev/null 2>&1; then
        echo "corpus_each: callback not a function: $fn" >&2
        return 2
    fi
    local category=""
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim trailing CR for files with CRLF endings; leave leading
        # whitespace alone so corpus authors can indent for grouping.
        line=${line%$'\r'}
        case "$line" in
            '')
                continue
                ;;
            '#'*)
                # Category annotation? Accept "# category: <name>" with any
                # surrounding whitespace.
                local trimmed
                trimmed=${line#\#}
                # strip leading spaces
                while [ "${trimmed# }" != "$trimmed" ]; do
                    trimmed=${trimmed# }
                done
                case "$trimmed" in
                    category:*)
                        category=${trimmed#category:}
                        # strip leading spaces from category value
                        while [ "${category# }" != "$category" ]; do
                            category=${category# }
                        done
                        ;;
                esac
                continue
                ;;
        esac
        "$fn" "$line" "$category"
    done <"$file"
}

# report_results — print summary line; return 1 if any assertions failed.
report_results() {
    local total=$((PASS_COUNT + FAIL_COUNT))
    printf 'Total: %d | Pass: %d | Fail: %d\n' \
        "$total" "$PASS_COUNT" "$FAIL_COUNT"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        return 1
    fi
    return 0
}
