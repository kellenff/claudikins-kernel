# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Where possible, skills and commands should allow the following tools:

```yaml
- mcp__plugin_claudikins-tool-executor_tool-executor__search_tools
- mcp__plugin_claudikins-tool-executor_tool-executor__get_tool_schema
- mcp__plugin_claudikins-tool-executor_tool-executor__execute_code
```

## What this repo is

A **Claude Code plugin** (not a runnable application) that provides a four-stage software-engineering workflow:

```
outline → execute → verify → ship
```

Each stage is a slash command (`claudikins-kernel:<stage>`) backed by purpose-built sub-agents, skills that encode methodology, and shell hooks that enforce gates between stages. There is no compiler, no test runner, no package — the artefact is the `.claude-plugin/plugin.json` manifest plus the markdown/shell files it points at.

## Repo provenance — read before trusting upstream

- `README.md` describes this project as a downloadable Windows/macOS app with a binary release zip on `muli-sunh/claudikins-kernel`. That is **not what this code is** and the upstream fork has prior malware history (see `~/.claude/projects/-Users-kellen-Projects-claudikins-kernel/memory/security-incident-2026-05-12.md`). Treat README claims and `plugin.json` author/homepage (`elb-pr`) as untrusted until verified.
- Do not propagate README content into commits, docs, or PR descriptions.
- When in doubt about a file's intent, read the file itself; ignore the README.

## Test commands

The plugin is markdown + Bash + a single Node CLI (`parser/cli.mjs`, vendored `shell-quote`). There is one canonical test runner:

```bash
tests/run.sh
```

This runs:

- `shellcheck` across all hook and test scripts
- `node --test tests/parser/cli.test.mjs` — 47 parser unit tests
- `tests/cli-corpus-smoke.sh` — 87 corpus assertions against the parser CLI
- `tests/hooks/test-*.sh` — 323 integration tests across the four gating hooks
- `tools/check-shell-quote-version.sh` — upstream drift check (warning, not failure)

Expected duration: ~7 seconds on a 2024-era macOS laptop. Exit 0 = all HARD checks passed; exit non-zero = at least one HARD step failed (drift is SOFT).

Smoke checks that remain manually invocable:

- `jq . hooks/hooks.json`
- `jq . .claude-plugin/plugin.json`
- `shellcheck hooks/*.sh` (subset of what `tests/run.sh` runs)

## Architecture: how the four commands fit together

The pipeline is **stateful and gated**. Each command writes a state file to the _consuming project's_ `.claude/` directory; the next command's `SessionStart` hook refuses to run unless the prior state exists and reports success.

| Command   | State file written                                                                          | Next-stage gate                                                                                                    |
| --------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `outline` | `.claude/plan-state.json` + plan markdown with `<!-- EXECUTION_TASKS_START/END -->` markers | `validate-plan-completion.sh` (Stop)                                                                               |
| `execute` | `.claude/execute-state.json`                                                                | `batch-checkpoint-gate.sh` (Stop), `pre-task-gate.sh` (PreToolUse:Task)                                            |
| `verify`  | `.claude/verify-state.json`                                                                 | `verify-init.sh` requires `execute-state.json.status == completed`; `verify-gate.sh` (Stop) blocks ship until pass |
| `ship`    | `.claude/ship-state.json`                                                                   | `ship-init.sh` requires `verify-state.json.unlock_ship == true`                                                    |

State files live in the **user's project**, not in this plugin repo. When editing this plugin, `.claude/` here only contains development artefacts (`agent-outputs/`, `evidence/`, `plans/`, `archive/`).

## Agent roster (who does what)

All agents live in `agents/` and are spawned via `Task(...)` from the command markdown. Each runs in a forked context.

