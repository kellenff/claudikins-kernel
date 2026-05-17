# Parser Grammar Specification

> Behavioural specification for the parser CLI (`parser/cli.mjs`). This document
> IS the spec; the CLI implementation must conform to every rule stated here.
> Discrepancies between this document and the implementation are resolved in
> favour of this document.

---

## 1. Purpose & threat model

This document specifies how the parser CLI tokenises and classifies bash command
strings for use by Claude Code hook gating. The CLI is a static lexical
analyser: it consumes a single command-string from a hook invocation envelope,
runs it through a pinned version of `shell-quote`, walks the resulting token
stream, and emits a JSON verdict describing the commands found and whether any
wrapper-form or meta-command violation was detected.

The threat model treats the **command string as adversarial input**. It may
contain quoting tricks, nested substitution syntax, encoded redirections, comment
injection, and other attempts to disguise what the bash shell would actually
execute. The **parser library (`shell-quote`) is trusted** — its tokenisation
defines our lexical ground truth. The CLI inspects parsed tokens at decision
time only; **runtime alias resolution, function expansion, parameter expansion,
brace expansion, pathname expansion, and command substitution execution are
explicitly out of scope**. If the live shell would resolve `git` to a function
that runs `rm -rf /`, this CLI cannot and will not detect that — alias/function
expansion is the host shell's responsibility, not the gate's.

---

## 2. Parse mode

The CLI invokes `shell-quote` with an **identity env shim** that preserves
every variable reference as its literal `$NAME` form:

```js
import { parse as shellQuoteParse } from "shell-quote";
const tokens = shellQuoteParse(commandString, (name) => "$" + name);
```

That is: **identity env shim, default escape behaviour**. Pinned version:
`shell-quote@1.8.3` (see `parser/VENDORED.md`).

### Why the identity env shim

`shell-quote.parse(str, env)` substitutes `$VAR` references against the
provided `env` mapping. The default behaviour (no env arg or `env={}`) is to
**replace unknown vars with the empty string**, which is hostile to our use
case for two reasons — both demonstrated against `shell-quote@1.8.3`:

1. **Empty-string collapse hides the variable.** Without the shim:

   ```
   parse("$EVIL args")          → ["", "args"]
   ```

   The `$EVIL` token becomes `""`. §7's var-as-command rule catches the empty
   token, but the unresolved variable name itself is gone.

2. **Substring-concatenation bypass.** Without the shim:

   ```
   parse("$PATH/bin/git -anything") → ["/bin/git", "-anything"]
   ```

   `$PATH` collapses to `""`, leaving the suffix `/bin/git` to be parsed as a
   normal path. The basename becomes `git` — a value that would pass any
   command-allowlist gate. The attacker has smuggled a variable-controlled
   command past the lexer.

With the identity shim `name => '$' + name`, `shell-quote` returns the literal
`$NAME` string for every variable lookup, so both inputs above tokenise as:

```
parse("$EVIL args",            n => '$'+n) → ["$EVIL", "args"]
parse("$PATH/bin/git -ignored", n => '$'+n) → ["$PATH/bin/git", "-ignored"]
```

The walker now sees a string token whose first character is `$`. §7's
var-as-command rule rejects it (basename extraction yields `$PATH/bin/git`,
which starts with `$`), closing the substring-concatenation bypass.

### Default escape

