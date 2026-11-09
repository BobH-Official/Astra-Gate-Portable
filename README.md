# Astra Gate Portable (unofficial)

Unofficial, unpack-and-run Windows builds of
[Astra Gate](https://github.com/239573049/Astra-Gate), maintained by BobH.

This repository is a packaging wrapper, not a fork of the upstream source. It contains
no Astra Gate source code. At build time it shallow-clones an upstream release tag,
overlays the packaging script and optional patches, builds the Windows desktop app with
its bundled server, and publishes a portable ZIP.

> Not affiliated with the Astra Gate project. Report portable-build problems here; report
> product bugs upstream.

## What the ZIP contains

- `Astra.exe` — the Avalonia desktop app, Native AOT.
- `resources/server/` — `astra-server.exe`, its native companions, and the web console.
- No installer, no admin rights, no Node.js and no .NET runtime required.

Unpack the ZIP anywhere and run `Astra.exe`. The application still uses upstream's data
directory (`%USERPROFILE%\.astra`) by default. Set `ASTRA_HOME` before launching to keep
data beside the unpacked files; this is an upstream-supported environment variable.

The binaries are not code-signed, so Windows SmartScreen may warn. Verify the attached
SHA-256 before running.

## Repository layout

Only `scripts/package-portable.mjs` mirrors an upstream path exactly. The `scripts/`
directory can therefore be copied or merged into an upstream checkout without path
translation. Everything under `wrapper/` is intentionally outside upstream's tree.

| Path | Purpose | Upstream PR? |
| --- | --- | --- |
| `scripts/package-portable.mjs` | Builds the portable ZIP from an upstream checkout. Self-contained and intended to be PR-able. | Yes |
| `wrapper/build-portable.mjs` | Wrapper-only orchestrator: resolves the tag, clones upstream, overlays scripts/patches, builds, packages. | No |
| `wrapper/latest-upstream-tag.mjs` | Reads the latest stable upstream release tag from the GitHub API. | No |
| `.mise.toml` | Tool versions and local tasks. | No |
| `.github/workflows/portable-ci.yml` | Builds on pull requests and pushes to `master`; no release. | No |
| `.github/workflows/portable-release.yml` | Scheduled/manual upstream check, build and GitHub release. | No |
| `UPSTREAM` | One line: `owner/repo` of the upstream project. | No |
| `patches/` | Optional source patches. Not created until a patch is actually needed. | No |
| `README.md`, `AGENTS.md` | Documentation. | No |

## How a build works

1. Resolve the upstream release tag: an explicit `--tag`, or the latest stable release
   from the GitHub API.
2. Shallow-clone `https://github.com/<UPSTREAM>` at that tag into `.upstream/`
   (gitignored).
3. Check that the tag matches `cli/package.json` and that upstream still has the
   packaging helpers this wrapper depends on.
4. Copy `scripts/package-portable.mjs` into the checkout.
5. Apply `patches/*.patch` in filename order, if any exist.
6. Run the same build steps as the upstream release: pnpm install, web build, Native AOT
   publish of the server, Native AOT build/publish of the desktop app, then the server
   plugin self-test and the desktop `--smoke` test.
7. Run `scripts/package-portable.mjs`: stage `Astra.exe` plus the packed server, create
   the ZIP, write its SHA-256, extract the ZIP and verify the extracted layout and file
   sizes.
8. Write `build-info.json` with the upstream tag, RID, checksum, size and workflow run.

Outputs land in `out/portable/<rid>/`:

```
Astra-<version>-win32-<arch>-portable.zip
Astra-<version>-win32-<arch>-portable.zip.sha256
build-info.json
```

## Local build

Requirements:

- Windows 10/11, x64 or arm64.
- Git, PowerShell 5+.
- Node.js 24, pnpm 9.15.0.
- .NET SDK `11.0.100-rc.3.26522.148` (the version upstream pins in `global.json`).

With mise (`mise install` installs Node.js and pnpm; install the .NET SDK separately):

```powershell
mise install
mise run portable -- --tag v0.14.3100
# latest stable
mise run portable
```

Without mise:

```powershell
node wrapper/build-portable.mjs --tag v0.14.3100 --rid win-x64
node wrapper/build-portable.mjs --tag v0.14.3100 --rid win-arm64
```

Useful checks:

```powershell
# Clone, overlay, validate and stop before the heavy build.
node wrapper/build-portable.mjs --tag v0.14.3100 --prepare-only

# Print the latest stable upstream tag.
node wrapper/latest-upstream-tag.mjs

# Validate the mise configuration and script syntax.
mise tasks validate
node --check wrapper/build-portable.mjs
node --check wrapper/latest-upstream-tag.mjs
node --check scripts/package-portable.mjs
```

`--prepare-only` is safe on non-Windows hosts. The full build requires Windows because
the Windows Native AOT publish and the ZIP step use Windows tooling.

## Continuous integration and automatic releases

`Portable CI` runs on pull requests and pushes to `master` that touch wrapper files. It
builds the latest stable upstream and uploads the ZIP as a workflow artifact. It does not
create a release.

`Portable release` runs:

- every 6 hours on a schedule, and
- manually via `workflow_dispatch`, with optional `tag`, `rid` and `force` inputs.

The scheduled run resolves the latest stable upstream tag, checks whether this repository
already has a release with tag `portable-<upstream tag>`, and only builds when it does not.
A manual run can force a rebuild. Release tags are:

```
portable-<upstream tag>    # e.g. portable-v0.14.3100
```

and contain the ZIP, its `.sha256` file and `build-info.json`. Preview versions are marked
as prereleases. The scheduled build covers `win-x64`; `win-arm64` is available through
manual dispatch and requires access to the `windows-11-arm` runner.

### Scoop and checksum verification

Every release uploads `Astra-<version>-win32-<arch>-portable.zip.sha256` in the standard
`<sha256>  <filename>` format. The release workflow verifies the checksum with
`sha256sum -c` before publishing and repeats the hash in the release notes. A Scoop
manifest can point its autoupdate hash at that asset:

```json
"hash": {
  "url": "$url.sha256"
}
```

This works because the release asset is exactly `<zip>.sha256`. Adjust the manifest URL
for `arm64` if needed.

### Why polling instead of `on: release`

A GitHub Actions `release` event only fires in the repository where the release is
published. A wrapper repository (or a fork) cannot subscribe to another repository's
release events. The practical options are:

1. **Scheduled polling** (implemented): no upstream cooperation, at most ~6 hours of
   delay, and GitHub may delay scheduled runs at peak times.
2. **`repository_dispatch` from upstream**: requires the upstream maintainers to add a
   token and a dispatch step to their release workflow. This is the lowest-latency option
   if they agree.
3. **A webhook/GitHub App or RSS bridge**: an extra service to host and maintain.

The schedule only runs on the repository's default branch. Push `master` and set it as the
default branch before relying on automatic releases.

## Keeping the PR-able part separate

GitHub has no configuration file that marks part of a repository as "PR-only". A pull
request contains the commits on a branch in a fork; `CODEOWNERS`, path filters and
required checks affect review and CI, but they do not restrict what a PR changes.

The separation therefore has to be structural:

- This wrapper repository contains all wrapper-only files: workflows, mise tasks, the
  orchestrator and documentation.
- For an upstream PR, fork Astra Gate, branch from upstream `main`, copy in **only**
  `scripts/package-portable.mjs`, commit that one file, and open the PR.
- Keep the fork's default branch identical to upstream. Never put wrapper workflows or
  mise configuration on it.
- Keep PR-able changes and wrapper-only changes in separate commits even in this
  repository. If a commit mixes them, split it before exporting the PR branch.

Before opening the PR, open an issue to ask whether a portable ZIP is welcome and where
the script should live. The script is deliberately self-contained and uses upstream's
existing `scripts/rid-map.mjs` and `scripts/pack-platform.mjs`; it does not require the
wrapper repository.

## Patches

Do not create `patches/` preemptively. If a source change is needed:

1. Add `patches/NNNN-short-description.patch`.
2. The orchestrator applies patches in filename order after copying the packaging script.
3. Each patch is checked with `git apply --check` first; a patch that no longer applies
   fails the build.

Patches are not rebased automatically. A failed scheduled build is the signal that a
patch needs maintenance. This is intentional: silently auto-merging source patches is
riskier than failing loudly.

## Repository setup checklist

1. Create the GitHub repository and push the `master` bookmark.
2. Set `master` as the default branch.
3. Enable Actions.
4. If the repository policy restricts the default token, allow read/write workflow
   permissions, or rely on the job-level `contents: write` in the release workflow.
5. Run `Portable release` manually once to verify the full path.
6. Optionally open an upstream issue about accepting `scripts/package-portable.mjs`.

## Limitations

- Windows only; there are no macOS or Linux portable builds here.
- No installer integration, auto-update integration or code signing.
- Data is not relocated automatically: use `ASTRA_HOME` if you want a self-contained
  directory.
- Only stable upstream releases are discovered automatically; previews need a manual
  tag.
- GitHub may disable a scheduled workflow after 60 days without repository activity;
  re-enable it from the Actions tab if the schedule stops.
- The build is heavy (roughly 30–60 minutes) because it builds two Native AOT binaries.