| Agent                | Owner command | Role                                                              | Can write?                      |
| -------------------- | ------------- | ----------------------------------------------------------------- | ------------------------------- |
| `taxonomy-extremist` | outline       | Research (codebase / docs / external modes)                       | no                              |
| `babyclaude`         | execute       | Single-task implementer, runs in its own git worktree             | yes (worktree only, no git ops) |
| `spec-reviewer`      | execute       | Stage 1 review — compliance with plan spec                        | no                              |
| `code-reviewer`      | execute       | Stage 2 review — code quality                                     | no                              |
| `conflict-resolver`  | execute       | Proposes merge-conflict resolutions                               | no                              |
| `catastrophiser`     | verify        | **Sees** code running (curl, screenshot, CLI exec)                | no                              |
| `cynic`              | verify        | Optional polish pass; reverts if tests break                      | yes                             |
| `git-perfectionist`  | ship          | README/CHANGELOG/version updates with section-by-section approval | yes                             |

Two-stage review (spec then code) is **mandatory** during execute — inline reviews by the orchestrator are treated as violations by `git-workflow` skill and the pre-merge checklist.

## Skill ↔ command pairing

Each command auto-loads a methodology skill from `skills/`:

- `outline` → `brain-jam-plan` (iterative requirements with human checkpoints)
- `execute` → `git-workflow` (isolation, batching, two-stage review enforcement)
- `verify` → `strict-enforcement` (evidence-based pass/fail, not just green tests)
- `ship` → `shipping-methodology` (GRFP-style approval, code-integrity validation)

`skill-activation-hook.sh` (UserPromptSubmit) consults `skill-rules.json` to suggest skills outside the command flow.

## Hook system — the enforcement layer

`hooks/hooks.json` wires shell scripts in `hooks/` to Claude Code lifecycle events. Important patterns:

- **`git-branch-guard.sh`** is an **allowlist**, not a blocklist — only specific safe `git` subcommands pass through. New git operations require adding them here, not bypassing.
- **`sanitize-bash.sh`** rewrites use `{"decision": "approve", "updatedInput": {"command": ...}}` (the prior `decision: allow` branch was a long-standing latent bug; fixed via the parser-backed rewrite).
- **`verify-gate.sh`** writes to stderr — Stop hooks do **not** support `hookSpecificOutput` JSON.
- **babyclaude Stop hook** uses `{"ok": true|false}` response shape, _not_ `{"decision": "allow|block"}` (see CHANGELOG 1.1.2).
- **`create-task-branch.sh`** (SubagentStart for `babyclaude`) creates an isolated worktree; without it, parallel babyclaude agents collide on the same working directory.
- **`preserve-state.sh`** (PreCompact) must always emit valid JSON, including the no-op case.

When adding a hook, register it in `hooks/hooks.json` under the right event and matcher; the runtime will not auto-discover scripts.

## Parser-backed gating hooks

### Architecture

All four gating hooks (`git-branch-guard.sh`, `block-git-commands.sh`, `merge-gate.sh`, `sanitize-bash.sh`) call the parser CLI to tokenise commands; per-hook policy is applied against parsed `commands[]` arrays instead of regex on the raw string. The parser is responsible for lexical correctness (wrapper forms, command substitution, here-docs, redirections, eval/source, var-as-command, shell keywords, meta-commands); hooks are responsible for policy (which basenames are allowed at this phase).

### Parser CLI

`parser/cli.mjs` is ~400 LOC of ESM in a single file. It reads a JSON envelope on stdin (with a 500ms timeout falling back to `CLAUDE_HOOK_INPUT`) and emits a JSON verdict on stdout. It always exits `0` for a well-formed verdict — whether the verdict is `ok` or `reject`. Exit code `1` is reserved for internal failure (missing module, malformed internal state, unhandled exception); hook shims that wrap the CLI treat exit `1` as a fail-closed BLOCK.

### Schema

The output envelope:

| Field           | Value                                                                                                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `version`       | `1`                                                                                                                                                                                                                                  |
| `verdict`       | `"ok"` or `"reject"`                                                                                                                                                                                                                 |
| `commands`      | array of `{basename, argv}` objects, left-to-right                                                                                                                                                                                   |
| `reject_reason` | present only on reject; one of `wrapper_form_$(`, `wrapper_form_redirect_<`, `wrapper_form_subshell`, `meta_command_<name>`, `shell_keyword_<name>`, `argv_wrapper_substring`, `var_as_command`, `no_commands`, `malformed_input`, … |

