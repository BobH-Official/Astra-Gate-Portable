#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkToolchain, createExec, describeProblem } from './lib/toolchain-check.mjs';

const usage = `Usage: node wrapper/build-portable.mjs [options]

Options:
  --tag <tag>        Upstream Astra-Gate release tag (default: latest stable release)
  --rid <rid>        Windows RID: win-x64 or win-arm64 (default: win-x64)
  --out <dir>        Output directory (default: out)
  --upstream <dir>   Upstream checkout directory (default: .upstream)
  --prepare-only     Clone, overlay and validate, then stop before building
  -h, --help         Show this help

Environment:
  ASTRA_TAG          Same as --tag
  ASTRA_RID          Same as --rid
  GITHUB_TOKEN       Raises the GitHub API rate limit when resolving the latest tag

The upstream checkout is recreated from the release tag on every run. Wrapper-only
files stay in this repository; only scripts/package-portable.mjs and patches are
copied into the checkout.`;

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function fail(message) {
  console.error(`[build-portable] error: ${message}`);
  process.exit(1);
}

function arg(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return undefined;
  const value = process.argv[index + 1];
  if (value === undefined || value.startsWith('--')) fail(`--${name} requires a value.`);
  return value;
}

function flag(name) {
  return process.argv.includes(`--${name}`);
}

if (flag('help') || process.argv.includes('-h')) {
  console.log(usage);
  process.exit(0);
}

const upstreamSlug = fs.readFileSync(path.join(root, 'UPSTREAM'), 'utf8').trim();
if (!/^[\w.-]+\/[\w.-]+$/.test(upstreamSlug)) fail(`UPSTREAM must contain owner/repo, got: ${upstreamSlug}`);

const rid = arg('rid') ?? process.env.ASTRA_RID ?? 'win-x64';
if (!['win-x64', 'win-arm64'].includes(rid)) fail(`Unsupported --rid "${rid}". Expected win-x64 or win-arm64.`);

const outRoot = path.resolve(root, arg('out') ?? 'out');
const upstreamDir = path.resolve(root, arg('upstream') ?? '.upstream');
const upstreamConfig = path.join(root, 'UPSTREAM');
if (process.platform === 'win32' && upstreamDir.toLowerCase() === upstreamConfig.toLowerCase()) {
  fail('--upstream collides with the UPSTREAM file on a case-insensitive filesystem; use .upstream.');
}
const upstreamRelative = path.relative(root, upstreamDir);
if (upstreamRelative === '' || upstreamRelative.startsWith('..') || path.isAbsolute(upstreamRelative)) {
  fail('--upstream must be a directory inside the repository.');
}
const prepareOnly = flag('prepare-only');

async function latestTag() {
  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'astra-gate-portable-packaging',
  };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  const response = await fetch(`https://api.github.com/repos/${upstreamSlug}/releases/latest`, { headers });
  if (!response.ok) {
    const body = await response.text();
    fail(`GitHub API returned ${response.status} while resolving the latest upstream release: ${body.trim()}`);
  }
  const release = await response.json();
  if (!release.tag_name) fail('The latest upstream release has no tag_name.');
  return release.tag_name;
}

const inputTag = arg('tag') ?? process.env.ASTRA_TAG;
const tag = (inputTag ?? (await latestTag())).replace(/^v?/, 'v');
const version = tag.slice(1);
if (!/^\d+\.\d+\.\d+(?:-preview\.[1-9]\d*)?$/.test(version)) {
  fail(`Unsupported upstream tag "${tag}". Expected v<major>.<minor>.<patch> or v<major>.<minor>.<patch>-preview.<n>.`);
}

function run(file, args, options = {}) {
  console.log(`[build-portable] $ ${file} ${args.join(' ')}`);
  return execFileSync(file, args, { stdio: 'inherit', ...options });
}

async function retry(attempts, label, fn) {
  for (let attempt = 1; ; attempt++) {
    try {
      return fn();
    } catch (error) {
      if (attempt >= attempts) throw error;
      console.warn(`[build-portable] ${label} failed (attempt ${attempt}/${attempts}); retrying in ${attempt * 20}s`);
      await new Promise((resolve) => setTimeout(resolve, attempt * 20000));
    }
  }
}

