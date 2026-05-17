# Inlined dependency: shell-quote

**Upstream:** https://github.com/ljharb/shell-quote
**Tag:** v1.8.3
**Upstream commit SHA:** `487a9b41a7b6154d2a9c10bdffe65cf74d2c3ded`
**License:** MIT
**Transitive runtime dependencies:** none

The parser CLI (`parser/cli.mjs`) imports a single `parse()` function from
`parser/shell-quote-parse.mjs`. That file is a hand-inlined ESM copy of
`parse.js` from the upstream `shell-quote` package at the tag above, with a
local "Invariants — DO NOT alter" comment block and an MIT attribution
header. No other upstream files are required at runtime.

## Inlined files

| Path                                  | SHA-256                                                            |
| ------------------------------------- | ------------------------------------------------------------------ |
| `parser/shell-quote-parse.mjs`        | `cb2de1d4c2e874f62ac326ad3d19375b70d0a01bc62ed2c0492bd397ea9499c8` |
| `parser/LICENSES/shell-quote-MIT.txt` | `8bb16db1b047019e4395965f2cf3611b06c34bf86dc2d0210b3c3f91b53c21fe` |

To verify integrity:

```bash
shasum -a 256 parser/shell-quote-parse.mjs parser/LICENSES/shell-quote-MIT.txt
```

## Files no longer in repo

These were vendored under `parser/node_modules/shell-quote/` prior to
inlining and were removed in Task 5:

- `parse.js` — now inlined at `parser/shell-quote-parse.mjs`
- `LICENSE` — preserved verbatim at `parser/LICENSES/shell-quote-MIT.txt`
- `quote.js`, `index.js`, `README.md`, `security.md`, `.eslintrc`, `.nycrc`,
  `FUNDING.yml`, `print.py`, `test/`, `package.json`, etc. — unused at
  runtime; removed

The previous `parser/package.json` and `parser/package-lock.json` are also
gone: the plugin no longer has any installable Node project root.

## Update procedure

When upstream releases a new version:

1.  Inspect the upstream diff:
    `https://github.com/ljharb/shell-quote/compare/v1.8.3...v<new>`
2.  Apply the upstream changes from `parse.js`'s function body into
    `parser/shell-quote-parse.mjs`. Preserve:
    - The "Invariants — DO NOT alter" comment block at the top.
    - The MIT attribution header.
    - The `var i` hoisting in the outer `.map()` callback (upstream uses
      `var` deliberately because the index is referenced from the inner
      callback's closure).
    - The `TOKEN = Math.random()` sentinel used to mark control operators.
3.  Run `tests/run.sh`. All 47 parser unit tests + 87 corpus assertions +
    323 hook integration tests must pass.
4.  Refresh both SHA-256 values:

    ```bash
    shasum -a 256 parser/shell-quote-parse.mjs parser/LICENSES/shell-quote-MIT.txt
    ```

5.  Update the `Tag`, `Upstream commit SHA`, and SHA-256 table above. Fetch
    the new commit SHA via:

        curl -fsSL https://api.github.com/repos/ljharb/shell-quote/git/refs/tags/v<new> \
          | jq -r '.object.sha'

    If the ref points to an annotated-tag object (`type: tag`), dereference
    it once more via `https://api.github.com/repos/ljharb/shell-quote/git/tags/<sha>`
    to get the underlying commit SHA.

6.  If the upstream `LICENSE` changed, re-copy it byte-for-byte to
    `parser/LICENSES/shell-quote-MIT.txt`.
7.  Run `tools/check-shell-quote-version.sh` — it should report
    `OK: vendored=v<new> upstream=v<new>` and exit 0.

## Drift-check sources

`tools/check-shell-quote-version.sh` reads the tag from this file (it
greps for a `Tag` or `Version` line and pulls out the first SemVer
token). The check fetches upstream `parse.js` from:

`https://raw.githubusercontent.com/ljharb/shell-quote/v1.8.3/parse.js`

Fallback if the GitHub raw URL is blocked, the registry tarball is
available at:

`https://registry.npmjs.org/shell-quote/-/shell-quote-1.8.3.tgz`

Extract `package/parse.js` from the tarball and feed it through the same
normalisation pipeline documented in the drift-check script.

## Rationale

The plugin has no Node project root and no install step — users drop it
into `~/.claude/plugins/` and expect commands to run immediately.
Inlining `shell-quote`'s single required function (a small, zero-dep,
MIT-licensed parser) directly into `parser/shell-quote-parse.mjs` keeps
the dependency deterministic, auditable in-tree, and free of network
access at runtime. The drift checker keeps us honest about staying in
sync with upstream without making upstream a runtime concern.