The default escape character (`\`) handling matches POSIX shell behaviour as
closely as `shell-quote` can model. We do not override it.

---

## 3. Token shapes and dispositions

`shell-quote.parse` returns an array whose entries are one of:

- A plain string (a literal word, possibly multi-character)
- An object with an `op` field (an operator token)
- An object with a `comment` field (a `#`-prefixed comment)
- An object with a `glob` field (an unexpanded glob pattern)

The table below enumerates every token shape we recognise and the disposition
the walker applies.

| Token shape                           | Example                  | Disposition                                                                                                                                                                                                                                                                 | Reject reason (if any)                          |
| ------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Plain string                          | `"git"`                  | Walk; collect into current argv. First token of argv (after env-strip) is the command-position basename.                                                                                                                                                                    | (varies; see §7, §10, §11)                      |
| `{op:"&&"}`                           | `git pull && git push`   | Command-position separator — finalises current argv, starts a new one.                                                                                                                                                                                                      | —                                               |
| `{op:"\|\|"}`                         | `test -f x \|\| touch x` | Command-position separator.                                                                                                                                                                                                                                                 | —                                               |
| `{op:";"}`                            | `cd /tmp; ls`            | Command-position separator.                                                                                                                                                                                                                                                 | —                                               |
| `{op:"\|"}`                           | `cat foo \| grep bar`    | Command-position separator (pipeline).                                                                                                                                                                                                                                      | —                                               |
| `{op:"&"}`                            | `long-job &`             | Command-position separator (backgrounding).                                                                                                                                                                                                                                 | —                                               |
| `{op:"("}`                            | `( cd /tmp && ls )`      | Subshell open. Standalone (i.e. not immediately preceded by the string token `'$'`) → reject.                                                                                                                                                                               | `wrapper_form_subshell`                         |
| `{op:")"}`                            | `( cd /tmp && ls )`      | Subshell close — acts as a command-position separator for purposes of argv finalisation.                                                                                                                                                                                    | —                                               |
| String token `'$'`                    | `echo $(date)`           | Literal dollar. If immediately followed by `{op:"("}` → command substitution opener (rejected as a wrapper form). Otherwise treated as a normal string. With the §2 env shim, unresolved `$NAME` arrives as a **single** string token `"$NAME"` (the `$` is not split off). | `wrapper_form_$(` (when followed by `{op:"("}`) |
| `{op:"<"}`                            | `cat < file`             | Input redirection. ANY op whose `op` value starts with `<` is rejected (covers `<`, `<<<`, `<&`, `<(`).                                                                                                                                                                     | `wrapper_form_redirect_<`                       |
| `{op:"<<<"}`                          | `cat <<<"hello"`         | Here-string. Rejected by the `<`-prefix rule.                                                                                                                                                                                                                               | `wrapper_form_redirect_<`                       |
| `{op:"<&"}`                           | `exec 3<&0`              | FD dup-input. Rejected by the `<`-prefix rule.                                                                                                                                                                                                                              | `wrapper_form_redirect_<`                       |
| `{op:"<("}`                           | `diff <(cmd1) <(cmd2)`   | Process substitution. Rejected by the `<`-prefix rule.                                                                                                                                                                                                                      | `wrapper_form_redirect_<`                       |
| `{op:">"}`                            | `cmd > out`              | Output redirection — **allowed**. Writes are not a parser-gate concern; downstream policies enforce write authorisation.                                                                                                                                                    | —                                               |
| `{op:">>"}`                           | `cmd >> log`             | Append redirection — allowed (same rationale).                                                                                                                                                                                                                              | —                                               |
| `{op:">&"}`                           | `cmd 2>&1`               | FD dup-output — allowed.                                                                                                                                                                                                                                                    | —                                               |
| `{comment:"..."}`                     | `git push # comment`     | Stripped from the command stream before walking. If the comment string contains `\n` followed by non-whitespace, log a warning.                                                                                                                                             | — (still stripped)                              |
| `{glob:{pattern}}`                    | `ls *.txt`               | Treated as a plain string argument. Do not expand the glob.                                                                                                                                                                                                                 | — (no expansion)                                |
| Embedded `\n` in a plain string token | `"line1\nline2"`         | Treat the `\n` as a command-position separator: split the string into two argv elements at the newline boundary.                                                                                                                                                            | —                                               |

### Notes on multi-char redirections

`shell-quote@1.8.3` does **not** tokenise `<<` or `<>` as single ops — its
`CONTROL` regex contains `<<<`, `<&`, `<(`, and the single-char class
`[&;()|<>]`, but no `<<` or `<>` branch. Those sequences therefore
decompose into two adjacent single-char ops:

```
parse("cat <<EOF")   → ["cat", {op:"<"}, {op:"<"}, "EOF"]
parse("cat <> file") → ["cat", {op:"<"}, {op:">"}, "file"]
```

The §9 rule "any op token whose value starts with `<`" fires on the **first**
`{op:"<"}` of either sequence, so the rejection still happens at the leftmost
token. No separate `{op:"<<"}` / `{op:"<>"}` shape needs to be handled.

### Notes on comment stripping

`shell-quote` emits `{comment:"..."}` for a `#`-prefixed segment up to end-of-input.
In a normal command line, there is at most one comment token. However, the
adversarial corpus contains crafted inputs where the comment string itself
encodes a newline followed by additional command text (an attempt to smuggle
content past the gate). The walker **still strips the comment** in that case —
the rule is mechanical — but emits a warning to stderr so a human reviewer can
audit the corpus. The bypass attempt is then expected to be caught downstream
by the wrapper-form rules (§9) or the meta-command block list (§10) once a
follow-up test vector is added.

### Notes on globs

`shell-quote` returns `{glob:{pattern:"..."}}` for unquoted wildcard patterns.
The CLI does **not** expand globs; the pattern string is treated as an opaque
literal for the purposes of basename extraction and the argv-level wrapper
scan. If the user wrote `ls *.sh`, the second argv element is the glob pattern
`*.sh`, not the expanded file list.

---

## 4. Command-position walker

The walker iterates the token stream once, left-to-right, accumulating tokens
into a per-command `argv` array. Whenever a command-position separator is
encountered, the current argv is finalised (if non-empty) and a new one is
started. At the end of the stream, the final argv is finalised.

**REJECT contract.** Throughout the pseudocode below, `REJECT(reason)` is a
terminating action: it emits the JSON verdict
`{version:1, verdict:"reject", reject_reason:reason, commands:[]}` on stdout,
exits the process with code `0` (see §14), and terminates the walker. No
further tokens are inspected.

**`prev` tracking.** `prev` holds the **previous string-or-op token** the
walker saw (comments are ignored for this purpose). It is consulted only by
the `{op:"("}` case to decide whether the open paren is a command-substitution
opener (prev is the string token `'$'`) or a standalone subshell.

Pseudocode:

```
function walk(tokens):
    commands = []
    argv = []
    prev = null
    for tok in tokens:
        if isComment(tok):
            maybeWarnOnEmbeddedNewline(tok)
            continue
        else if isSeparatorOp(tok):           # &&, ||, ;, |, &, )
            finalise(argv, commands)
            argv = []
            prev = tok
            continue
        else if isOpenParen(tok):             # {op:"("}
            if prev is the string token '$':
                REJECT("wrapper_form_$(")
            else:
                REJECT("wrapper_form_subshell")
        else if isLessThanOp(tok):            # any op whose value starts with "<"
            REJECT("wrapper_form_redirect_<")
        else if isString(tok):
            for segment in splitOnNewline(tok):
                if segment == "":
                    finalise(argv, commands)   # leading/trailing/embedded empty
                    argv = []                  # segments finalise the current argv
                else:
                    argv.push(segment)
            prev = tok
            continue
        else if isGlob(tok):
            argv.push(tok.pattern)
            prev = tok
            continue
        # Any other op (>, >>, >&, etc.) is allowed; advance prev and continue.
        prev = tok
    finalise(argv, commands)
    return commands
```

`finalise(argv, commands)` performs env-prefix stripping (§5) and pushes
`{basename, argv}` onto `commands` if the stripped argv is non-empty. Empty
argvs are silently dropped at finalisation; the §8 empty-commands check is
applied to the final `commands` array, not to individual argvs.

**splitOnNewline finalisation.** `splitOnNewline("\nfoo")` yields
`["", "foo"]`; `splitOnNewline("foo\n")` yields `["foo", ""]`;
`splitOnNewline("a\n\nb")` yields `["a", "", "b"]`. Each empty segment
triggers a `finalise(argv, commands)` call. Leading/trailing empty segments
therefore produce no-op finalisations when the argv being built is already
empty — they are silently dropped by `finalise`'s "drop empty argv" rule
above. Embedded empty segments (`"a\n\nb"`) collapse to a single argv
boundary.

---

## 5. Env-prefix stripping

A shell command may have leading `VAR=value` assignments that scope a single
invocation, e.g. `LANG=C git log`. These are environment assignments, not
commands.

**Rule:** any leading token in an argv whose string value matches the regex

```
^[A-Za-z_][A-Za-z0-9_]*=
```

is **stripped** from the argv. The check is repeated iteratively: as long as
the first remaining token matches that regex, it is removed.

After stripping, the **first remaining token** is the command-position
basename. If stripping consumes the entire argv (i.e. the argv was nothing but
env-assignments), the argv is treated as empty and dropped at finalisation —
this is consistent with bash's behaviour for `LANG=C` on its own (which sets
the variable for the duration of a non-existent command, a no-op for our
purposes).

