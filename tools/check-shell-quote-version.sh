#!/usr/bin/env bash
#
# check-shell-quote-version.sh — detect drift between the inlined shell-quote
# parse function (parser/shell-quote-parse.mjs) and the upstream parse.js at
# the recorded tag. Structural diff, warning-only, always exits 0.
#
# This is Klaus K7's mitigation for R-3: previous regex/version-string drift
# checks produced false positives whenever attribution comments or whitespace
# changed. We now compare normalised code bodies, ignoring cosmetic noise.
#
# Normalisation rules (per Klaus K7) — applied to BOTH local and upstream
# before diffing:
#   a. Strip the leading attribution / comment block. Everything from the top
#      of the file down to (but NOT including) the first line that begins a
#      code construct (var / const / let / function / import / export) is
#      discarded. Code is never stripped.
#   b. Strip a leading `'use strict';` line.
#   c. Strip the export wrapper:
#        - `module.exports = function parse` → `function parse`
#        - `export default function parse`   → `function parse`
#      The CommonJS form wraps `parse` in an assignment expression and so
#      ends the file with `};` rather than `}`. Strip a trailing `;` from
#      the final non-blank line to normalise that asymmetry away.
#   d. Collapse runs of whitespace (tabs + spaces) to a single space, and
#      strip leading whitespace on each line (so indentation differences are
#      ignored).
#   e. Normalise line endings: CRLF → LF; strip trailing whitespace.
#
# Exit codes:
#   0  — always. This is a warning tool, not a CI gate.
#
# Network failure, missing files, parse failure → print warning, exit 0.
#
# NOTE (forward-reference): Task 6 (Batch 3) renames parser/VENDORED.md →
# parser/INLINED.md. For now we prefer INLINED.md if present and fall back to
# VENDORED.md. After Batch 3 lands, this fallback can be deleted.
#
# Fallback fetch URL (NOT implemented, documented only): if
# raw.githubusercontent.com is blocked, the registry tarball is available at
#   https://registry.npmjs.org/shell-quote/-/shell-quote-${VERSION_NO_V}.tgz
# Extract `package/parse.js` from the tarball and feed it through the same
# normalisation pipeline.

# Deliberately NOT using `set -e` — every fallible step is guarded so that
# the script always exits 0. We still want pipefail + nounset for safety.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
INLINED_MD="$PROJECT_DIR/parser/INLINED.md"
VENDORED_MD="$PROJECT_DIR/parser/VENDORED.md"
LOCAL_PARSE="$PROJECT_DIR/parser/shell-quote-parse.mjs"

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

# Pick the metadata file: prefer INLINED.md (post-Batch-3), fall back to
# VENDORED.md (current). TODO: after Batch 3 lands, simplify to INLINED.md only.
META_FILE=""
if [ -f "$INLINED_MD" ]; then
    META_FILE="$INLINED_MD"
elif [ -f "$VENDORED_MD" ]; then
    META_FILE="$VENDORED_MD"
else
    warn "neither $INLINED_MD nor $VENDORED_MD found; cannot determine recorded tag"
    exit 0
fi

