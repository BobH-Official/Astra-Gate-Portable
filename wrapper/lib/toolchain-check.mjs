// Toolchain preflight for wrapper/build-portable.mjs.
//
// Upstream records the toolchain in three different places and moves them
// independently: the .NET SDK in `global.json`, pnpm in `package.json`
// (`packageManager`), and Node only in their release workflow. A tag that moved
// one of them (v0.14.3104 switched the SDK from 11.0.100-rc.3.26522.148 to the
// GA 11.0.100) fails deep inside a long build with
// "A compatible .NET SDK was not found" unless the caller looks first.
//
// This module is pure: it reads the checkout, asks the installed tools their
// versions and reports problems, so it can be unit-tested without a build.

import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

/** Read the pins from a checked-out upstream tree. */
export function readPins(upstreamDir, readFile = fs.readFileSync, exists = fs.existsSync) {
  const pins = {};
  const globalJsonPath = path.join(upstreamDir, 'global.json');
  if (exists(globalJsonPath)) {
    pins.dotnet = JSON.parse(readFile(globalJsonPath, 'utf8'))?.sdk?.version ?? undefined;
  }
  const packageJsonPath = path.join(upstreamDir, 'package.json');
  if (exists(packageJsonPath)) {
    const manager = JSON.parse(readFile(packageJsonPath, 'utf8'))?.packageManager;
    pins.pnpm = /^pnpm@([^+]+)/.exec(manager ?? '')?.[1];
  }
  return pins;
}

/**
 * Compare the checkout's pins with the installed tools.
 *
 * `exec` is injectable so tests do not need dotnet or pnpm on PATH. `dotnet` is
 * asked while its cwd is the checkout, so the CLI resolves global.json itself
 * (rollForward / allowPrerelease) instead of this module guessing.
 */
export function checkToolchain({ upstreamDir, tag, exec = execFileSync }) {
  const pins = readPins(upstreamDir);
  const problems = [];
  const warnings = [];
  let dotnet;
  let pnpm;

  if (pins.dotnet) {
    try {
      dotnet = String(
        exec('dotnet', ['--version'], {
          cwd: upstreamDir,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'pipe'],
        }),
      ).trim();
    } catch (error) {
      problems.push({
        kind: 'dotnet-missing',
        pinned: pins.dotnet,
        detail: String(error?.stderr ?? '')
          .trim()
          .split('\n')
          .slice(0, 4)
          .join(' '),
      });
    }
  }

  if (pins.pnpm) {
    try {
      pnpm = String(exec('pnpm', ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })).trim();
    } catch {
      problems.push({ kind: 'pnpm-missing', pinned: pins.pnpm });
    }
    if (pnpm && pnpm !== pins.pnpm) {
      const major = (value) => value.split('.')[0];
      const sameMajor = major(pnpm) === major(pins.pnpm);
      (sameMajor ? warnings : problems).push({
        kind: sameMajor ? 'pnpm-minor' : 'pnpm-major',
        pinned: pins.pnpm,
        actual: pnpm,
      });
    }
  }

  return { tag, pins, dotnet, pnpm, problems, warnings };
}

/** One-line explanation for a problem, for the build log. */
export function describeProblem(problem) {
  switch (problem.kind) {
    case 'dotnet-missing':
      return (
        `The tag needs .NET SDK ${problem.pinned} and dotnet cannot resolve it` +
        (problem.detail ? `: ${problem.detail}` : '.') +
        ` Install that SDK (bash wrapper/upstream-toolchain.sh --get dotnet ${problem.tag ?? 'v<tag>'}).`
      );
    case 'pnpm-missing':
      return `pnpm is not on PATH, but the tag pins pnpm ${problem.pinned} in package.json.`;
    case 'pnpm-major':
      return `pnpm ${problem.actual} is on PATH but the tag pins ${problem.pinned}; a different major cannot read the lockfile. Install pnpm ${problem.pinned}.`;
    default:
      return `Unexpected toolchain problem: ${JSON.stringify(problem)}`;
  }
}
