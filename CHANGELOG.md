# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Inlined `shell-quote` `parse` function; removed vendored package tree.** The `parser/node_modules/shell-quote/` vendored directory has been deleted. The single function the parser CLI actually uses (`parse`) is now inlined as an ES module at `parser/shell-quote-parse.mjs`. `parser/cli.mjs` imports it directly instead of resolving through `node_modules`.
- **Licence preserved.** The upstream MIT licence text is retained at `parser/LICENSES/shell-quote-MIT.txt` per the MIT licence's redistribution clause. Provenance attribution is also retained in the inlined source header.
- **`parser/VENDORED.md` renamed to `parser/INLINED.md`** and rewritten to document the inlined model: SHA-256 of the inlined source, upstream commit reference, the rationale for inlining (eliminating `node_modules/` from the gating-hook hot path), and the update procedure if upstream `parse` changes.
- **`tools/check-shell-quote-version.sh` rewritten with structural-diff normalisation (Klaus K7).** The drift check now strips comments, whitespace, and other cosmetic differences before comparing against the npm registry, suppressing false-positives that would otherwise fire on every benign upstream reformat.
- **No runtime behaviour change.** All 47 parser unit tests, 87 CLI corpus smoke assertions, and 323 hook integration tests pass without modification. The parser CLI emits byte-identical verdicts for every input in `tests/fixtures/bypass-corpus-{parser,hook}.txt`.
- **Hygiene goal of plan session `plan-2026-05-17-0650` is satisfied.** The associated perf goal (reducing Node startup overhead in the gating-hook chain) is deferred — see "Deferred work" below.

#### Pre-change latency baseline (captured before inlining)

Aggregate per-Bash-tool latency (sum of `git-branch-guard.sh` + `sanitize-bash.sh` + `merge-gate.sh`), 30-invocation sample on macOS Apple Silicon / Node 24, captured 2026-05-17 pre-inlining:

| Metric | Value    |
| ------ | -------- |
| min    | 134.0 ms |
| p50    | 142.9 ms |
| p95    | 147.2 ms |
| p99    | 148.6 ms |
| max    | 148.6 ms |
| mean   | 142.6 ms |

#### Post-change latency baseline (after inlining)