# Extract the recorded version. We look for any line matching the label
# `Tag` or `Version` (case-insensitive) followed somewhere later on the same
# line by a SemVer token like `1.8.3` or `v1.8.3`. This is tolerant of
# markdown decoration (`**`, backticks, colons, etc.) between label and value.
TAG_RAW=""
TAG_RAW=$(grep -E -i -m1 '(^|[^[:alnum:]])(tag|version)([^[:alnum:]]|$)' "$META_FILE" 2>/dev/null || true)
VERSION_NO_V=""
if [ -n "$TAG_RAW" ]; then
    # Pull the first SemVer-looking token out of the matched line.
    VERSION_NO_V=$(printf '%s\n' "$TAG_RAW" | grep -E -o '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
fi

if [ -z "$VERSION_NO_V" ]; then
    warn "could not parse recorded shell-quote version from $META_FILE"
    exit 0
fi

TAG="v$VERSION_NO_V"

if [ ! -f "$LOCAL_PARSE" ]; then
    warn "local parse file not found: $LOCAL_PARSE"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    warn "curl not available; cannot fetch upstream"
    exit 0
fi

UPSTREAM_URL="https://raw.githubusercontent.com/ljharb/shell-quote/${TAG}/parse.js"
UPSTREAM_RAW=""
UPSTREAM_RAW=$(curl -fsSL --max-time 10 --connect-timeout 5 \
    -A "claudikins-kernel-drift-check" "$UPSTREAM_URL" 2>/dev/null || true)

if [ -z "$UPSTREAM_RAW" ]; then
    warn "failed to fetch upstream parse.js for $TAG from $UPSTREAM_URL"
    exit 0
fi

LOCAL_RAW=""
LOCAL_RAW=$(cat "$LOCAL_PARSE" 2>/dev/null || true)
if [ -z "$LOCAL_RAW" ]; then
    warn "could not read $LOCAL_PARSE"
    exit 0
fi

# normalise: implements rules (a)–(e) above.
# Reads from stdin, writes to stdout.
normalise() {
    # Use awk for rule (a)+(b)+(c), then tr/sed for (d)+(e).
    awk '
        BEGIN { started = 0 }
        {
            # Rule (e): strip CR (CRLF → LF handled by awk reading line-by-line,
            # but a trailing \r on the line is still there).
            sub(/\r$/, "", $0)

            if (!started) {
                # Rule (a): skip until we hit a code-starting line.
                # We consider a code line one whose first non-whitespace token
                # is one of: var, const, let, function, import, export.
                # Match leading whitespace + keyword + word boundary.
                if ($0 ~ /^[[:space:]]*(var|const|let|function|import|export)([[:space:]]|$)/) {
                    started = 1
                } else {
                    next
                }
            }

            # Rule (b): strip a leading `use strict` line at the top of code.
            # Only meaningful on the very first emitted line.
            if (NR_emitted == 0 && $0 ~ /^[[:space:]]*['\''"]use strict['\''"];?[[:space:]]*$/) {
                next
            }
            NR_emitted++

            # Rule (c): normalise export wrappers to a bare `function parse`.
            sub(/module\.exports[[:space:]]*=[[:space:]]*function[[:space:]]+parse/, "function parse", $0)
            sub(/export[[:space:]]+default[[:space:]]+function[[:space:]]+parse/, "function parse", $0)

            print
        }
    ' \
    | sed -E 's/[[:space:]]+$//' \
    | sed -E 's/^[[:space:]]+//' \
    | tr -s '\t ' '  ' \
    | sed -E 's/  +/ /g' \
    | awk '
        # Final pass: strip a trailing `;` from the very last non-blank line.
        # The CommonJS export form ends the file with `};` (statement
        # terminator on the wrapping assignment); the ESM declaration form
        # ends with `}`. Both should normalise to the same thing.
        { lines[NR] = $0; last_nonblank = ($0 ~ /[^[:space:]]/) ? NR : last_nonblank }
        END {
            if (last_nonblank > 0) {
                sub(/;[[:space:]]*$/, "", lines[last_nonblank])
            }
            for (i = 1; i <= NR; i++) print lines[i]
        }
    '
}

TMP_LOCAL=""
TMP_UPSTREAM=""
TMP_LOCAL=$(mktemp -t shellquote-local.XXXXXX 2>/dev/null || true)
TMP_UPSTREAM=$(mktemp -t shellquote-upstream.XXXXXX 2>/dev/null || true)

if [ -z "$TMP_LOCAL" ] || [ -z "$TMP_UPSTREAM" ]; then
    warn "could not create temp files; skipping drift check"
    [ -n "$TMP_LOCAL" ] && rm -f "$TMP_LOCAL"
    [ -n "$TMP_UPSTREAM" ] && rm -f "$TMP_UPSTREAM"
    exit 0
fi

# shellcheck disable=SC2064  # we want $TMP_* expanded now, not at trap time
trap "rm -f '$TMP_LOCAL' '$TMP_UPSTREAM'" EXIT

printf '%s' "$LOCAL_RAW"    | normalise > "$TMP_LOCAL"    || true
printf '%s' "$UPSTREAM_RAW" | normalise > "$TMP_UPSTREAM" || true

if diff -q "$TMP_UPSTREAM" "$TMP_LOCAL" >/dev/null 2>&1; then
    printf 'OK: vendored=%s upstream=%s\n' "$TAG" "$TAG"
    exit 0
fi

printf 'DRIFT detected: upstream parse.js diverges from inlined shell-quote-parse.mjs\n' >&2
diff -u "$TMP_UPSTREAM" "$TMP_LOCAL" >&2 || true
exit 0
