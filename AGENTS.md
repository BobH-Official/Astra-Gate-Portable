# AGENTS.md

Guidance for coding agents working in this repository. Read `README.md` first.

`README.md` is the public, user-facing document. Keep repository-owner and maintenance
instructions in this file.

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
| `wrapper/resolve-release.sh` | Wrapper-only planner: picks the tags/RIDs a run must build and the release that owns `latest`. |
| `wrapper/lib/semver.sh` | Shared version ordering helpers (`semver_key`, `semver_valid`, `semver_is_stable`). |
| `wrapper/publish-release.sh` | Wrapper-only release publisher: verifies and uploads assets, merges notes across partial runs. |
| `wrapper/scoop/scoop-register-protocol.ps1` | Optional Notes helper: registers `astra://` for an app directory. |
| `wrapper/scoop/scoop-unregister-protocol.ps1` | Optional Notes helper: removes the `astra://` registration, the reverse of the register script. |
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
bash -n wrapper/lib/semver.sh
bash -n wrapper/resolve-release.sh
bash -n wrapper/publish-release.sh
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

## Portable behavior

- `ASTRA_HOME` is the only data redirection. The app creates the directory and keeps its
  database, keys, logs and plugins there.
- The portable build does not run the NSIS installer. It therefore does not create
  install/uninstall keys or register `astra://` by default.
- The app writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Astra` only when the
  user enables desktop login, and `...\Astra Server` only when the user enables server
  autostart or runs `astra autostart enable`.
- `AutostartService.RefreshAsync` only manages CLI-managed binaries under
  `<ASTRA_HOME>\server\astra-server-<version>`. The portable server in
  `resources/server/astra-server.exe` is not managed, so normal startup does not rewrite
  registry entries.
- Scoop manifests set `ASTRA_HOME` with `env_set`, the same way `bun` sets `BUN_INSTALL`:
  `"ASTRA_HOME": "$persist_dir\\data"`. Scoop owns setting and removing that variable; do
  not set it in the PS1 helpers.
- `scoop-register-protocol.ps1` and `scoop-unregister-protocol.ps1` are optional Notes
  helpers, not Scoop hooks. They only register or remove `astra://` for the app directory;
  they do not touch `ASTRA_HOME`, autostart entries, user data, or NSIS keys. They must work
  on Windows PowerShell 5.1 and PowerShell 7; CI parses them under both shells.
- Autostart entries are controlled by the app: disable desktop login in Settings, or run
  `astra autostart disable` for the server. Do not add source patches for registry cleanup.

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

## CI triggers

- `portable-ci.yml` runs on `pull_request` and on `push` to `master`, path-filtered to
  `scripts/**`, `wrapper/**`, `.mise.toml`, `UPSTREAM` and both workflow files. It also
  has `workflow_dispatch` with an optional `tag` input.
- `portable-release.yml` runs on the `schedule` `23 */4 * * *` (every four hours) and on
  `workflow_dispatch` with `tag`, `rid` and `force` inputs. `rid` is `win-x64`,
  `win-arm64`, or `both`. It has no push trigger.

## CI and release behavior

- `portable-ci.yml` is path-filtered to wrapper files, builds the latest stable upstream
  on `windows-latest`, and uploads an artifact. It never publishes a release.
- `portable-release.yml` runs every four hours and on manual dispatch. `resolve-release.sh`
  builds a plan of `(tag, rid)` pairs and answers three questions:
  - which tags need work: the latest stable upstream tag, the newest version we already
    published (so a release whose ARM64 leg failed is completed), and, when catch-up is
    enabled, every stable version released after the newest published one;
  - which RIDs are missing per tag: a tag is skipped when its
    `Astra-<version>-win32-<arch>-portable.zip` and `.sha256` are both attached to the
    release; `force` makes every requested RID missing;
  - which release must own GitHub's `latest` marker (see below).
- Version gaps are expected: the poll runs every four hours and upstream can publish twice
  in between. A scheduled run enables catch-up (`MAX_CATCH_UP`, default 5, drops the
  oldest of a larger gap) so an intermediate version is still published; a dispatch opts
  in with `catch_up: true`, and an explicit `tag` always disables it. Superseded versions
  are worth keeping because they are the fallback when the newest tag does not build.
- The `build` matrix has one job per `(version, rid)`. Artifacts are named
  `astra-portable-<version>-<rid>`, and the release job downloads its own version with
  `astra-portable-<version>-win-*` so a preview of the same version cannot leak into a
  stable release.
- `latest` handling: GitHub marks whatever release was created last as latest, so a manual
  backfill of an older version would steal `releases/latest` from a newer one. The
  resolver computes the highest stable version from the releases that already exist plus
  the ones this run publishes, and every release job passes it as `LATEST_STABLE_TAG`;
  anything older is created/edited with `--latest=false` and gets a "newer build
  available" note. Previews never send a latest flag. The publisher re-checks that the
  newer release actually has a ZIP before demoting anything, so a failed newer build
  cannot leave `releases/latest` empty. Do not let the publisher decide this per job, and
  do not rely on creation order.
- The `build` matrix uploads `out/portable/<rid>/*` per RID. The upload path must not
  wildcard the RID directory (`out/portable/*/*.zip`): upload-artifact keeps the hierarchy
  below the first wildcard, which nests the files under `win-x64/` and leaves `dist/`
  holding directories instead of assets.
- The `release` matrix has one job per tag and is serialised with `max-parallel: 1`; it
  runs even when part of the build matrix failed (`always()` plus a `resolve` guard). It
  publishes the RIDs that succeeded and warns about the rest; the next tick rebuilds the
  missing pieces because the resolver looks at the assets attached to the release, not at
  what a previous run intended to build. A tag with no artifact at all is a warning when
  the matrix failed and an error when it succeeded.