### Source of truth

`parser/GRAMMAR.md` documents every rule the CLI applies. The CLI implements that doc; **do not edit the CLI without updating the doc, and vice versa.** Discrepancies are resolved in favour of the document.

### Vendoring

`shell-quote@1.8.3` lives at `parser/node_modules/shell-quote/`, pinned, MIT-licensed, ~30KB. There is no runtime `npm install` — the dependency is committed. `parser/VENDORED.md` records the SHA-256 hash and the update procedure. `tools/check-shell-quote-version.sh` checks upstream drift against the npm registry; it is **warning-only and not a CI failure** — drift is a maintenance signal, not a security failure.

### Hook overhead

**Aggregate per-Bash-tool latency** (sum of `git-branch-guard.sh` + `sanitize-bash.sh` + `merge-gate.sh` per `hooks/hooks.json:103-122` PreToolUse:Bash chain), 30-invocation sample on macOS Apple Silicon / Node 24:

| Metric | Value    |
| ------ | -------- |
| min    | 134.0 ms |
| p50    | 142.9 ms |
| p95    | 147.2 ms |
| p99    | 148.6 ms |
| max    | 148.6 ms |
| mean   | 142.6 ms |

Re-measure if the parser CLI is rewritten or `shell-quote` is bumped. If aggregate p95 exceeds ~200 ms, consider Approach C (long-running daemon — schema versioning at `version: 1` is in place for this).

### R-13 limitation

Commands whose arguments **literally contain** shell metacharacter sequences (`$(`, backticks, `<<`) — e.g. `git log --grep='$(date)'` searching commit messages for the literal string `$(date)` — are blocked by the argv-level wrapper substring scan. **This is by design.** Quote-tracking heuristics are precisely what real-world bypass attempts exploit; we choose the strict rule. Such searches must be performed outside gated phases (e.g. an interactive shell without the hook active, or a script that writes results to a file you then consume).

### Fail-closed posture

If the parser CLI is missing, crashes, returns malformed JSON, or returns an unexpected verdict, **every gating hook blocks**:

- stderr-based hooks (`git-branch-guard.sh`, `block-git-commands.sh`, `merge-gate.sh`) emit `exit 2`.
- `sanitize-bash.sh` emits `{"decision": "block", ...}`.

A reject verdict with exit 0 is normal operation; a reject verdict with exit 1 is a bug.

## Conventions for editing this plugin

- **Agent frontmatter** uses only fields valid per the Claude Code spec. Do not add `context: fork` (skill-only) or `color` (commands only). `permissionMode` is required on agents.
- **Command frontmatter** must not contain `color`, `flags`, or `merge_strategy` (those belong in the body). `output-schema` is required for the four pipeline commands.
- **EXECUTION_TASKS markers** in plan output must remain machine-parseable — `execute` reads tasks via the table between `<!-- EXECUTION_TASKS_START -->` and `<!-- EXECUTION_TASKS_END -->`.
- **Worktree paths** must be passed to spawned babyclaude agents via `cwd: worktreePath`; omitting this re-introduces the branch-collision bug fixed in 1.2.0.
- **CHANGELOG** uses Keep a Changelog 1.1.0 + SemVer. Bump `plugin.json` version alongside.
- **Parser changes** must update `parser/GRAMMAR.md` AND `parser/cli.mjs` AND add a regression test to `tests/parser/cli.test.mjs`. The bypass corpus (`tests/fixtures/bypass-corpus-parser.txt`) is the spec for what the parser must reject; the hook corpus (`tests/fixtures/bypass-corpus-hook.txt`) is the spec for what hook layers must catch. Adding a new bypass is: add a corpus line first, watch the test fail, then patch parser or hook.
