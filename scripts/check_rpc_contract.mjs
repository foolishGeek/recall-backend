#!/usr/bin/env node
// Recall · RPC contract check.
//
// Guards against the "node_heat_pct" bug class: the mobile app calling a
// Postgres RPC (by name + named params) that no longer exists in the final
// migration state (dropped/renamed) — which surfaces at runtime as
// "Could not find the function public.<name>(...) in the schema cache".
//
// It computes the FINAL set of functions after all migrations run in order
// (CREATE [OR REPLACE] adds/updates a signature; DROP FUNCTION removes it),
// then asserts every `supabase.rpc('name', params: {...})` call in the mobile
// app resolves to a function whose argument names are a superset of the
// provided named params.
//
// Usage:
//   node scripts/check_rpc_contract.mjs [--mobile <path>] [--migrations <path>]
// Defaults assume the workspace layout: recall-backend/ next to recall-mobile/.
//
// Exit code 0 = all mobile RPCs resolve; 1 = one or more mismatches.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const backendRoot = resolve(here, '..');

function argValue(flag, fallback) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const migrationsDir = resolve(
  argValue('--migrations', join(backendRoot, 'supabase', 'migrations')),
);
const mobileLibDir = resolve(
  argValue('--mobile', join(backendRoot, '..', 'recall-mobile', 'lib')),
);

// ── helpers ────────────────────────────────────────────────────────────────

function walk(dir, matcher) {
  const out = [];
  const stack = [dir];
  while (stack.length) {
    const d = stack.pop();
    let entries;
    try {
      entries = readdirSync(d, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const full = join(d, e.name);
      if (e.isDirectory()) stack.push(full);
      else if (matcher(e.name)) out.push(full);
    }
  }
  return out;
}

// Read a balanced (...) or {...} block starting at the opening bracket index.
// Returns { body, end } where body excludes the outer brackets. Skips brackets
// inside single-quoted string / dollar-quoted bodies well enough for our inputs.
function readBalanced(str, openIdx, open, close) {
  let depth = 0;
  for (let i = openIdx; i < str.length; i++) {
    const ch = str[i];
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return { body: str.slice(openIdx + 1, i), end: i };
    }
  }
  return { body: str.slice(openIdx + 1), end: str.length };
}

