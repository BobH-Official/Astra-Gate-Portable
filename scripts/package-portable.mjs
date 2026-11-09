#!/usr/bin/env node
/**
 * Package the Windows Avalonia desktop app, including its bundled server, as a portable ZIP.
 *
 * This script is independent of the installer packaging. It consumes existing build outputs:
 *
 *   node scripts/package-portable.mjs --rid win-x64 \
 *     --desktop-publish out/portable-input/desktop \
 *     --server-publish out/portable-input/server \
 *     --web-dist web/dist [--version x.y.z] [--out out/portable/win-x64]
 *
 * desktop-publish: Native AOT publish of src/Astra.Desktop (contains astra-desktop.exe).
 * server-publish:  Native AOT publish of src/Astra.Server (contains astra-server.exe and its DLLs).
 * web-dist:        Vite output copied to resources/server/wwwroot beside the bundled server.
 */
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ridToServerDir } from './rid-map.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};
const fail = (message) => {
  throw new Error(message);
};
const resolve = (value) => path.resolve(root, value);

const rid = arg('rid');
const desktopPublish = arg('desktop-publish') && resolve(arg('desktop-publish'));
const serverPublish = arg('server-publish') && resolve(arg('server-publish'));
const webDist = arg('web-dist') && resolve(arg('web-dist'));
if (!rid || !desktopPublish || !serverPublish || !webDist) {
  fail('Usage: node scripts/package-portable.mjs --rid <win-x64|win-arm64> --desktop-publish <dir> --server-publish <dir> --web-dist <dir> [--version <ver>] [--out <dir>]');
}
if (!['win-x64', 'win-arm64'].includes(rid)) fail(`Unsupported RID "${rid}". Portable packaging currently supports win-x64 and win-arm64.`);

const version = arg('version') ?? JSON.parse(fs.readFileSync(path.join(root, 'cli', 'package.json'), 'utf8')).version;
if (!/^\d+\.\d+\.\d+(?:-preview\.[1-9]\d*)?$/.test(version)) fail(`Invalid release version "${version}".`);

for (const [label, dir] of [['desktop publish', desktopPublish], ['server publish', serverPublish], ['web dist', webDist]]) {
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) fail(`${label} directory not found: ${dir}`);
}
if (!fs.existsSync(path.join(desktopPublish, 'astra-desktop.exe'))) fail(`astra-desktop.exe not found in ${desktopPublish}`);
if (!fs.existsSync(path.join(serverPublish, 'astra-server.exe'))) fail(`astra-server.exe not found in ${serverPublish}`);
if (!fs.existsSync(path.join(webDist, 'index.html'))) fail(`index.html not found in ${webDist}`);

const arch = rid === 'win-arm64' ? 'arm64' : 'x64';
const outDir = arg('out') ? resolve(arg('out')) : path.join(root, 'out', 'portable', rid);
const stage = path.join(outDir, 'unpacked');
const verify = path.join(outDir, 'verify');
const baseName = `Astra-${version}-win32-${arch}-portable.zip`;
const zip = path.join(outDir, baseName);
const hashFile = zip + '.sha256';

fs.mkdirSync(outDir, { recursive: true });
fs.rmSync(stage, { recursive: true, force: true });
fs.rmSync(verify, { recursive: true, force: true });
fs.rmSync(zip, { force: true });
fs.rmSync(hashFile, { force: true });
fs.mkdirSync(stage, { recursive: true });

// Use the upstream server packer verbatim: binary, native companions and wwwroot all follow release.yml.
execFileSync(process.execPath, [
  path.join(root, 'scripts', 'pack-platform.mjs'),
  '--rid', rid,
  '--publish-dir', serverPublish,
  '--web-dist', webDist,
], { stdio: 'inherit' });
const packedServer = path.join(root, 'npm', ridToServerDir(rid), 'bin');