Same methodology (30-invocation sample, macOS Apple Silicon, Node 24, nearest-rank percentiles, `CLAUDE_HOOK_INPUT`-via-env to skip the parser CLI's stdin-timeout path), captured 2026-05-17 post-inlining:

| Metric | Value    |
| ------ | -------- |
| min    | 83.7 ms  |
| p50    | 86.5 ms  |
| p95    | 93.9 ms  |
| p99    | 110.2 ms |
| max    | 110.2 ms |
| mean   | 87.7 ms  |

SC-11 holds: new p95 93.9 ms ≤ baseline_max + 4 = 152.6 ms (58.7 ms headroom). Delta vs pre-change: **53.3 ms faster p95** (~36% reduction), driven by eliminating the `node_modules/` resolution and ESM-loader walk for `shell-quote` on every Bash-tool invocation. Mean drops from 142.6 → 87.7 ms (54.9 ms faster).

### Deferred work

- **Parser CLI perf port (Go via `mvdan.cc/sh/v3/syntax`).** Estimated ~3× speedup of the aggregate hook chain (~40-50 ms vs current ~143 ms p50). Out of scope for this release because the hygiene goal (eliminating `parser/node_modules/`) and the perf goal share no scaffolding. Re-visit by **2026-11-17** (see `<!-- TODO(perf): revisit Go port — review by 2026-11-17 -->` adjacent to CLAUDE.md's latency table). Plan reference: session `plan-2026-05-17-0650`, R-10.

## [1.3.0] - 2026-05-17

### Added

- **Parser-backed gating hooks** — four hooks (`git-branch-guard.sh`, `block-git-commands.sh`, `merge-gate.sh`, `sanitize-bash.sh`) now route Bash command text through a Node.js + `shell-quote` parser CLI (`parser/cli.mjs`) instead of regex-on-raw-string matching. Closes the bypass class Klaus flagged where `$(echo "git merge X")`, `bash -c 'rm -rf /'`, and similar wrapper forms slipped past pattern-only gates.
- `parser/GRAMMAR.md` — behavioural spec for the parser CLI (16 sections + §10.5 SHELL_KEYWORDS): JSON envelope schema, 19 meta-commands, 15 shell keywords, 12 reject_reason patterns, and recursive inner-shell parsing rules.
- `parser/cli.mjs` — argv walker that emits `{version:1, verdict:"ok"|"reject", commands:[{basename, argv}], reject_reason?}`. Reads from stdin (preferred) or `CLAUDE_HOOK_INPUT` env var; exits 0 on any verdict, 1 only on internal CLI failure.
- `parser/vendor/shell-quote@1.8.3` — vendored MIT-licensed tokeniser, no transitive deps. SHA-256 pinned in `parser/VENDORED.md`.
- `tests/run.sh` — canonical test runner. Hard steps: shellcheck, parser unit tests (47), CLI corpus smoke (parser-bypass + allowlist), hook integration tests. Soft step: registry drift check.
- `tests/fixtures/bypass-corpus-parser.txt` (61 entries) and `bypass-corpus-hook.txt` (32 entries) — split corpus distinguishing parser-layer rejections from hook-layer policy blocks.
- `tools/check-shell-quote-version.sh` — optional drift check against npm registry with `--max-time` and binary preflight.
- Latency baseline documented in CLAUDE.md: p95 < 150ms aggregate per Bash tool call (min 134.0 / p50 142.9 / p95 147.2 / p99 148.6 / mean 142.6 ms).

### Changed

- `hooks/git-branch-guard.sh` rewritten as parser-backed shim. Allowlist preserved verbatim (add/status/diff/log/show/ls-files/check-ignore/rev-parse/symbolic-ref/commit + `config --get/--list/--get-all/--get-regexp`). Walks all commands in a compound; rejects on any disallowed subcommand. Fail-closed on parser missing, crash, or malformed output.
- `hooks/block-git-commands.sh` rewritten as parser-backed shim. Blocks any command-position basename `git` across compound forms, wrappers, and substitutions (babyclaude scope).
- `hooks/merge-gate.sh` rewritten. Detects `git merge` via parser walker (including `cd repo && git merge X` and `bash -c 'git merge ...'`); verdict-file gate logic unchanged.
- `hooks/sanitize-bash.sh` rewritten. JSON emission via `jq -n` (no string interpolation). `rm -rf` danger-path detection extended (`/`, `~`, `$HOME` across flag permutations `-r`, `-rf`, `-fr`, `-Rf`, `-fR`, `-rfR`, `-rRf`). `git commit` rewrite branch now emits `"decision":"approve"` (corrects the long-standing `"allow"` bug noted in CLAUDE.md).
- Stdin > `CLAUDE_HOOK_INPUT` precedence harmonised across all four hooks.

### Fixed

- BSD-grep portability: parser-backed `merge-gate.sh` no longer relies on `rg -P` / `grep -P` PCRE shim — eliminates remaining macOS portability concerns.
- Regex blind spots: chained merge detection (`cd repo && git merge X`), command substitution wrappers (`$(...)`, `` `...` ``), and `eval`/`bash -c`/`xargs` indirection are now caught structurally.

### Security

- Argv-level wrapper substring scan + SHELL_KEYWORDS rejection class closes the parser-bypass corpus that motivated this change (Klaus audit, 2026-05-16).

## [1.2.1] - 2026-05-16

### Fixed

- `merge-gate.sh` BSD grep incompatibility: replaced `grep -P` (PCRE, GNU-only) with portable extraction. Hook now prefers `ripgrep` (`rg -qP` / `rg -oP`) when available and falls back to `grep -qE` + `sed -nE` with POSIX character classes (`[[:space:]]`). Resolves "grep: invalid option -- P" on macOS.

### Added

- `## Tool Use Protocol` section in all 16 plugin components (4 commands, 4 skills, 8 agents): instructs each component to prefer the tool-executor MCP (`search_tools` → `get_tool_schema` → `execute_code`) for capabilities beyond basic file/shell ops, and gracefully fall back to Read/Grep/Glob/Bash/Edit/Write otherwise.
- `CLAUDE.md` at repo root: project guidance for future Claude Code sessions covering the four-stage pipeline (outline → execute → verify → ship), agent roster, skill pairings, hook gotchas, editing conventions, and a provenance warning about upstream README/manifest claims.
- `hooks/git-branch-guard.sh`: `git diff --stat` admitted to the safe-command allowlist for inspect-only diff summaries.

## [1.2.0] - 2026-01-21

### Added

- **Review Enforcement** in git-workflow skill and execute.md - reviewer agents (spec-reviewer, code-reviewer) MUST be spawned; inline reviews are now violations
- Pre-merge checklist requiring `.claude/reviews/spec/` and `.claude/reviews/code/` files to exist
- Test task detection and implementation source injection in execute.md - prevents test agents from hallucinating interfaces
- Defensive "For Test Tasks" section in babyclaude.md - blocks if implementation sources not provided
- Worktree path injection in babyclaude spawn with `cwd: worktreePath` for proper isolation

### Changed

- `git-branch-guard.sh` switched from blocklist to **allowlist** approach - only permits safe git commands (add, status, diff, log, show, ls-files, check-ignore, rev-parse, symbolic-ref, config --get/--list, commit)
- Rationalizations table updated with "I'll do the review myself" violation
- Red flags updated with inline review warnings

### Fixed

- Branch collision bug - parallel babyclaude agents now operate in isolated worktrees instead of shared working directory
- `preserve-state.sh` PreCompact hook now always outputs valid JSON (even for no-op cases)
- Phase-aware resume commands in preserve-state.sh (outline/execute/verify/ship)

## [1.1.3] - 2026-01-20

### Changed

- `batch-checkpoint-gate.sh`: improved checkpoint message formatting with proper newline handling via jq

---

## [1.1.2] - 2026-01-19

### Fixed

- babyclaude Stop prompt hook: use `{"ok": true/false}` response format instead of `{"decision": "allow/block"}` (Claude Code expects the former)

## [1.1.1] - 2026-01-19

### Fixed

- `sanitize-bash.sh`: use `"decision": "approve"` instead of invalid `"decision": "allow"`
- `verify-gate.sh`: output to stderr instead of invalid `hookSpecificOutput` JSON (Stop hooks don't support it)

## [1.1.0] - 2026-01-20

### Added

- `homepage`, `repository`, `license`, and `keywords` fields to plugin.json
- `permissionMode` to all 8 agents for proper permission handling
- `once: true` to session-startup hook (prevents duplicate execution)
- `pre-task-gate.sh` hook implementing constraint C-4 (review verdict gate)
- PreToolUse/Task matcher in hooks.json for pre-task validation
- Permission deny rules in settings.local.json for dangerous git operations
- "Next Stage" sections to all 4 commands for workflow continuity
- Frontmatter `hooks.Stop` to 5 agents (babyclaude, catastrophiser, cynic, git-perfectionist, taxonomy-extremist)
- LLM-based Stop hook (`type: "prompt"`) for babyclaude completion evaluation
- `sanitize-bash.sh` PreToolUse hook with `updatedInput` pattern for command sanitization
- `output-schema` to all 4 commands for structured JSON output
- `skill-rules.json` for skill auto-activation with intent/path pattern matching
- `skill-activation-hook.sh` UserPromptSubmit hook for auto-suggesting relevant skills
- Execution tracing with `trace-start.sh` and `trace-end.sh` (SubagentStart/SubagentStop)
- `.claude/traces/` directory for span-based execution timing
- `allowed-tools` to all 4 skills with appropriate tool restrictions

### Changed

- Commands restructured: `flags`, `merge_strategy`, `color` moved from frontmatter to body documentation
- Plugin version bumped from 1.0.0 to 1.1.0
- Author name updated to full name in plugin.json
- Agent-specific SubagentStop hooks moved from hooks.json to agent frontmatter

### Removed

- Invalid `context: fork` field from all agents (skill-only field)
- `color` field from command frontmatter (not a valid field)
- SubagentStop section from hooks.json (replaced by frontmatter hooks + global tracing)

### Fixed

- Agent frontmatter now uses only valid fields per Claude Code spec

## [1.0.0] - 2026-01-18

### Added

- Initial release
- 4 commands: outline, execute, verify, ship
- 8 agents: babyclaude, catastrophiser, cynic, spec-reviewer, code-reviewer, taxonomy-extremist, conflict-resolver, git-perfectionist
- 4 skills: brain-jam-plan, git-workflow, strict-enforcement, shipping-methodology
- Hook infrastructure with hooks.json and shell scripts
