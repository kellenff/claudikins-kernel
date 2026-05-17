# Test fixtures — bypass and allowlist corpora

These two files **are the spec** for the parser/sanitiser. They define,
by enumeration, what the gated-phase git guard must block and what it
must allow. The parser code is downstream of these lists: when a new
bypass is discovered in the wild, it lands here **first**, then the
parser is patched until the corpus test goes green again. Do not
reverse this order.

## Files

| File                   | Purpose                                                             |
| ---------------------- | ------------------------------------------------------------------- |
| `bypass-corpus.txt`    | Command strings that MUST be rejected. ≥ 50 entries, 19 categories. |
| `allowlist-corpus.txt` | Command strings that MUST pass through unchanged. ≥ 20 entries.     |
| `README.md`            | This file.                                                          |

## Line format

- One entry per line. Each entry is a single line of shell-ish text.
- Lines beginning with `#` are comments. A comment of the form
  `# category: <name>` annotates the category of the **next** non-blank
  non-comment entry (and of every subsequent entry until a new
  `# category:` marker appears).
- Blank lines are allowed and ignored; they exist only for visual
  grouping.
- For genuinely multi-line bypass attempts (here-docs, embedded
  newlines, line continuations) the corpus stores a **single-line
  surrogate** with the literal two-character sequence `\n` (backslash +
  `n`) where the real newline would be. The test harness is responsible
  for translating that surrogate back into a real newline before
  feeding the string to the parser. This keeps the corpus
  `wc -l`-stable and grep-friendly.

## How the tests consume these files

`tests/cli-corpus-smoke.sh` and `tests/hooks/test-*.sh` read each
fixture line-by-line, skipping `^#` and `^$`. For every bypass line the
test asserts the parser returns a _reject_ verdict; for every allowlist
line it asserts the parser returns _accept_ with the command string
unchanged. A single failing line fails the whole suite — there is no
partial credit.

## The contamination rule (anti-rule)

The two corpora **must not overlap**. Concretely:

1. No identical line may appear in both files.
2. No allowlist line may contain any of the wrapper / metacharacter
   substrings used by the bypass corpus: `$(`, `` ` ``, `<<`, `<<<`,
   `<(`, `$'`, `&&`, `||`, `;`. (A literal `;` inside a quoted
   argument is technically harmless, but the test scans for substrings
   without quote-awareness, so keep the allowlist surgically clean.)
3. No bypass line may be a benign read-only git invocation; if it
   looks safe it belongs in the allowlist, not here.

CI enforces (1) and (2) directly. (3) is enforced by review.

## Adding entries

- **New bypass discovered:** add it under the matching `# category:`
  block. If it does not fit any existing category, add a new
  `# category: <name>` marker and at least one entry. Then run the
  suite — it will (correctly) fail until the parser is updated.
- **New legitimate command needed:** add it to the allowlist under the
  matching category. Verify it does not contain any of the banned
  substrings above.
- **Never delete entries** without an explicit deprecation note in
  the commit message. The corpus is append-mostly.