// Mirrors package-desktop.mjs's copyProgram/copyServer. That script cannot be called directly for a
// portable-only build because its Windows path always invokes NSIS after creating this same layout.
for (const entry of fs.readdirSync(desktopPublish, { withFileTypes: true })) {
  if (/\.(pdb|dbg|dSYM)$/i.test(entry.name)) continue;
  const target = entry.name === 'astra-desktop.exe' ? 'Astra.exe' : entry.name;
  fs.cpSync(path.join(desktopPublish, entry.name), path.join(stage, target), { recursive: true, verbatimSymlinks: true });
}
fs.chmodSync(path.join(stage, 'Astra.exe'), 0o755);
fs.cpSync(packedServer, path.join(stage, 'resources', 'server'), { recursive: true, verbatimSymlinks: true });

const license = path.join(root, 'LICENSE');
if (!fs.existsSync(license)) fail(`License file not found in the upstream checkout: ${license}`);
fs.copyFileSync(license, path.join(stage, 'LICENSE'));
const thirdPartyNotices = path.join(root, 'THIRD_PARTY_NOTICES.md');
if (fs.existsSync(thirdPartyNotices)) fs.copyFileSync(thirdPartyNotices, path.join(stage, 'THIRD_PARTY_NOTICES.md'));

function filesUnder(dir, base = dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...filesUnder(full, base));
    else if (entry.isFile()) files.push(path.relative(base, full).replaceAll(path.sep, '/'));
  }
  return files.sort();
}

function assertLayout(dir) {
  for (const relative of ['Astra.exe', 'LICENSE', 'resources/server/astra-server.exe', 'resources/server/wwwroot/index.html']) {
    if (!fs.existsSync(path.join(dir, ...relative.split('/')))) fail(`Packaged file is missing: ${relative}`);
  }
  if (!fs.existsSync(path.join(dir, 'resources', 'server', 'e_sqlite3.dll'))) {
    fail('Packaged file is missing: resources/server/e_sqlite3.dll');
  }
}
assertLayout(stage);

function powershell(script, env) {
  execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
    stdio: 'inherit',
    env: { ...process.env, ...env },
  });
}

powershell(
  'Add-Type -AssemblyName System.IO.Compression.FileSystem; ' +
    '[System.IO.Compression.ZipFile]::CreateFromDirectory($env:ASTRA_PORTABLE_STAGE, $env:ASTRA_PORTABLE_ZIP, ' +
    '[System.IO.Compression.CompressionLevel]::Optimal, $false)',
  { ASTRA_PORTABLE_STAGE: stage, ASTRA_PORTABLE_ZIP: zip },
);

const sha256 = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
fs.writeFileSync(hashFile, `${sha256}  ${baseName}\n`);

// Verify the actual archive rather than trusting the staging directory.
powershell(
  'Add-Type -AssemblyName System.IO.Compression.FileSystem; ' +
    '[System.IO.Compression.ZipFile]::ExtractToDirectory($env:ASTRA_PORTABLE_ZIP, $env:ASTRA_PORTABLE_VERIFY)',
  { ASTRA_PORTABLE_ZIP: zip, ASTRA_PORTABLE_VERIFY: verify },
);
assertLayout(verify);
const stagedFiles = filesUnder(stage);
const verifiedFiles = filesUnder(verify);
if (JSON.stringify(stagedFiles) !== JSON.stringify(verifiedFiles)) fail('The extracted ZIP file list differs from the staging directory.');
for (const relative of stagedFiles) {
  const stagedSize = fs.statSync(path.join(stage, ...relative.split('/'))).size;
  const verifiedSize = fs.statSync(path.join(verify, ...relative.split('/'))).size;
  if (stagedSize !== verifiedSize) fail(`Extracted file size differs: ${relative}`);
}

const mb = (bytes) => (bytes / 1024 / 1024).toFixed(1);
console.log(`Portable desktop ${version} (${rid}) packaged successfully:`);
console.log(`  ${path.relative(root, zip)} (${mb(fs.statSync(zip).size)} MB, ${stagedFiles.length} files)`);
console.log(`  ${path.relative(root, hashFile)}`);
console.log(`  SHA-256: ${sha256}`);
console.log(`  Verified extraction: ${path.relative(root, verify)}`);