### Examples

| Original argv                 | After env-strip            | Basename                                            |
| ----------------------------- | -------------------------- | --------------------------------------------------- |
| `["LANG=C", "git", "log"]`    | `["git", "log"]`           | `git`                                               |
| `["A=1", "B=2", "C=3", "ls"]` | `["ls"]`                   | `ls`                                                |
| `["FOO=bar"]`                 | `[]`                       | (dropped)                                           |
| `["./script.sh", "VAR=1"]`    | `["./script.sh", "VAR=1"]` | `script.sh` (only leading assignments are stripped) |

---

## 6. Basename extraction

Given the first remaining token after env-strip, the basename is computed as:

```js
import path from "node:path";
const basename = path.basename(token);
```

This handles both POSIX and Windows path separators via Node's `path.basename`
(though the CLI is primarily a POSIX tool).

### Examples

| Token            | Basename |
| ---------------- | -------- |
| `/usr/bin/git`   | `git`    |
| `git`            | `git`    |
| `./scripts/x.sh` | `x.sh`   |
| `../../bin/foo`  | `foo`    |
| `bash`           | `bash`   |

---

## 7. Var-as-command rule

If, after env-strip, the command-position token is **empty** OR **begins with a
literal `$` character** (an unresolved variable expansion that the walker did
not collapse), the entire envelope is rejected with reason `var_as_command`.

