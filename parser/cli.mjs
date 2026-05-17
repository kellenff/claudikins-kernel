#!/usr/bin/env node
// parser/cli.mjs
// Static lexical analyser for bash command strings. See parser/GRAMMAR.md
// for the behavioural specification. This file implements that spec.

import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const shellQuote = require('./node_modules/shell-quote/index.js');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const META_COMMANDS = new Set([
  'eval', 'source', '.', 'exec', 'command', 'builtin',
  'bash', 'sh', 'zsh', 'dash', 'ksh',
  'env', 'xargs', 'nohup', 'setsid', 'time', 'watch', 'coproc',
  'parallel',
]);

// §10.5 Shell-keyword block list — compound-statement introducers. These are
// not commands; they introduce control-flow blocks. Their presence in
// command position means the input contains a compound statement, which the
// gate must refuse since policy is per-command, not per-block.
const SHELL_KEYWORDS = new Set([
  'for', 'while', 'until', 'if', 'case', 'function', 'select',
  'do', 'done', 'then', 'else', 'elif', 'fi', 'esac', 'in',
]);

const ARGV_WRAPPER_SUBSTRINGS = ['$(', '`', '<<', '<(', "$'", '\\$\\('];

const SEPARATOR_OPS = new Set(['&&', '||', ';', '|', '&', ')']);

const ENV_PREFIX_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

const DEFAULT_STDIN_TIMEOUT_MS = 500;
const STDIN_MAX_BYTES = 1024 * 1024;  // 1 MiB cap; oversize input → malformed_input

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function emitOk(commands) {
  emit({ version: 1, verdict: 'ok', commands });
  process.exit(0);
}

