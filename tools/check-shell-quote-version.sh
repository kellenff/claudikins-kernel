#!/usr/bin/env bash
#
# check-shell-quote-version.sh — detect drift between the vendored shell-quote
# version (parser/package.json) and the latest published version on the npm
# registry. Lightweight maintenance signal; not a CI failure gate.
#
# Exit codes:
#   0  vendored == upstream
#   1  drift detected
#   2  any fetch / parse / IO error
#
# Flags:
#   --json   emit structured JSON instead of human-readable text
#
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PACKAGE_JSON="$PROJECT_DIR/parser/package.json"
readonly REGISTRY_URL="https://registry.npmjs.org/shell-quote/latest"
JSON_OUTPUT=0

for arg in "$@"; do
    case "$arg" in
        --json) JSON_OUTPUT=1 ;;
        *)
            echo "ERROR: unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

for bin in jq curl; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin required" >&2; exit 2; }
done

if [ ! -f "$PACKAGE_JSON" ]; then
    echo "ERROR: $PACKAGE_JSON not found" >&2
    exit 2
fi

VENDORED=$(jq -r '.dependencies["shell-quote"] // empty' "$PACKAGE_JSON" 2>/dev/null || true)
if [ -z "$VENDORED" ]; then
    echo "ERROR: vendored shell-quote version not found in $PACKAGE_JSON" >&2
    exit 2
fi
VENDORED="${VENDORED#[\^~]}"  # strip leading ^ or ~ if a range was used

UPSTREAM_JSON=$(curl -sf --max-time 10 --connect-timeout 5 -A "claudikins-kernel-drift-check" "$REGISTRY_URL" || true)
if [ -z "$UPSTREAM_JSON" ]; then
    echo "ERROR: failed to fetch upstream version from npm registry" >&2
    exit 2
fi

UPSTREAM=$(printf '%s' "$UPSTREAM_JSON" | jq -r '.version // empty' 2>/dev/null || true)
if [ -z "$UPSTREAM" ]; then
    echo "ERROR: malformed upstream response (no .version field)" >&2
    exit 2
fi

if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ "$VENDORED" = "$UPSTREAM" ]; then
        jq -n --arg v "$VENDORED" --arg u "$UPSTREAM" \
            '{vendored: $v, upstream: $u, drift: false}'
        exit 0
    else
        jq -n --arg v "$VENDORED" --arg u "$UPSTREAM" \
            '{vendored: $v, upstream: $u, drift: true}'
        exit 1
    fi
fi

if [ "$VENDORED" = "$UPSTREAM" ]; then
    echo "OK: vendored=$VENDORED upstream=$UPSTREAM"
    exit 0
else
    echo "WARN: vendored=$VENDORED upstream=$UPSTREAM (drift detected)" >&2
    exit 1
fi
