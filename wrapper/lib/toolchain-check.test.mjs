// Unit tests for wrapper/lib/toolchain-check.mjs.
// Run with: node wrapper/lib/toolchain-check.test.mjs  (or directly)
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { checkToolchain, createExec, describeProblem, readPins } from './toolchain-check.mjs';

let failures = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`ok   ${name}`);
  } catch (error) {
    console.error(`FAIL ${name}\n     ${error.message}`);
    failures += 1;
  }
}

function upstream({ dotnet, packageManager, releaseNodeVersion }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'astra-toolchain-'));
  if (dotnet !== undefined) {
    fs.writeFileSync(path.join(dir, 'global.json'), JSON.stringify({ sdk: { version: dotnet } }, null, 2));
  }
  if (packageManager !== undefined) {
    fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ packageManager }, null, 2));
  }
  if (releaseNodeVersion !== undefined) {
    const wf = path.join(dir, '.github', 'workflows');
    fs.mkdirSync(wf, { recursive: true });
    fs.writeFileSync(path.join(wf, 'release.yml'), `jobs:\n  build:\n    steps:\n      - uses: actions/setup-node@v4\n        with:\n          node-version: ${releaseNodeVersion}\n`);
  }
  return dir;
}

// Fake `exec` that answers from a table and records the cwd it was called with.
function fakeExec(table) {
  const calls = [];
  const exec = (file, args, options = {}) => {
    calls.push({ file, args, cwd: options.cwd });
    const answer = table[file];
    if (answer instanceof Error) throw answer;
    if (answer === undefined) throw new Error(`ENOENT: ${file}`);
    return `${answer}\n`;
  };
  exec.calls = calls;
  return exec;
}

test('reads both pins from the checkout', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  assert.deepEqual(readPins(dir), { dotnet: '11.0.100', pnpm: '9.15.0' });
});

test('strips the pnpm integrity suffix', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0+sha512.deadbeef' });
  assert.equal(readPins(dir).pnpm, '9.15.0');
});

test('missing files yield no pins instead of throwing', () => {
  const dir = upstream({});
  assert.deepEqual(readPins(dir), {});
});

test('a GA toolchain passes silently', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  const result = checkToolchain({
    upstreamDir: dir,
    tag: 'v0.14.3104',
    exec: fakeExec({ dotnet: '11.0.100', pnpm: '9.15.0' }),
  });
  assert.deepEqual(result.problems, []);
  assert.deepEqual(result.warnings, []);
  assert.equal(result.dotnet, '11.0.100');
  assert.equal(result.pnpm, '9.15.0');
});

test('an RC pin passes when the RC SDK is installed', () => {
  const dir = upstream({ dotnet: '11.0.100-rc.3.26522.148', packageManager: 'pnpm@9.15.0' });
  const result = checkToolchain({
    upstreamDir: dir,
    tag: 'v0.14.3103',
    exec: fakeExec({ dotnet: '11.0.100-rc.3.26522.148', pnpm: '9.15.0' }),
  });
  assert.deepEqual(result.problems, []);
});

test('dotnet is asked with the checkout as cwd so global.json applies', () => {
  const dir = upstream({ dotnet: '11.0.100' });
  const exec = fakeExec({ dotnet: '11.0.100', pnpm: '9.15.0' });
  checkToolchain({ upstreamDir: dir, tag: 'v0.14.3104', exec });
  const dotnetCall = exec.calls.find((call) => call.file === 'dotnet');
  assert.equal(dotnetCall.cwd, dir);
});

test('an unresolvable SDK is a problem naming the pinned version', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  const error = new Error('dotnet --version failed');
  error.stderr = 'A compatible .NET SDK was not found.\nRequested: 11.0.100';
  const result = checkToolchain({
    upstreamDir: dir,
    tag: 'v0.14.3104',
    exec: fakeExec({ dotnet: error, pnpm: '9.15.0' }),
  });
  assert.equal(result.problems.length, 1);
  assert.equal(result.problems[0].kind, 'dotnet-missing');
  assert.equal(result.problems[0].pinned, '11.0.100');
  const message = describeProblem({ ...result.problems[0], tag: 'v0.14.3104' });
  assert.match(message, /11\.0\.100/);
  assert.match(message, /v0\.14\.3104/);
  assert.match(message, /A compatible .NET SDK was not found/);
});

test('a pnpm major mismatch is a problem', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  const result = checkToolchain({
    upstreamDir: dir,
    tag: 'v0.14.3104',
    exec: fakeExec({ dotnet: '11.0.100', pnpm: '10.2.0' }),
  });
  assert.equal(result.problems.length, 1);
  assert.equal(result.problems[0].kind, 'pnpm-major');
  assert.match(describeProblem(result.problems[0]), /does not|cannot read the lockfile/);
});

test('a pnpm minor mismatch is only a warning', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  const result = checkToolchain({
    upstreamDir: dir,
    tag: 'v0.14.3104',
    exec: fakeExec({ dotnet: '11.0.100', pnpm: '9.16.1' }),
  });
  assert.deepEqual(result.problems, []);
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].kind, 'pnpm-minor');
});

test('a missing pnpm is a problem', () => {
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  const result = checkToolchain({
    upstreamDir: dir,
    tag: 'v0.14.3104',
    exec: fakeExec({ dotnet: '11.0.100' }),
  });
  assert.equal(result.problems[0].kind, 'pnpm-missing');
  assert.match(describeProblem(result.problems[0]), /not on PATH/);
});

test('on Windows the probe runs the .cmd shim through the shell', () => {
  const calls = [];
  const exec = createExec({
    platform: 'win32',
    execFile: (file, options) => {
      calls.push({ file, options });
      return file.startsWith('dotnet') ? '11.0.100\n' : '9.15.0\n';
    },
  });
  const dir = upstream({ dotnet: '11.0.100', packageManager: 'pnpm@9.15.0' });
  const result = checkToolchain({ upstreamDir: dir, tag: 'v0.14.3106', exec });
  assert.deepEqual(result.problems, []);
  assert.equal(result.pnpm, '9.15.0');
  const pnpmCall = calls.find((call) => call.file.startsWith('pnpm'));
  // `pnpm` alone never resolves: CreateProcess only appends `.exe`.
  assert.equal(pnpmCall.file, 'pnpm --version');
  assert.equal(pnpmCall.options.shell, true);
});

test('off Windows the probe keeps the argv form', () => {
  const calls = [];
  const exec = createExec({
    platform: 'linux',
    execFile: (file, args, options) => {
      calls.push({ file, args, options });
      return '9.15.0\n';
    },
  });
  const dir = upstream({ packageManager: 'pnpm@9.15.0' });
  checkToolchain({ upstreamDir: dir, tag: 'v0.14.3106', exec });
  assert.deepEqual(calls[0].args, ['--version']);
  assert.equal(calls[0].options.shell, undefined);
});

test('a tag without pins is not checked', () => {
  const dir = upstream({});
  const exec = fakeExec({ dotnet: '11.0.100', pnpm: '9.15.0' });
  const result = checkToolchain({ upstreamDir: dir, tag: 'v0.14.3104', exec });
  assert.deepEqual(result.problems, []);
  assert.equal(exec.calls.length, 0);
});

console.log(failures === 0 ? '\nall toolchain-check tests passed' : `\n${failures} test(s) failed`);
process.exit(failures === 0 ? 0 : 1);