- Manual dispatch inputs are `tag` (empty = latest stable), `rid` (`win-x64`,
  `win-arm64`, or `both`), `force` (rebuild an existing release) and `catch_up` (also
  build stable versions released since the newest published build). Preview tags are not
  discovered automatically; dispatch with the preview tag.
- Every release must include the `.sha256` asset; `wrapper/publish-release.sh` verifies it
  with `sha256sum -c` before publishing, re-checks the uploaded asset digest, and repeats
  the hash plus the Scoop `hash.url` in the release notes. Do not remove it: Scoop and
  manual verification use it.
- Release notes are generated from the assets attached to the release, not from the
  current `dist/`. A run that only fills in one RID keeps the other RID's hash line, so
  notes must stay additive and must never be rewritten from the last build alone.
- The packaging script copies the upstream `LICENSE` and `THIRD_PARTY_NOTICES.md` into the
  portable ZIP. Keep that behavior when changing the packaging script.
- The release job copies `wrapper/scoop/*.ps1` into `dist`, writes a `.sha256` for each
  script, verifies every checksum, and uploads the optional Scoop Notes helpers next to
  the ZIP. They must stay outside the ZIP.
- The release asset check covers the expected ZIPs and their `.sha256` assets. If a
  release predates the optional Scoop Notes helpers, rebuild with `force` or upload the
  helpers manually.
- A scheduled run covers both RIDs, so the arm64 leg needs the `windows-11-arm` runner.
  A failure there does not block the x64 publication; the next tick retries only arm64.
- Scheduled workflows run only on the default branch. GitHub may disable a schedule after
  60 days without repository activity; re-enable it if needed.

### Why polling instead of `on: release`

A GitHub Actions `release` event only fires in the repository where the release is
published. A wrapper repository (or a fork) cannot subscribe to another repository's
release events. The options are:

1. Scheduled polling (implemented): no upstream cooperation; up to ~4 hours delay.
2. `repository_dispatch` from upstream: requires the maintainers to add a token and a
   dispatch step; lowest latency if they agree.
3. Webhook/GitHub App/RSS bridge: an extra service to host and maintain.

Do not replace the poll with `on: release` for upstream.

### Release planner and publisher

`wrapper/resolve-release.sh` decides what to do; `wrapper/publish-release.sh` does it.
Both are wrapper-only bash scripts with no inline logic left in the YAML, so they can be
tested with a stubbed `gh`.

`resolve-release.sh`:
1. lists this repository's releases (drafts excluded) and the upstream stable releases
   through `gh api`;
2. reads its inputs (`INPUT_TAG`, `INPUT_RID`, `INPUT_FORCE`, `INPUT_CATCH_UP`);
3. writes `build_matrix` (`{"include":[{tag, version, rid}]}`), `release_matrix`
   (`{"include":[{tag, version}]}`), `latest_stable` and `skip` to `GITHUB_OUTPUT`. The
   workflow feeds both objects straight to `strategy.matrix`, so an empty result is still
   a valid matrix and versions are visited newest first.

`publish-release.sh`:
1. verifies every `dist/*.sha256` with `sha256sum -c` and rejects a ZIP without its
   checksum file;
2. creates the release when it is missing and uploads every asset with `--clobber`;
3. re-reads the release through the API and fails when an asset did not land or its
   digest differs from the local file;
4. regenerates the notes from the assets attached to the release, so a run that only
   fills one RID keeps the other RID's hash line, and adds a "newer build available" note
   when the release is not the newest stable one;
5. passes `--latest` only to the release named by `LATEST_STABLE_TAG`, and
   `--latest=false` to older ones — but only after confirming the newer release really
   carries a `-portable.zip` asset. A planned version can fail to build, and demoting
   every remaining release would leave `releases/latest` (and Scoop's `$url`) empty;
6. exits non-zero only when nothing could be published.

Keep release logic in those scripts rather than inline in the workflow. They need bash 4
or newer (associative arrays and `mapfile`); `ubuntu-latest` ships bash 5. CI checks them
with `bash -n`; ordering lives in `wrapper/lib/semver.sh`, so do not compare version
strings with `<` or `sort` directly.

## Patches

Do not create `patches/` preemptively. If a source change is needed:

1. Add `patches/NNNN-short-description.patch`.
2. The orchestrator applies patches in filename order after copying the packaging script.
3. Each patch is checked with `git apply --check`; a patch that no longer applies fails
   the build.

Patches are not rebased automatically. A failed scheduled build signals that a patch
needs maintenance; do not auto-merge source patches.

## Upstream changes

- The build scripts read the upstream slug only from `UPSTREAM`.
- If upstream changes `scripts/rid-map.mjs`, `scripts/pack-platform.mjs`, the desktop
  output layout or the release build commands, update `scripts/package-portable.mjs` and
  `wrapper/build-portable.mjs` together, then verify with `--prepare-only` and a full
  Windows build.
- If a source patch is needed, add `patches/NNNN-description.patch`; see [Patches](#patches).
  The orchestrator checks each patch with `git apply --check` and fails the build when it
  no longer applies. Do not auto-rebase patches.

## PR to upstream

- Fork upstream, branch from upstream `main`, copy only
  `scripts/package-portable.mjs`, commit that file, and open the PR.
- Keep the fork's default branch identical to upstream. Never put wrapper workflows,
  mise tasks or documentation on it.
- GitHub has no configuration that restricts PR contents to a path. Separation comes
  from the repository, the branch and commit hygiene, not from GitHub settings.
- Ask upstream first (issue) whether a portable ZIP is welcome and where the script
  should live.