### Rationale

`$EVIL some-args` is a runtime-determined command. The gate cannot know what
`$EVIL` resolves to without executing in the host shell; allowing it would let
adversarial input bypass every other rule by hiding the command name behind a
variable.

### Examples

| Argv (after env-strip) | Verdict             | Reason                                     |
| ---------------------- | ------------------- | ------------------------------------------ |
| `["$EVIL", "args"]`    | reject              | `var_as_command`                           |
| `["", "args"]`         | reject              | `var_as_command`                           |
| `["$PATH/bin/git"]`    | reject              | `var_as_command` (begins with `$`)         |
| `["git", "$BRANCH"]`   | ok (subject to §11) | `$BRANCH` is an argv, not command-position |

---

## 8. Empty-commands rule

If, after walking the entire token stream, the resulting `commands` list is
empty, the envelope is rejected with reason `no_commands`.

This catches:

- An empty command string.
- A command string consisting only of comments or whitespace.
- A command string consisting only of env assignments that strip to empty argvs.
- Pathological separator-only inputs (e.g. `;;;` or `&&`).

---

## 9. Wrapper-form rejections (op-level)

The walker rejects the following operator-token forms **before** falling back
to the argv-level substring scan (§11). These rules fire at op-token boundaries
and produce specific reject reasons:

| Form                                                    | Reject reason                                          |
| ------------------------------------------------------- | ------------------------------------------------------ |
| Any `{op}` whose value **starts with `<`**              | `wrapper_form_redirect_<`                              |
| String token `'$'` immediately followed by `{op:"("}`   | `wrapper_form_$(`                                      |
| Standalone `{op:"("}` (no preceding string token `'$'`) | `wrapper_form_subshell`                                |
| `{op:"<("}` (process substitution)                      | `wrapper_form_redirect_<` (covered by `<`-prefix rule) |

The `<`-prefix rule is deliberately broad: it covers `<`, `<<<`, `<&`, and
`<(` with a single check. The multi-char forms `<<` and `<>` decompose into
two adjacent `{op:"<"}` (or `{op:"<"}` + `{op:">"}`) tokens (see §3); the
first `<` op fires this rule before the second token is reached. New
`<`-prefixed operators that `shell-quote` may emit in future versions are
caught automatically.

Process substitution (`<(...)`) is sometimes treated as a distinct concept in
bash, but lexically it begins with `<` and falls under the same rule. We do
not emit a separate `wrapper_form_proc_sub` reject reason for it — the
`<`-prefix rule wins.

> **Reserved reject reasons.** The schema in §13 includes
> `wrapper_form_proc_sub`, `wrapper_form_backtick`, and `wrapper_form_ansi_c`
> as reserved values. The CLI does not emit them via op-level rules — `<(` is
> covered by the `<`-prefix rule, and backtick / `$'...'` forms are caught by
> the argv-level substring scan (§11) which surfaces as `argv_wrapper_substring`.
> They are reserved in the schema so that future versions of `shell-quote` that
> tokenise these constructs into distinct op markers can emit a more specific
> reason without a schema bump.

---

