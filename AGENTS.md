# AGENTS.md

Guidance for coding agents working in this repository. Read `README.md` first.

## What this repository is

A packaging wrapper for unofficial Windows portable builds of Astra Gate. Upstream is
`239573049/Astra-Gate`, recorded in `UPSTREAM`. This repository contains no upstream
source code and is not a source fork. A build shallow-clones an upstream release tag,
overlays wrapper files and optional patches, builds the app, and publishes a ZIP.

## Hard rules

- Never vendor or edit upstream source here. `.upstream/` is a disposable clone and is
  gitignored.
- `scripts/package-portable.mjs` is the only file that can be copied 1:1 to upstream (the
  explicit list is in `README.md`). It must stay runnable from a clean upstream checkout
  and must not import wrapper-only files or depend on this repository's workflows or mise
  tasks.
- Only `scripts/package-portable.mjs` uses an upstream-relative path. Keep the `scripts/`
  directory 1:1 with upstream; put every wrapper-only script under `wrapper/`.
- Wrapper-only files: `wrapper/**`, `.github/workflows/**`, `.mise.toml`, `UPSTREAM`,
  `README.md`, `AGENTS.md`.
- Do not add `patches/` until a source patch is actually required.
- `LICENSE` is the wrapper's MIT license, using the same terms as upstream. Do not
  replace it with a different license. The packaging script copies the upstream
  `LICENSE` into the ZIP; keep that behavior.
- Do not mix PR-able and wrapper-only changes in one commit.
- Do not commit `.upstream/`, `out/`, build outputs, tokens or secrets.
- Do not add wrapper-only paths to the packaging script. If the packaging script needs a
  helper, it must already exist upstream or be part of the same PR.

## Layout

Only `scripts/package-portable.mjs` mirrors an upstream path exactly. Everything under
`wrapper/` is intentionally outside upstream's tree.

| Path | Purpose |
| --- | --- |
| `scripts/package-portable.mjs` | PR-able packaging script; runs inside an upstream checkout. |
| `wrapper/build-portable.mjs` | Wrapper-only orchestrator: tag resolution, clone, overlay, patches, build, package. |
| `wrapper/latest-upstream-tag.mjs` | Wrapper-only GitHub API helper. |
| `.mise.toml` | Tool versions and local tasks. |
| `.github/workflows/portable-ci.yml` | PR/push build validation; no release. |
| `.github/workflows/portable-release.yml` | Scheduled/manual build and GitHub release. |
| `UPSTREAM` | One line: upstream `owner/repo`. |
| `LICENSE` | MIT license for this wrapper; same terms as upstream. |
| `patches/` | Optional source patches, applied in filename order. |

## Build and validation

Requirements: Windows for a full build; Git, PowerShell, Node.js 24, pnpm 9.15.0,
.NET SDK `11.0.100-rc.3.26522.148`. `mise install` installs Node.js and pnpm; install the
.NET SDK separately (upstream's `global.json` pins it).

Fast checks:

```powershell
node --check wrapper/build-portable.mjs
node --check wrapper/latest-upstream-tag.mjs
node --check scripts/package-portable.mjs
mise tasks validate
```

Prepare-only check (clone, overlay, patch and version validation, no build):

```powershell
node wrapper/build-portable.mjs --tag v0.14.3100 --prepare-only
```

Full local build:

```powershell
mise run portable -- --tag v0.14.3100
# or
node wrapper/build-portable.mjs --tag v0.14.3100 --rid win-x64
```

Full builds take roughly 30–60 minutes. Do not run one for documentation-only changes.

## jj workflow

This checkout is a colocated jj/git repository. Use jj for repository state:

```powershell
jj status
jj diff
jj commit -m "..." [paths]
jj bookmark set master -r @-
jj git push --bookmark master   # only when a remote exists
```

Commit separation:

1. PR-able changes: a commit touching only `scripts/package-portable.mjs`.
2. Wrapper changes: workflows, mise, orchestrator, docs.

Do not squash wrapper changes into the PR-able commit. If a change spans both, split it.

## CI and release behavior

- `portable-ci.yml` is path-filtered to wrapper files, builds the latest stable upstream
  on `windows-latest`, and uploads an artifact. It never publishes a release.
- `portable-release.yml` runs every six hours and on manual dispatch. It resolves the
  latest stable tag (or an input tag), skips when `portable-<tag>` already exists unless
  `force` is set, builds, then creates or updates the release with the ZIP, SHA-256 and
  `build-info.json`.
- Every release must include the `.sha256` asset; the release job verifies it with
  `sha256sum -c` before publishing. Do not remove it: Scoop and manual verification use it.
- The packaging script copies the upstream `LICENSE` and `THIRD_PARTY_NOTICES.md` into the
  portable ZIP. Keep that behavior when changing the packaging script.
- The scheduled build uses `win-x64`. `win-arm64` is manual-only and requires the
  `windows-11-arm` runner.
- Scheduled workflows run only on the default branch. Push `master` and set it as default
  before relying on the schedule. GitHub may disable a schedule after 60 days without
  repository activity; re-enable it in the Actions tab if needed.
- GitHub cannot subscribe to another repository's release events. Polling the API is
  intentional; do not replace it with `on: release` for upstream.

## Upstream changes

- The build scripts read the upstream slug only from `UPSTREAM`.
- If upstream changes `scripts/rid-map.mjs`, `scripts/pack-platform.mjs`, the desktop
  output layout or the release build commands, update `scripts/package-portable.mjs` and
  `wrapper/build-portable.mjs` together, then verify with `--prepare-only` and a full
  Windows build.
- If a source patch is needed, add `patches/NNNN-description.patch`. The orchestrator
  checks each patch with `git apply --check` and fails the build when it no longer
  applies. Do not auto-rebase patches.

## PR to upstream

- Fork upstream, branch from upstream `main`, copy only
  `scripts/package-portable.mjs`, commit that file, and open the PR.
- Keep the fork's default branch identical to upstream. Never put wrapper workflows,
  mise tasks or documentation on it.
- GitHub has no configuration that restricts PR contents to a path. Separation comes
  from the repository, the branch and commit hygiene, not from GitHub settings.
- Ask upstream first (issue) whether a portable ZIP is welcome and where the script
  should live.
