# Vendored dependencies

This directory vendors `shell-quote` so the parser CLI can `require('shell-quote')` without a runtime `npm install`.

## shell-quote

- **Version:** `1.8.3`
- **License:** MIT
- **Upstream:** https://github.com/ljharb/shell-quote
- **Registry tarball:** https://registry.npmjs.org/shell-quote/-/shell-quote-1.8.3.tgz
- **SHA-256 of `node_modules/shell-quote/index.js`:** `6dba443a976bcfdb5972a479c5c43c298e96bdef471c1629844ce9d6b31f5b68`
- **Transitive runtime dependencies:** none

To verify integrity:

    echo "6dba443a976bcfdb5972a479c5c43c298e96bdef471c1629844ce9d6b31f5b68  parser/node_modules/shell-quote/index.js" | shasum -a 256 -c

### Rationale

The plugin has no Node project root and no install step — users drop it into `~/.claude/plugins/` and expect commands to run immediately. Vendoring `shell-quote` (a small, zero-dependency, MIT-licensed parser) directly into `parser/node_modules/` keeps the dependency deterministic, auditable in-tree, and free of network access at runtime. The exact-pinned `package.json` plus committed `package-lock.json` make the vendored state reproducible from any clone.

### Update procedure

1. Edit `parser/package.json` and change the `shell-quote` version to the desired exact pin (no `^`, no `~`).
2. From `parser/`, run `npm install --no-audit --no-fund`.
3. Recompute the SHA-256: `shasum -a 256 parser/node_modules/shell-quote/index.js`.
4. Update the version and SHA-256 in this file.

> **Do not run `npm install` inside `parser/`** except when intentionally re-vendoring per the procedure above. A casual `npm install` (e.g. triggered by an IDE or unrelated tooling) will regenerate `node_modules/` and may modify `package-lock.json`, silently drifting from the recorded SHA-256.