function emitReject(reason, commands = []) {
  emit({ version: 1, verdict: 'reject', commands, reject_reason: reason });
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Token predicates
// ---------------------------------------------------------------------------

function isString(tok) {
  return typeof tok === 'string';
}

function isOpToken(tok) {
  return tok !== null && typeof tok === 'object' && typeof tok.op === 'string';
}

function isCommentToken(tok) {
  return tok !== null && typeof tok === 'object' && typeof tok.comment === 'string';
}

function isGlobToken(tok) {
  // shell-quote emits {op:"glob", pattern:"..."}.
  // GRAMMAR.md describes it as {glob:{pattern}}. Handle both shapes.
  if (tok === null || typeof tok !== 'object') return false;
  if (tok.op === 'glob' && typeof tok.pattern === 'string') return true;
  if (tok.glob && typeof tok.glob.pattern === 'string') return true;
  return false;
}

function globPattern(tok) {
  if (tok.op === 'glob') return tok.pattern;
  return tok.glob.pattern;
}

// ---------------------------------------------------------------------------
// Env-prefix strip (§5) + basename (§6)
// ---------------------------------------------------------------------------

function stripEnvPrefix(argv) {
  let i = 0;
  while (i < argv.length && ENV_PREFIX_RE.test(argv[i])) i++;
  return argv.slice(i);
}

function basenameOf(token) {
  return path.basename(token);
}

// ---------------------------------------------------------------------------
// Walker (§4)
// ---------------------------------------------------------------------------

function splitOnNewline(str) {
  // Split on literal '\n', preserving empty segments.
  return str.split('\n');
}

// Walk tokens, return { commands, reject }
function walk(tokens) {
  const commands = [];
  let argv = [];
  let prev = null;

  function finalise() {
    if (argv.length === 0) return;
    const stripped = stripEnvPrefix(argv);
    if (stripped.length === 0) {
      argv = [];
      return;
    }
    const first = stripped[0];
    const basename = basenameOf(first);
    commands.push({ basename, argv: stripped, _firstTokenRaw: first });
    argv = [];
  }

  for (const tok of tokens) {
    if (isCommentToken(tok)) {
      // §3: strip; warn if comment string contains \n followed by non-whitespace.
      if (/\n\S/.test(tok.comment)) {
        process.stderr.write(
          'warning: comment token contains embedded newline + non-whitespace content\n'
        );
      }
      continue;
    }

    if (isOpToken(tok)) {
      const op = tok.op;

      // Separator ops finalise current argv.
      if (SEPARATOR_OPS.has(op)) {
        finalise();
        prev = tok;
        continue;
      }

      // §9: open paren — subshell or command substitution.
      if (op === '(') {
        if (prev === '$') {
          return { reject: 'wrapper_form_$(', commands };
        }
        return { reject: 'wrapper_form_subshell', commands };
      }

      // §9: any op starting with '<' rejects.
      if (op.startsWith('<')) {
        return { reject: 'wrapper_form_redirect_<', commands };
      }

      // Glob op marker (shell-quote shape): treat as argv token.
      if (op === 'glob' && typeof tok.pattern === 'string') {
        argv.push(tok.pattern);
        prev = tok;
        continue;
      }

      // All other ops (>, >>, >&) allowed; advance prev.
      prev = tok;
      continue;
    }

    if (isGlobToken(tok)) {
      argv.push(globPattern(tok));
      prev = tok;
      continue;
    }

    if (isString(tok)) {
      const segments = splitOnNewline(tok);
      if (segments.length === 1) {
        argv.push(tok);
      } else {
        for (let i = 0; i < segments.length; i++) {
          const seg = segments[i];
          if (seg === '') {
            // Empty segment = newline boundary: finalise current argv.
            finalise();
          } else {
            argv.push(seg);
          }
        }
      }
      prev = tok;
      continue;
    }

    // Unknown token shape: advance prev defensively.
    prev = tok;
  }

  finalise();
  return { commands, reject: null };
}

// ---------------------------------------------------------------------------
// Argv-level substring scan (§11)
// ---------------------------------------------------------------------------

function scanArgv(commands) {
  for (const cmd of commands) {
    for (const item of cmd.argv) {
      if (typeof item !== 'string') continue;
      for (const needle of ARGV_WRAPPER_SUBSTRINGS) {
        if (item.includes(needle)) {
          return 'argv_wrapper_substring';
        }
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Var-as-command rule (§7)
// ---------------------------------------------------------------------------

function checkVarAsCommand(commands) {
  for (const cmd of commands) {
    const first = cmd._firstTokenRaw;
    if (typeof first !== 'string' || first === '' || first.startsWith('$')) {
      return 'var_as_command';
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Shell-keyword basename block (§10.5)
// ---------------------------------------------------------------------------

function checkShellKeyword(commands) {
  for (const cmd of commands) {
    if (SHELL_KEYWORDS.has(cmd.basename)) {
      return 'shell_keyword_' + cmd.basename;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Meta-command basename block (§10)
// ---------------------------------------------------------------------------

function checkMetaCommand(commands) {
  for (const cmd of commands) {
    if (META_COMMANDS.has(cmd.basename)) {
      return 'meta_command_' + cmd.basename;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Strip internal fields before emitting
// ---------------------------------------------------------------------------

function cleanCommands(commands) {
  return commands.map(c => ({ basename: c.basename, argv: c.argv }));
}

// ---------------------------------------------------------------------------
// Input reading (§12)
// ---------------------------------------------------------------------------

function readStdinWithTimeout(timeoutMs) {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) {
      resolve('');
      return;
    }
    let data = '';
    let totalBytes = 0;
    let oversize = false;
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      process.stdin.removeAllListeners('data');
      process.stdin.removeAllListeners('end');
      process.stdin.removeAllListeners('error');
      resolve(v);
    };
    const timer = setTimeout(() => finish(data), timeoutMs);
    process.stdin.on('data', (chunk) => {
      if (oversize) return;
      totalBytes += chunk.length;
      if (totalBytes > STDIN_MAX_BYTES) {
        oversize = true;
        data = '<<oversize>>';  // sentinel guaranteed to fail JSON.parse
        clearTimeout(timer);
        try { process.stdin.destroy(); } catch { /* ignore */ }
        finish(data);
        return;
      }
      data += chunk.toString('utf8');
    });
    process.stdin.on('end', () => { clearTimeout(timer); finish(data); });
    process.stdin.on('error', () => { clearTimeout(timer); finish(data); });
  });
}

function parseTimeout() {
  const raw = process.env.CLAUDE_PARSER_STDIN_TIMEOUT_MS;
  if (raw == null || raw === '') return DEFAULT_STDIN_TIMEOUT_MS;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 0) return DEFAULT_STDIN_TIMEOUT_MS;
  return n;
}

async function readInput() {
  const timeout = parseTimeout();
  const stdinData = await readStdinWithTimeout(timeout);
  if (stdinData && stdinData.length > 0) return stdinData;
  const envData = process.env.CLAUDE_HOOK_INPUT;
  if (envData && envData.length > 0) return envData;
  // No input available — §14 exit 1.
  process.stderr.write('parser/cli.mjs: no input on stdin or CLAUDE_HOOK_INPUT\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Envelope parsing (§12)
// ---------------------------------------------------------------------------

function extractCommand(raw) {
  let envelope;
  try {
    envelope = JSON.parse(raw);
  } catch {
    return { reject: 'malformed_input' };
  }
  if (envelope === null || typeof envelope !== 'object' || Array.isArray(envelope)) {
    return { reject: 'malformed_input' };
  }
  if (Object.prototype.hasOwnProperty.call(envelope, 'version')) {
    if (envelope.version !== 1) {
      return { reject: 'malformed_input' };
    }
  }
  // snake wins over camel.
  let cmd;
  if (envelope.tool_input && typeof envelope.tool_input === 'object' &&
      typeof envelope.tool_input.command === 'string') {
    cmd = envelope.tool_input.command;
  } else if (envelope.toolInput && typeof envelope.toolInput === 'object' &&
             typeof envelope.toolInput.command === 'string') {
    cmd = envelope.toolInput.command;
  } else {
    return { reject: 'malformed_input' };
  }
  return { command: cmd };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const raw = await readInput();
  const env = extractCommand(raw);
  if (env.reject) {
    emitReject(env.reject, []);
    return;
  }

  let tokens;
  try {
    tokens = shellQuote.parse(env.command, (name) => '$' + name);
  } catch {
    // shell-quote throws on bad ${...} substitutions; treat as malformed input.
    emitReject('malformed_input', []);
    return;
  }

  const walked = walk(tokens);
  if (walked.reject) {
    emitReject(walked.reject, cleanCommands(walked.commands));
    return;
  }
  const commands = walked.commands;

  // §8 empty-commands.
  if (commands.length === 0) {
    emitReject('no_commands', []);
    return;
  }

  // §7 var-as-command.
  const varReject = checkVarAsCommand(commands);
  if (varReject) {
    emitReject(varReject, cleanCommands(commands));
    return;
  }

  // §10.5 shell-keyword basename block (must run before meta-command so
  // that compound-statement bodies surface as shell_keyword_<name>).
  const keywordReject = checkShellKeyword(commands);
  if (keywordReject) {
    emitReject(keywordReject, cleanCommands(commands));
    return;
  }

  // §10 meta-command basename block.
  const metaReject = checkMetaCommand(commands);
  if (metaReject) {
    emitReject(metaReject, cleanCommands(commands));
    return;
  }

  // §11 argv-level substring scan.
  const argvReject = scanArgv(commands);
  if (argvReject) {
    emitReject(argvReject, cleanCommands(commands));
    return;
  }

  emitOk(cleanCommands(commands));
}

// §14: exit 1 only on internal failure.
main().catch((e) => {
  process.stderr.write('parser/cli.mjs: internal error: ' + (e && e.stack || e) + '\n');
  process.exit(1);
});
