// tests/parser/cli.test.mjs
// Unit tests for parser/cli.mjs. Run with: node --test tests/parser/
// Covers every section of parser/GRAMMAR.md (groups A-L below).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.resolve(HERE, '..', '..', 'parser', 'cli.mjs');

// ----- harness -------------------------------------------------------------

// Run cli.mjs with the given command. `opts.envelope` overrides the default
// `{version:1, tool_input:{command}}`. `opts.stdinOverride` replaces the
// serialised stdin entirely (used to inject raw bytes / malformed JSON).
// `opts.env` adds environment variables. Returns parsed stdout, raw streams,
// and exit code.
function runCli(command, opts = {}) {
    const envelope = opts.envelope ?? { version: 1, tool_input: { command } };
    const stdin = opts.stdinOverride ?? JSON.stringify(envelope);
    const env = { ...process.env, ...(opts.env ?? {}) };
    // Drop CLAUDE_HOOK_INPUT from inherited env unless caller set one.
    if (!(opts.env && 'CLAUDE_HOOK_INPUT' in opts.env)) {
        delete env.CLAUDE_HOOK_INPUT;
    }
    const result = spawnSync('node', [CLI], {
        input: stdin,
        env,
        encoding: 'utf8',
        timeout: 5000,
    });
    let parsed = null;
    try { parsed = JSON.parse(result.stdout); } catch { /* ignore */ }
    return {
        stdout: result.stdout,
        stderr: result.stderr,
        parsed,
        exitCode: result.status,
    };
}

// ----- Group A: §2 parse mode + env shim ----------------------------------

test('A1: $EVIL args → reject var_as_command (env shim preserves $EVIL)', () => {
    const r = runCli('$EVIL args');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'var_as_command');
});

test('A2: $PATH/bin/git -anything → reject var_as_command (substring-concat bypass closed)', () => {
    const r = runCli('$PATH/bin/git -anything');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'var_as_command');
});

test('A3: git status (no $-vars) → ok, basename git', () => {
    const r = runCli('git status');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
});

// ----- Group B: §4 command-position walker --------------------------------

test('B1: git status → 1 command, basename git, argv [git,status]', () => {
    const r = runCli('git status');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands.length, 1);
    assert.equal(r.parsed.commands[0].basename, 'git');
    assert.deepEqual(r.parsed.commands[0].argv, ['git', 'status']);
});

test('B2: cd repo && git push → 2 commands', () => {
    const r = runCli('cd repo && git push');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands.length, 2);
    assert.equal(r.parsed.commands[0].basename, 'cd');
    assert.equal(r.parsed.commands[1].basename, 'git');
});

test('B3: git status; git diff → 2 commands', () => {
    const r = runCli('git status; git diff');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands.length, 2);
});

test('B4: git status | wc -l → 2 commands (pipe)', () => {
    const r = runCli('git status | wc -l');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands.length, 2);
    assert.equal(r.parsed.commands[1].basename, 'wc');
});

test('B5: embedded \\n\\n inside quoted string → 2 commands (newline-as-separator)', () => {
    // shell-quote eats unquoted \n as whitespace, so we put it inside quotes
    // and exploit the empty-segment-finalises behaviour from §4.
    const r = runCli('echo "git status\n\ngit diff"');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands.length, 2);
});

test('B6: false || git push (||) → 2 commands', () => {
    const r = runCli('false || git push');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands.length, 2);
});

// ----- Group C: §5 env-prefix strip ---------------------------------------

test('C1: GIT_DIR=/tmp git status → ok, basename git (one env-prefix stripped)', () => {
    const r = runCli('GIT_DIR=/tmp git status');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
    assert.deepEqual(r.parsed.commands[0].argv, ['git', 'status']);
});

test('C2: FOO=1 BAR=2 git status → ok, basename git (two env-prefixes stripped)', () => {
    const r = runCli('FOO=1 BAR=2 git status');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
    assert.deepEqual(r.parsed.commands[0].argv, ['git', 'status']);
});

test('C3: argv mid-position VAR=1 is not stripped (only leading)', () => {
    const r = runCli('./script.sh VAR=1');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'script.sh');
    assert.deepEqual(r.parsed.commands[0].argv, ['./script.sh', 'VAR=1']);
});

// ----- Group D: §6 basename extraction ------------------------------------

test('D1: /usr/bin/git status → basename git (absolute path stripped)', () => {
    const r = runCli('/usr/bin/git status');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
});

test('D2: ./scripts/x.sh arg → basename x.sh', () => {
    const r = runCli('./scripts/x.sh arg');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'x.sh');
});

test('D3: ../../bin/foo → basename foo', () => {
    const r = runCli('../../bin/foo');
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'foo');
});

// ----- Group E: §7 var-as-command -----------------------------------------

test('E1: $EVIL args → reject var_as_command', () => {
    const r = runCli('$EVIL args');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'var_as_command');
});

test('E2: ${cmd} push → reject var_as_command (braced expansion preserved as $cmd)', () => {
    const r = runCli('${cmd} push');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'var_as_command');
});

// ----- Group F: §8 empty-commands -----------------------------------------

test('F1: empty command string → reject no_commands', () => {
    const r = runCli('');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'no_commands');
});

test('F2: env-only command (FOO=bar) → reject no_commands (strips to nothing)', () => {
    const r = runCli('FOO=bar');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'no_commands');
});

// ----- Group G: §9 wrapper-form rejections --------------------------------

test('G1: $(git push) → reject wrapper_form_$(', () => {
    const r = runCli('$(git push)');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'wrapper_form_$(');
});

test('G2: (git push) → reject wrapper_form_subshell', () => {
    const r = runCli('(git push)');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'wrapper_form_subshell');
});