## 10. Meta-command basename block list

After env-strip and basename extraction, the basename is compared against the
following block list. A match rejects the envelope with reason
`meta_command_<name>` where `<name>` is the matched basename.

**Block list (19 commands):**

```
eval, source, ., exec, command, builtin, bash, sh, zsh, dash, ksh,
env, xargs, parallel, nohup, setsid, time, watch, coproc
```

### Rationale per category

| Category              | Commands                           | Why blocked                                                                                                                                                                        |
| --------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Direct evaluators     | `eval`, `source`, `.`              | Execute arbitrary strings as shell code — total bypass of any static lexer.                                                                                                        |
| Process replacers     | `exec`                             | Replaces the shell process; subsequent argv tokens become an unconstrained new command.                                                                                            |
| Shell-builtin escapes | `command`, `builtin`               | Bypass alias/function resolution to invoke a raw builtin or external binary; gate-evasion.                                                                                         |
| Sub-shells            | `bash`, `sh`, `zsh`, `dash`, `ksh` | Spawn a fresh shell with a `-c` string we'd then need to re-parse. Out of scope.                                                                                                   |
| Env-as-wrapper        | `env`                              | `env CMD args` lets the caller pick `CMD` after env-mutation; recursive parsing required.                                                                                          |
| Argument multipliers  | `xargs`, `parallel`                | Read stdin / args and construct new command lines per item; impossible to lexically constrain. `parallel git ::: push` runs `git push` once the gate has waved `parallel` through. |
| Detachers             | `nohup`, `setsid`                  | Wrap an inner command; we'd need to re-parse the wrapped command.                                                                                                                  |
| Timers/wrappers       | `time`, `watch`                    | Same wrapper pattern as `nohup` (`time CMD`, `watch CMD`); inner command must be re-parsed.                                                                                        |
| Co-processes          | `coproc`                           | Starts a background co-process from a following command word; same wrapper concern.                                                                                                |

### Examples

| Command              | Basename  | Verdict                |
| -------------------- | --------- | ---------------------- |
| `eval "rm -rf /"`    | `eval`    | `meta_command_eval`    |
| `time git log`       | `time`    | `meta_command_time`    |
| `/bin/bash -c "..."` | `bash`    | `meta_command_bash`    |
| `xargs -I{} rm {}`   | `xargs`   | `meta_command_xargs`   |
| `command git push`   | `command` | `meta_command_command` |

---

## 10.5 Shell-keyword basename block list

After env-strip and basename extraction, but **before** the meta-command
check (§10), the basename is compared against a second block list: bash
compound-statement keywords. A match rejects the envelope with reason
`shell_keyword_<name>` where `<name>` is the matched basename.

### Rationale

These tokens are not commands; they are **compound-statement introducers**
or block delimiters (`for`, `while`, `if`, `case`, `function`, `select`,
`do`, `done`, `then`, `else`, `elif`, `fi`, `esac`, `in`). Their presence
in command position implies the input contains a control-flow block — a
`for` loop body, an `if` branch, a `function` definition that shadows a
gated command. Per-command policy cannot model per-block intent: the gate
must refuse to make a decision rather than wave through a body whose
behaviour depends on the loop / branch / function it lives inside.

`shell-quote` does not lex these as a distinct token shape — they arrive
as ordinary string tokens. The walker therefore catches them at
basename-comparison time, the same mechanism §10 uses for meta-commands.
The shell-keyword check is ordered **before** the meta-command check so
that a `for x in y; do ksh -c '...'; done` input surfaces as
`shell_keyword_for` (the outermost violation), not `meta_command_ksh`.

`time` is intentionally **not** in this set despite appearing in some
bash grammars as a keyword — it is already covered by §10 as a
meta-command (`time CMD` wraps an inner command, identically to `nohup`).

**Block list (15 keywords):**

```
for, while, until, if, case, function, select,
do, done, then, else, elif, fi, esac, in
```

### Examples

| Command                               | Basename   | Verdict                  |
| ------------------------------------- | ---------- | ------------------------ |
| `for x in y; do git push; done`       | `for`      | `shell_keyword_for`      |
| `while true; do git push; done`       | `while`    | `shell_keyword_while`    |
| `if true; then git push; fi`          | `if`       | `shell_keyword_if`       |
| `function git { evilbin; }; git push` | `function` | `shell_keyword_function` |
| `case $x in y) git push;; esac`       | `case`     | `shell_keyword_case`     |