// Split a SQL argument list on top-level commas (ignores commas inside ()/[]).
function splitTopLevel(argstr) {
  const parts = [];
  let depth = 0;
  let cur = '';
  for (const ch of argstr) {
    if (ch === '(' || ch === '[') depth++;
    else if (ch === ')' || ch === ']') depth--;
    if (ch === ',' && depth === 0) {
      parts.push(cur);
      cur = '';
    } else cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  return parts;
}

const ARG_MODES = new Set(['IN', 'OUT', 'INOUT', 'VARIADIC']);

// From a Postgres arg list, return the ordered list of argument NAMES.
function argNames(argstr) {
  if (!argstr.trim()) return [];
  return splitTopLevel(argstr)
    .map((seg) => {
      const tokens = seg.trim().split(/\s+/);
      let i = 0;
      if (tokens[i] && ARG_MODES.has(tokens[i].toUpperCase())) i++;
      const name = tokens[i];
      return name ? name.toLowerCase() : null;
    })
    .filter(Boolean);
}

// ── 1. Build the final function surface from migrations (in order) ──────────

// name -> array of signatures ({ args:Set<string>, file }). Overloads coexist.
const functions = new Map();

function addFn(name, args, file) {
  const key = name.toLowerCase();
  if (!functions.has(key)) functions.set(key, []);
  const sig = { args: new Set(args), argList: args, file };
  // CREATE OR REPLACE with same arity replaces; otherwise it's an overload.
  const list = functions.get(key);
  const idx = list.findIndex((s) => s.args.size === sig.args.size);
  if (idx >= 0) list[idx] = sig;
  else list.push(sig);
}

function dropFn(name, argTypesGiven) {
  const key = name.toLowerCase();
  if (!functions.has(key)) return;
  if (!argTypesGiven) {
    functions.delete(key); // DROP with no signature → remove all overloads
  } else {
    // DROP FUNCTION name(t1, t2, ...) → remove the overload with that arity.
    const arity = splitTopLevel(argTypesGiven).filter((s) => s.trim()).length;
    const list = functions.get(key).filter((s) => s.args.size !== arity);
    if (list.length) functions.set(key, list);
    else functions.delete(key);
  }
}

const migrationFiles = walk(migrationsDir, (n) => n.endsWith('.sql')).sort();

const createRe = /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?"?([a-zA-Z0-9_]+)"?\s*\(/gi;
const dropRe = /DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?(?:public\.)?"?([a-zA-Z0-9_]+)"?\s*(\()?/gi;

for (const file of migrationFiles) {
  const sql = readFileSync(file, 'utf8');
  const rel = file.replace(migrationsDir + '/', '');

  // Interleave CREATE and DROP in source order so final state is correct.
  const events = [];
  let m;
  createRe.lastIndex = 0;
  while ((m = createRe.exec(sql))) {
    const openIdx = m.index + m[0].length - 1;
    const { body } = readBalanced(sql, openIdx, '(', ')');
    events.push({ pos: m.index, kind: 'create', name: m[1], args: argNames(body) });
  }
  dropRe.lastIndex = 0;
  while ((m = dropRe.exec(sql))) {
    let argTypes = null;
    if (m[2] === '(') {
      const openIdx = m.index + m[0].length - 1;
      argTypes = readBalanced(sql, openIdx, '(', ')').body;
    }
    events.push({ pos: m.index, kind: 'drop', name: m[1], argTypes });
  }
  events.sort((a, b) => a.pos - b.pos);
  for (const ev of events) {
    if (ev.kind === 'create') addFn(ev.name, ev.args, rel);
    else dropFn(ev.name, ev.argTypes);
  }
}

// ── 2. Collect mobile RPC calls ─────────────────────────────────────────────

const rpcCallRe = /\.rpc\(\s*['"]([a-zA-Z0-9_]+)['"]/g;
const paramKeyRe = /['"]([a-zA-Z0-9_]+)['"]\s*:/g;

const mobileFiles = walk(mobileLibDir, (n) => n.endsWith('.dart'));
const calls = []; // { name, params:string[], file, line }

for (const file of mobileFiles) {
  const src = readFileSync(file, 'utf8');
  let m;
  rpcCallRe.lastIndex = 0;
  while ((m = rpcCallRe.exec(src))) {
    const name = m[1];
    // Read the whole .rpc(...) argument list to find a params: {...} block.
    const openIdx = src.indexOf('(', m.index);
    const { body } = readBalanced(src, openIdx, '(', ')');
    const params = [];
    const pIdx = body.search(/params\s*:/);
    if (pIdx >= 0) {
      const braceIdx = body.indexOf('{', pIdx);
      if (braceIdx >= 0) {
        const { body: pbody } = readBalanced(body, braceIdx, '{', '}');
        // Only top-level keys (ignore keys inside a nested value map).
        let depth = 0;
        let k;
        paramKeyRe.lastIndex = 0;
        // Recompute with a tiny scanner to respect nesting.
        const keys = topLevelMapKeys(pbody);
        for (k of keys) params.push(k.toLowerCase());
      }
    }
    const line = src.slice(0, m.index).split('\n').length;
    calls.push({ name, params, file: file.replace(mobileLibDir + '/', ''), line });
  }
}

function topLevelMapKeys(mapBody) {
  const keys = [];
  let depth = 0;
  let i = 0;
  while (i < mapBody.length) {
    const ch = mapBody[i];
    if (ch === '{' || ch === '(' || ch === '[') depth++;
    else if (ch === '}' || ch === ')' || ch === ']') depth--;
    else if ((ch === "'" || ch === '"') && depth === 0) {
      // Potential key: read the string, then check for a following ':'.
      const quote = ch;
      let j = i + 1;
      let s = '';
      while (j < mapBody.length && mapBody[j] !== quote) s += mapBody[j++];
      let k = j + 1;
      while (k < mapBody.length && /\s/.test(mapBody[k])) k++;
      if (mapBody[k] === ':') keys.push(s);
      i = j + 1;
      continue;
    }
    i++;
  }
  return keys;
}

// ── 3. Validate ─────────────────────────────────────────────────────────────

const problems = [];
for (const call of calls) {
  const sigs = functions.get(call.name.toLowerCase());
  if (!sigs || sigs.length === 0) {
    problems.push(
      `MISSING FUNCTION: ${call.name}() — called at ${call.file}:${call.line} but no final migration defines it`,
    );
    continue;
  }
  if (call.params.length === 0) continue; // name exists, no named params to check
  const ok = sigs.some((s) => call.params.every((p) => s.args.has(p)));
  if (!ok) {
    const known = sigs.map((s) => `(${s.argList.join(', ')})`).join(' | ');
    problems.push(
      `PARAM MISMATCH: ${call.name}({${call.params.join(', ')}}) — called at ${call.file}:${call.line}; known signatures: ${known}`,
    );
  }
}

const uniqueRpcNames = new Set(calls.map((c) => c.name));
console.log(
  `RPC contract check · ${migrationFiles.length} migrations · ` +
    `${functions.size} final functions · ${calls.length} mobile calls ` +
    `(${uniqueRpcNames.size} distinct)`,
);

if (problems.length) {
  console.error(`\n✗ ${problems.length} contract violation(s):\n`);
  for (const p of problems) console.error('  - ' + p);
  console.error(
    '\nFix: restore/rename the function in a migration, update the mobile call, ' +
      'or ensure migrations are applied in order.',
  );
  process.exit(1);
}

console.log('✓ every mobile RPC resolves to a final function with matching params');