test('G3: cat <<EOF\\nfoo\\nEOF → reject wrapper_form_redirect_<', () => {
    const r = runCli('cat <<EOF\nfoo\nEOF');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'wrapper_form_redirect_<');
});

test('G4: cat <<<"foo" → reject wrapper_form_redirect_< (here-string)', () => {
    const r = runCli('cat <<<"foo"');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'wrapper_form_redirect_<');
});

test('G5: bash <(echo foo) → reject wrapper_form_redirect_< (process sub)', () => {
    const r = runCli('bash <(echo foo)');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'wrapper_form_redirect_<');
});

test('G6: cat < file → reject wrapper_form_redirect_< (single-char <)', () => {
    const r = runCli('cat < file');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'wrapper_form_redirect_<');
});

// ----- Group H: §10 meta-command basenames --------------------------------

test('H1: eval "git push" → reject meta_command_eval', () => {
    const r = runCli('eval "git push"');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_eval');
});

test('H2: bash -c "git push" → reject meta_command_bash', () => {
    const r = runCli('bash -c "git push"');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_bash');
});

test('H3: sh -c "git push" → reject meta_command_sh', () => {
    const r = runCli('sh -c "git push"');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_sh');
});

test('H4: env git push → reject meta_command_env', () => {
    const r = runCli('env git push');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_env');
});

test('H5: exec git push → reject meta_command_exec', () => {
    const r = runCli('exec git push');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_exec');
});

test('H6: time git log → reject meta_command_time', () => {
    const r = runCli('time git log');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_time');
});

test('H7: xargs git push → reject meta_command_xargs', () => {
    const r = runCli('xargs git push');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'meta_command_xargs');
});

// ----- Group I: §11 argv-level wrapper substring scan ---------------------

test('I1: git commit -m "$(date)" → reject argv_wrapper_substring', () => {
    const r = runCli('git commit -m "$(date)"');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'argv_wrapper_substring');
});

test('I2: git log --grep=`whoami` → reject argv_wrapper_substring (backtick)', () => {
    const r = runCli('git log --grep=`whoami`');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'argv_wrapper_substring');
});

test('I3: echo "hi <<MARK foo MARK" → reject argv_wrapper_substring (<< inside argv)', () => {
    const r = runCli('echo "hi <<MARK foo MARK"');
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'argv_wrapper_substring');
});

test("I4: printf '%b' $'\\x41' → reject argv_wrapper_substring (ANSI-C quoting)", () => {
    // $' substring inside argv triggers the scan.
    const r = runCli("printf '%b' \"$'\\x41'\"");
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'argv_wrapper_substring');
});

// ----- Group J: §12 CLI input ---------------------------------------------

test('J1: camelCase shape (toolInput.command) → accepted', () => {
    const r = runCli(null, {
        envelope: { version: 1, toolInput: { command: 'git status' } },
    });
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
});

test('J2: snake_case wins over camelCase when both present', () => {
    const r = runCli(null, {
        envelope: {
            version: 1,
            tool_input: { command: 'git status' },
            toolInput: { command: 'rm -rf /' },
        },
    });
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
    assert.notEqual(r.parsed.commands[0].basename, 'rm');
});

test('J3: env-var CLAUDE_HOOK_INPUT fallback when stdin is empty', () => {
    const envelope = JSON.stringify({
        version: 1,
        tool_input: { command: 'git status' },
    });
    const r = runCli(null, {
        stdinOverride: '',
        env: { CLAUDE_HOOK_INPUT: envelope, CLAUDE_PARSER_STDIN_TIMEOUT_MS: '50' },
    });
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
});

test('J4: tool_input.command missing → reject malformed_input', () => {
    const r = runCli(null, { envelope: { version: 1, tool_input: {} } });
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'malformed_input');
});

// ----- Group K: §13/14 schema + exit codes --------------------------------

test('K1: output is valid JSON with version=1 for ok path', () => {
    const r = runCli('git status');
    assert.equal(r.exitCode, 0);
    assert.equal(r.parsed.version, 1);
    assert.equal(r.parsed.verdict, 'ok');
    assert.ok(Array.isArray(r.parsed.commands));
    // reject_reason omitted on ok verdict.
    assert.equal(Object.prototype.hasOwnProperty.call(r.parsed, 'reject_reason'), false);
});

test('K2: output is valid JSON with version=1 for reject path', () => {
    const r = runCli('eval foo');
    assert.equal(r.exitCode, 0);
    assert.equal(r.parsed.version, 1);
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(typeof r.parsed.reject_reason, 'string');
});

test('K3: malformed JSON on stdin → reject malformed_input, exit 0', () => {
    const r = runCli(null, { stdinOverride: 'not json' });
    assert.equal(r.exitCode, 0);
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'malformed_input');
});

test('K4: JSON array as envelope → reject malformed_input', () => {
    const r = runCli(null, { stdinOverride: '[{"version":1}]' });
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'malformed_input');
});

// ----- Group L: schema versioning -----------------------------------------

test('L1: omitted version → treated as 1 (ok)', () => {
    const r = runCli(null, {
        envelope: { tool_input: { command: 'git status' } },
    });
    assert.equal(r.parsed.verdict, 'ok');
    assert.equal(r.parsed.commands[0].basename, 'git');
});

test('L2: explicit version: 2 → reject malformed_input', () => {
    const r = runCli(null, {
        envelope: { version: 2, tool_input: { command: 'git status' } },
    });
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'malformed_input');
});

test('L3: explicit version string "1" → reject malformed_input', () => {
    const r = runCli(null, {
        envelope: { version: '1', tool_input: { command: 'git status' } },
    });
    assert.equal(r.parsed.verdict, 'reject');
    assert.equal(r.parsed.reject_reason, 'malformed_input');
});