---

## 11. Argv-level wrapper substring scan

After op-level rejections (§9) and meta-command rejections (§10) have passed,
the walker performs a **substring scan** over every argv item across all
command positions. This catches wrapper-form syntax that survived as part of a
quoted argument string rather than as a discrete op token.

### Scan targets

For each **string** token in any argv (command-position OR argument-position),
scan for any of the following substrings:

| Substring | Catches                                                                                        |
| --------- | ---------------------------------------------------------------------------------------------- |
| `$(`      | Command substitution `$(...)` inside a quoted argument.                                        |
| `` ` ``   | Literal backtick — legacy command substitution.                                                |
| `<<`      | Here-doc or here-string embedded in a quoted argument (also matches the `<<<` here-string).    |
| `<(`      | Process substitution embedded in a quoted argument.                                            |
| `$'`      | ANSI-C quoting (`$'...'`); allows escape sequences shell-quote may not unwrap.                 |
| `\$\(`    | Escape-game: `\$\(` survives `shell-quote` as a literal but bash unescapes it at execute time. |

Substrings overlap deliberately: a `<<<` here-string is matched by the `<<`
row above (any string containing `<<<` necessarily contains `<<`), so no
separate `<<<` row is needed. The aggressive overlap is preferred to a tight
list because it survives future shell-syntax additions that compose existing
sequences.

For `{op}` markers that `shell-quote` emits **inside** an argv (which can
happen when a quoted argument contains substitution syntax that
`shell-quote` partially tokenises into op markers), the op value is matched
against the §9 operator block list. Any match → reject.

A match anywhere in the argv space rejects the envelope with reason
`argv_wrapper_substring`.

### Examples

| Argv                                     | Verdict                  |
| ---------------------------------------- | ------------------------ |
| `["git", "log", "--grep=$(date)"]`       | `argv_wrapper_substring` |
| `["echo", "hello`world`"]`               | `argv_wrapper_substring` |
| `["cat", "<<EOF"]` (if seen as a string) | `argv_wrapper_substring` |
| `["printf", "$'\\x41'"]`                 | `argv_wrapper_substring` |
| `["grep", "pattern", "file.txt"]`        | ok                       |

The scan is intentionally aggressive. See §16 for the user-facing implication.

---

## 12. CLI input

The CLI reads its input envelope from **stdin first**, with an environment
variable fallback.

### Stdin

The CLI begins reading stdin immediately. If after **500ms** no data has
arrived **or** if stdin yields zero bytes on EOF, the CLI falls back to the
`CLAUDE_HOOK_INPUT` environment variable. The timeout is overridable via the
`CLAUDE_PARSER_STDIN_TIMEOUT_MS` environment variable (parsed as a base-10
integer; non-numeric values fall back to the 500ms default).

500ms is a defensive default that tolerates loaded hosts, Node.js startup
cost, and shell-wrapper IPC overhead. Tightening this default should be backed
by per-host measurement of stdin arrival latency under realistic load; a
too-tight value will silently race past valid stdin envelopes onto the
environment-variable fallback path, which is harder to debug than a timeout.

If `CLAUDE_HOOK_INPUT` is also empty or unset, the CLI exits with `exit 1`
(internal failure — no input).

### Envelope shape

The envelope is a JSON object with the following accepted shapes:

```jsonc
// Canonical snake_case form
{
  "version": 1,
  "tool_input": { "command": "git push origin main" }
}

// camelCase variant (also accepted)
{
  "version": 1,
  "toolInput": { "command": "git push origin main" }
}
```

### Field rules

- `tool_input.command` (snake_case) is the canonical field.
- `toolInput.command` (camelCase) is accepted as an alias.
- If **both** are present in the same envelope, **snake_case wins** (`tool_input.command` is used; the camelCase field is silently ignored).
- The top-level `version` field is optional. If omitted, the CLI treats it as
  `1`. If explicitly present, only `version === 1` is accepted; any other
  value (including string `"1"`, `0`, `2`, `null`) is rejected as
  `malformed_input`.
- If the envelope is not valid JSON, or if neither `tool_input.command` nor
  `toolInput.command` is a string, the envelope is rejected as
  `malformed_input`.

### Examples

| Envelope                                                                         | Result                              |
| -------------------------------------------------------------------------------- | ----------------------------------- |
| `{"tool_input":{"command":"ls"}}`                                                | accept; version defaults to 1       |
| `{"version":1,"toolInput":{"command":"ls"}}`                                     | accept                              |
| `{"version":1,"tool_input":{"command":"ls"},"toolInput":{"command":"rm -rf /"}}` | accept; uses `ls` (snake-case wins) |
| `{"version":2,"tool_input":{"command":"ls"}}`                                    | reject `malformed_input`            |
| `{"tool_input":{}}`                                                              | reject `malformed_input`            |
| `not json`                                                                       | reject `malformed_input`            |

---

## 13. CLI output

The CLI **always** writes a JSON object to stdout. The schema is:

```jsonc
{
  "version": 1,
  "verdict": "ok" | "reject",
  "commands": [
    { "basename": "git", "argv": ["git", "push", "origin", "main"] }
  ],
  "reject_reason": "..." // present only on reject
}
```

### Field rules

- `version` is always `1`.
- `verdict` is exactly `"ok"` or `"reject"`.
- `commands` is an array of `{basename, argv}` objects, in left-to-right order
  as encountered in the input.
- On `verdict === "ok"`, `reject_reason` is **omitted** entirely from the
  output object.
- On `verdict === "reject"`, `reject_reason` is **required** and is one of the
  enumerated values below. `commands` may be empty or partial (whatever was
  successfully collected before the rejecting token was seen).

### Enumerated reject_reason values

The complete set is:

```
wrapper_form_$(
wrapper_form_backtick
wrapper_form_redirect_<
wrapper_form_subshell
wrapper_form_proc_sub
wrapper_form_ansi_c
meta_command_<name>
shell_keyword_<name>
argv_wrapper_substring
var_as_command
no_commands
malformed_input
```

That is **12 schema-level values**. Two of them are parameterised:

- `meta_command_<name>` substitutes the matched basename, yielding one
  concrete string per entry in the §10 block list (19 entries → 19 concrete
  `meta_command_*` values: `meta_command_eval`, `meta_command_source`,
  `meta_command_.`, `meta_command_exec`, `meta_command_command`,
  `meta_command_builtin`, `meta_command_bash`, `meta_command_sh`,
  `meta_command_zsh`, `meta_command_dash`, `meta_command_ksh`,
  `meta_command_env`, `meta_command_xargs`, `meta_command_parallel`,
  `meta_command_nohup`, `meta_command_setsid`, `meta_command_time`,
  `meta_command_watch`, `meta_command_coproc`).
- `shell_keyword_<name>` substitutes the matched basename, yielding one
  concrete string per entry in the §10.5 block list (15 entries → 15
  concrete `shell_keyword_*` values: `shell_keyword_for`,
  `shell_keyword_while`, `shell_keyword_until`, `shell_keyword_if`,
  `shell_keyword_case`, `shell_keyword_function`, `shell_keyword_select`,
  `shell_keyword_do`, `shell_keyword_done`, `shell_keyword_then`,
  `shell_keyword_else`, `shell_keyword_elif`, `shell_keyword_fi`,
  `shell_keyword_esac`, `shell_keyword_in`).

All other values are literal strings. The enumerable total at the wire
level is therefore **44 concrete reject_reason strings** (10 literals + 19
meta-command expansions + 15 shell-keyword expansions).

As noted in the §9 "Reserved reject reasons" callout,
`wrapper_form_backtick`, `wrapper_form_proc_sub`, and `wrapper_form_ansi_c`
are reserved in the schema for future precision but the CLI currently routes
those constructs through `argv_wrapper_substring` (§11) or the `<`-prefix
rule (§9). When `shell-quote` begins emitting distinct op markers for those
constructs, the corresponding reserved value may be promoted to active use
without a schema bump.

---

## 14. Exit-code semantics

The CLI uses exactly two exit codes.

| Exit code | Meaning                                                                                                                                               |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0`       | The CLI produced a well-formed JSON verdict on stdout. This is the success case for **both** `verdict: "ok"` and `verdict: "reject"`.                 |
| `1`       | The CLI itself failed: an unhandled exception during parse, a missing/broken `shell-quote` module, malformed internal state, no input available, etc. |

### Hook integration

Hook shims that wrap this CLI **must** treat `exit 1` as a **fail-closed BLOCK**
— if the CLI cannot produce a verdict, no command should be allowed through.
Hook shims that see `exit 0` should consume the JSON verdict from stdout and
act on the `verdict` field; they should **not** infer block/allow from the
exit code alone.

A reject verdict (`{"verdict":"reject", ...}`) with `exit 0` is a normal
operating outcome, not an error. A reject verdict with `exit 1` is a bug.

---

## 15. Parse-vs-execution divergence

`shell-quote` is a JavaScript approximation of bash word-splitting. It is
**not** an interpreter and does **not** perform any of the runtime
transformations bash applies before executing a command:

| Bash phase                        | Performed by `shell-quote`? |
| --------------------------------- | --------------------------- |
| Tokenisation / word-splitting     | yes (the whole point)       |
| Brace expansion (`{a,b,c}`)       | no                          |
| Tilde expansion (`~`, `~user`)    | no                          |
| Parameter expansion (`$VAR`)      | no (we explicitly disable)  |
| Command substitution execution    | no                          |
| Arithmetic expansion (`$((1+1))`) | no                          |
| Process substitution execution    | no                          |
| Pathname expansion (glob match)   | no                          |
| Quote removal                     | partial                     |
| Alias / function resolution       | no (shell-time only)        |

The CLI's view of "what runs" is therefore the **lexical token stream** as
`shell-quote` sees it. Bash's view at execution time may legitimately differ —
for instance, `${ls,/}` is an undefined parameter expansion that bash would
reject at execute-time but `shell-quote` may tokenise as `["${ls,/}"]`.

### How we mitigate the divergence

1. **Hard-reject wrapper forms** (§9): all substitution-style syntax
   (`$(`, `<(`, `<<`, here-docs) is blocked at the token level so we never
   need to know what they'd evaluate to.
2. **Argv-level substring scan** (§11): catches the same syntax even when
   `shell-quote` swallows it into a quoted string instead of emitting
   discrete ops.
3. **Var-as-command rule** (§7): blocks any command whose first token would
   require bash execution to know.
4. **Meta-command block list** (§10): blocks every command we know of that
   would interpret a subsequent argument as new shell code.

### What's still divergent

- Brace and tilde expansion at the argument position is unchecked. `rm ~/*` is
  parsed as `["rm", "~/*"]`; bash will expand it to `rm /home/you/<everything>`.
  This is **out of scope** for the parser-gate; the policy gate above (§16) is
  responsible for deciding whether `rm` is allowed at all.
- Bash builtins that take a string and re-parse it (`printf` with `%b`,
  `read -e`, etc.) are not in the meta-command list. If a new builtin with
  this property appears in the corpus, it should be added to §10.

Bypasses found outside the four mitigations above are **corpus additions, not
parser bugs**. The corpus is in `tests/fixtures/bypass-corpus.txt`.

---

## 16. R-13 limitation

By design, the argv-level substring scan (§11) rejects any command whose
arguments **literally contain** shell metacharacter sequences — even if those
sequences are inside a single-quoted argument that bash would treat as a
literal string at execute time.

### The case

```
git log --grep='$(date)'
```

The intent here is to search commit messages for the literal substring
`$(date)`. Bash would honour the single quotes and pass `--grep=$(date)` to
`git log` as a literal argument; no command substitution occurs. **But our
parser cannot know that** — by the time the token stream reaches us,
`shell-quote` has already collapsed the quotes, and the argv element is the
string `--grep=$(date)`. The substring scan sees `$(` and rejects.

### Why this is policy, not a workaround

The alternative — tracking quote provenance per character through the
tokeniser — is fragile, error-prone, and is precisely the kind of "do what I
mean" complexity an adversarial input can exploit. Many real-world bypass
attempts hide substitution syntax inside what looks like a single-quoted
argument, knowing that quote-tracking heuristics often get it wrong.

We choose the strict rule: **if your argument literally contains `$(`, `` ` ``,
`<<`, `<(`, `$'`, or `\$\(`, you cannot run it through a gated phase.**

### User guidance

If you genuinely need to grep for a literal substring like `$(date)`, perform
the search **outside a gated phase** (e.g. in an interactive shell without the
hook active, or via a script that does the search and writes its output to a
file you then consume). The block is the gate doing its job, not a bug to
file.

If you encounter R-13 in a flow that should be allowed, the correct response
is to add the specific exception to a higher-level policy layer — not to relax
this rule.