// pnpm is a `.cmd` shim on Windows; createExec() knows how to start it (and
// keeps the probe in lib/toolchain-check.mjs on the same rules).
const runPnpm = createExec();

function pnpm(args) {
  console.log(`[build-portable] $ pnpm ${args.join(' ')}`);
  return runPnpm('pnpm', args, { cwd: upstreamDir, stdio: 'inherit' });
}

console.log(`[build-portable] upstream=${upstreamSlug} tag=${tag} version=${version} rid=${rid}`);

fs.rmSync(upstreamDir, { recursive: true, force: true });
fs.mkdirSync(path.dirname(upstreamDir), { recursive: true });
run('git', [
  '-c',
  'core.longpaths=true',
  '-c',
  'core.autocrlf=false',
  '-c',
  'advice.detachedHead=false',
  'clone',
  '--depth',
  '1',
  '--branch',
  tag,
  `https://github.com/${upstreamSlug}.git`,
  upstreamDir,
]);

const upstreamPackage = JSON.parse(fs.readFileSync(path.join(upstreamDir, 'cli', 'package.json'), 'utf8'));
if (upstreamPackage.version !== version) {
  fail(`Tag ${tag} resolves to cli/package.json version ${upstreamPackage.version}; refusing to package a mismatched release.`);
}

for (const required of ['scripts/rid-map.mjs', 'scripts/pack-platform.mjs']) {
  if (!fs.existsSync(path.join(upstreamDir, ...required.split('/')))) {
    fail(`The upstream tag ${tag} does not contain ${required}.`);
  }
}

// Preflight the local toolchain against what this tag asks for. Upstream moved
// the .NET pin from 11.0.100-rc.3.26522.148 to the GA 11.0.100 between
// v0.14.3103 and v0.14.3104, and pnpm comes from `packageManager`; a mismatch
// otherwise shows up as a confusing "A compatible .NET SDK was not found" in
// the middle of a long build. CI installs these versions from
// wrapper/upstream-toolchain.sh, so this mainly protects local builds.
const toolchain = checkToolchain({ upstreamDir, tag });
for (const problem of toolchain.problems) {
  fail(describeProblem({ ...problem, tag }));
}
for (const warning of toolchain.warnings) {
  console.warn(
    `[build-portable] warning: pnpm ${warning.actual} is on PATH but ${tag} pins ${warning.pinned}; continuing, the lockfile should still apply.`,
  );
}
if (toolchain.dotnet) {
  console.log(`[build-portable] dotnet ${toolchain.dotnet} (tag pins ${toolchain.pins.dotnet ?? 'nothing'})`);
}
if (toolchain.pnpm) {
  console.log(`[build-portable] pnpm ${toolchain.pnpm}`);
}

fs.copyFileSync(path.join(root, 'scripts', 'package-portable.mjs'), path.join(upstreamDir, 'scripts', 'package-portable.mjs'));
execFileSync(process.execPath, ['--check', path.join(upstreamDir, 'scripts', 'package-portable.mjs')], { stdio: 'inherit' });

const patchesDir = path.join(root, 'patches');
if (fs.existsSync(patchesDir)) {
  const patches = fs.readdirSync(patchesDir).filter((name) => /\.(patch|diff)$/i.test(name)).sort();
  for (const name of patches) {
    const patch = fs.readFileSync(path.join(patchesDir, name));
    console.log(`[build-portable] applying patches/${name}`);
    execFileSync('git', ['-C', upstreamDir, 'apply', '--check', '--whitespace=nowarn', '-'], {
      input: patch,
      stdio: ['pipe', 'inherit', 'inherit'],
    });
    execFileSync('git', ['-C', upstreamDir, 'apply', '--whitespace=nowarn', '-'], {
      input: patch,
      stdio: ['pipe', 'inherit', 'inherit'],
    });
  }
}

run(process.execPath, ['scripts/sync-versions.mjs', '--check'], { cwd: upstreamDir });

