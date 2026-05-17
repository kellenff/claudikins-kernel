#!/usr/bin/env bash
# tests/cli-corpus-smoke.sh
#
# Pipes every non-comment non-blank entry of bypass-corpus-parser.txt and
# allowlist-corpus.txt through parser/cli.mjs and asserts the verdict
# matches expectation (reject for parser-bypass, ok for allowlist).
#
# Only the parser-scope bypass corpus is iterated here. Hook-scope
# bypasses (bypass-corpus-hook.txt) are exercised by tests/hooks/*
# integration tests in Batch 4.
#
# Runs BEFORE per-hook integration tests so any later hook-wrapper
# failure unambiguously indicts the wrapper, not the parser.
#
# Exit 0 iff every entry produced the expected verdict; exit 1 otherwise.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CLI="$PROJECT_DIR/parser/cli.mjs"
BYPASS="$PROJECT_DIR/tests/fixtures/bypass-corpus-parser.txt"
ALLOW="$PROJECT_DIR/tests/fixtures/allowlist-corpus.txt"

for f in "$CLI" "$BYPASS" "$ALLOW"; do
    if [ ! -f "$f" ]; then
        printf 'cli-corpus-smoke: missing required file: %s\n' "$f" >&2
        exit 1
    fi
done

PASS=0
FAIL=0
BYPASS_TOTAL=0
ALLOW_TOTAL=0
FAILING_ENTRIES=()

# Translate \n -> newline and \t -> tab surrogates as defined in
# tests/fixtures/README.md. printf '%b' interprets these escapes.
translate_surrogates() {
    # shellcheck disable=SC2059
    printf '%b' "$1"
}

run_one() {
    local raw_line="$1" expected="$2" file="$3" lineno="$4" category="$5"
    local cmd payload stdout verdict reason

    cmd=$(translate_surrogates "$raw_line")
    payload=$(jq -cn --arg cmd "$cmd" '{version:1, tool_input:{command:$cmd}}')

    # The CLI exits 0 on both ok and reject verdicts; only internal
    # errors give nonzero. Don't `set -e` us out of the pipeline.
    stdout=$(printf '%s' "$payload" | node "$CLI" 2>/dev/null || true)

    verdict=$(printf '%s' "$stdout" | jq -r '.verdict // "ERROR"' 2>/dev/null || printf 'ERROR')
    reason=$(printf '%s' "$stdout" | jq -r '.reject_reason // ""' 2>/dev/null || printf '')

    if [ "$verdict" = "$expected" ]; then
        PASS=$((PASS + 1))
        return 0
    fi

    FAIL=$((FAIL + 1))
    # Red FAIL line (ANSI only if stdout is a TTY).
    local red='' reset=''
    if [ -t 1 ]; then
        red=$'\033[31m'
        reset=$'\033[0m'
    fi
    printf '%sFAIL%s %s:%d [%s] expected=%s got=%s reason=%s\n  line: %s\n' \
        "$red" "$reset" "$(basename "$file")" "$lineno" "$category" \
        "$expected" "$verdict" "$reason" "$raw_line"

    FAILING_ENTRIES+=("$(jq -cn \
        --arg file "$(basename "$file")" \
        --argjson line "$lineno" \
        --arg category "$category" \
        --arg expected "$expected" \
        --arg actual "$verdict" \
        --arg reason "$reason" \
        --arg command "$raw_line" \
        '{file:$file, line:$line, category:$category, expected:$expected, actual:$actual, reject_reason:$reason, command:$command}')")
}

iterate_corpus() {
    local file="$1" expected="$2"
    local lineno=0
    local category=""
    local line

    # shellcheck disable=SC2094  # run_one doesn't write to $file; it only echoes the line.
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))

        # Strip trailing CR for CRLF-tolerant reading.
        line="${line%$'\r'}"

        # Skip blank lines.
        [ -z "$line" ] && continue

        # Category annotation: `# category: <name>`.
        if [[ "$line" =~ ^#[[:space:]]*category: ]]; then
            category="${line#*category:}"
            # Trim leading whitespace.
            category="${category#"${category%%[![:space:]]*}"}"
            continue
        fi

        # Skip any other comment lines.
        [[ "$line" =~ ^# ]] && continue

        if [ "$expected" = "reject" ]; then
            BYPASS_TOTAL=$((BYPASS_TOTAL + 1))
        else
            ALLOW_TOTAL=$((ALLOW_TOTAL + 1))
        fi

        run_one "$line" "$expected" "$file" "$lineno" "$category"
    done < "$file"
}

iterate_corpus "$BYPASS" "reject"
iterate_corpus "$ALLOW" "ok"

printf '\nCorpus smoke: Parser-bypass=%d | Allowlist=%d | Pass=%d | Fail=%d\n' \
    "$BYPASS_TOTAL" "$ALLOW_TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