if (prepareOnly) {
  console.log(`[build-portable] prepared ${upstreamDir} for ${tag}; stopping before the build.`);
  process.exit(0);
}

if (process.platform !== 'win32') {
  fail('The Windows portable build must run on Windows. Use --prepare-only elsewhere.');
}

await retry(3, 'pnpm install', () => pnpm(['install', '--frozen-lockfile']));
pnpm(['--filter', '@aidotnet/web', 'build']);

run('dotnet', [
  'publish',
  'src/Astra.Server',
  '-c',
  'Release',
  '-r',
  rid,
  '--self-contained',
  'true',
  '-p:PublishAot=true',
  '-o',
  'out/publish',
], { cwd: upstreamDir });

run('dotnet', [
  'build',
  'src/Astra.Desktop',
  '-c',
  'Release',
  '-r',
  rid,
  '-p:PublishAot=true',
  '-warnaserror',
], { cwd: upstreamDir });

run('dotnet', [
  'publish',
  'src/Astra.Desktop',
  '-c',
  'Release',
  '-r',
  rid,
  '-p:PublishAot=true',
  '--no-build',
  '-o',
  'out/desktop-publish',
], { cwd: upstreamDir });

const canRunSmokeTests = rid === `win-${process.arch}`;
if (canRunSmokeTests) {
  run(path.join(upstreamDir, 'out', 'publish', 'astra-server.exe'), ['plugin-selftest'], { cwd: upstreamDir });
  run(path.join(upstreamDir, 'out', 'desktop-publish', 'astra-desktop.exe'), ['--smoke'], { cwd: upstreamDir });
} else {
  console.warn(`[build-portable] skipping smoke tests: ${rid} cannot run on a ${process.arch} host.`);
}

const portableOut = path.join(outRoot, 'portable', rid);
fs.rmSync(portableOut, { recursive: true, force: true });
fs.mkdirSync(portableOut, { recursive: true });

run(
  process.execPath,
  [
    path.join(upstreamDir, 'scripts', 'package-portable.mjs'),
    '--rid',
    rid,
    '--desktop-publish',
    path.join(upstreamDir, 'out', 'desktop-publish'),
    '--server-publish',
    path.join(upstreamDir, 'out', 'publish'),
    '--web-dist',
    path.join(upstreamDir, 'web', 'dist'),
    '--version',
    version,
    '--out',
    portableOut,
  ],
  { cwd: upstreamDir },
);

const arch = rid === 'win-arm64' ? 'arm64' : 'x64';
const zipName = `Astra-${version}-win32-${arch}-portable.zip`;
const zipPath = path.join(portableOut, zipName);
const hashPath = `${zipPath}.sha256`;
if (!fs.existsSync(zipPath)) fail(`The packaging script did not create ${zipPath}.`);
if (!fs.existsSync(hashPath)) fail(`The packaging script did not create ${hashPath}.`);

const sha256 = crypto.createHash('sha256').update(fs.readFileSync(zipPath)).digest('hex');
const recordedHash = fs.readFileSync(hashPath, 'utf8').trim().split(/\s+/)[0];
if (recordedHash !== sha256) fail(`SHA-256 mismatch: ${recordedHash} (recorded) vs ${sha256} (actual).`);

const buildInfo = {
  upstream: upstreamSlug,
  tag,
  version,
  rid,
  file: zipName,
  sha256,
  bytes: fs.statSync(zipPath).size,
  builtAt: new Date().toISOString(),
  wrapperCommit: process.env.GITHUB_SHA ?? null,
  workflowRun: process.env.GITHUB_RUN_ID ?? null,
  workflowAttempt: process.env.GITHUB_RUN_ATTEMPT ?? null,
};
fs.writeFileSync(path.join(portableOut, 'build-info.json'), `${JSON.stringify(buildInfo, null, 2)}\n`);

console.log(`[build-portable] portable ZIP: ${zipPath}`);
console.log(`[build-portable] SHA-256: ${sha256}`);
console.log(`[build-portable] build info: ${path.join(portableOut, 'build-info.json')}`);
