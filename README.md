# Astra Gate Portable (unofficial)

Unofficial, unpack-and-run Windows builds of
[Astra Gate](https://github.com/239573049/Astra-Gate).

| | |
| --- | --- |
| Upstream | [239573049/Astra-Gate](https://github.com/239573049/Astra-Gate) |
| License | [MIT](LICENSE), same terms as upstream |
| Platform | Windows x64; ARM64 builds are available manually |
| Scope | Unofficial portable packaging; this repository is not a source fork |

This repository does not contain Astra Gate source code. Each release is built from an
upstream release tag: the build shallow-clones that tag, overlays the packaging script,
and runs upstream's build commands. See [How it works](#how-it-works).

> Not affiliated with the Astra Gate project. Report portable-build problems here; report
> product bugs upstream.

## Download and run

Download the latest `Astra-<version>-win32-x64-portable.zip` and its `.sha256` file from
the [latest release](../../releases/latest) page.

1. Verify the SHA-256 (see below).
2. Unpack the ZIP anywhere.
3. Run `Astra.exe`.

No installer, administrator rights, Node.js, or .NET runtime is required. The app uses
upstream's data directory (`%USERPROFILE%\.astra`) by default. Set `ASTRA_HOME` before
launching to keep data next to the unpacked files; this is an upstream-supported
environment variable. The binaries are not code-signed, so Windows SmartScreen may warn.

## Package contents

The ZIP contains:

- `Astra.exe` — the Avalonia desktop app, Native AOT.
- `resources/server/` — `astra-server.exe`, its native companions, and the web console.
- `LICENSE` and `THIRD_PARTY_NOTICES.md` from the upstream tag.

Each release also publishes:

- `Astra-<version>-win32-<arch>-portable.zip.sha256`
- `build-info.json` — upstream tag, RID, size, SHA-256, and build run.

## Verify the download

The `.sha256` file uses the standard `<sha256>  <filename>` format.

```powershell
Get-FileHash .\Astra-<version>-win32-x64-portable.zip -Algorithm SHA256
Get-Content .\Astra-<version>-win32-x64-portable.zip.sha256
```

On a system with `sha256sum`:

```bash
sha256sum -c Astra-<version>-win32-x64-portable.zip.sha256
```

The release workflow verifies the checksum before publishing and repeats the hash in the
release notes.

### Scoop

The checksum asset is exactly `<zip>.sha256`, so a Scoop manifest can use:

```json
"hash": {
  "url": "$url.sha256"
}
```

Adjust the manifest URL for the ARM64 asset if needed.

## Releases

Stable upstream releases are discovered automatically every six hours. Release tags use
the upstream tag with a prefix:

```text
portable-<upstream tag>    # e.g. portable-v0.14.3100
```

Preview versions are marked as prereleases and are not built automatically. Scheduled
builds target `win-x64`; `win-arm64` builds are available manually.

## Build from source

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
the Windows Native AOT publish and the ZIP step use Windows tooling. Full builds take
roughly 30–60 minutes. Pull requests that touch the build wrapper run the same build in
GitHub Actions.

## How it works

1. Resolve the upstream release tag: an explicit `--tag`, or the latest stable release
   from the GitHub API.
2. Shallow-clone `https://github.com/<UPSTREAM>` at that tag into `.upstream/`
   (gitignored).
3. Check that the tag matches `cli/package.json` and that upstream still has the packaging
   helpers this wrapper depends on.
4. Copy `scripts/package-portable.mjs` into the checkout and apply optional patches.
5. Run the same build steps as the upstream release: pnpm install, web build, Native AOT
   publish of the server, Native AOT build/publish of the desktop app, then the server
   plugin self-test and the desktop `--smoke` test.
6. Run `scripts/package-portable.mjs`: stage `Astra.exe` plus the packed server, create
   the ZIP, write its SHA-256, extract the ZIP and verify the extracted layout and file
   sizes.
7. Write `build-info.json` with the upstream tag, RID, checksum, size and workflow run.

Outputs land in `out/portable/<rid>/`:

```text
Astra-<version>-win32-<arch>-portable.zip
Astra-<version>-win32-<arch>-portable.zip.sha256
build-info.json
```

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
| `.github/workflows/portable-ci.yml` | Builds pull requests and `master` pushes; no release. | No |
| `.github/workflows/portable-release.yml` | Scheduled/manual upstream check, build and GitHub release. | No |
| `UPSTREAM` | One line: `owner/repo` of the upstream project. | No |
| `LICENSE` | MIT license for this wrapper; same terms as upstream. | No |
| `patches/` | Optional source patches. Not created until a patch is actually needed. | No |
| `README.md`, `AGENTS.md` | Documentation. | No |

## Contributing upstream

Only one file can be copied 1:1 into an upstream checkout and proposed as a PR:

| Local path | Upstream path | How to use |
| --- | --- | --- |
| `scripts/package-portable.mjs` | `scripts/package-portable.mjs` | Copy as-is, commit it alone, and open a PR against upstream `main`. |

No other file is upstream-mergeable. `wrapper/**`, `.github/workflows/**`, `.mise.toml`,
`UPSTREAM`, `README.md`, `AGENTS.md` and `LICENSE` are wrapper-only. The root `LICENSE` is
the wrapper's copy; the ZIP carries the upstream license from the built tag.
`scripts/package-portable.mjs` uses only upstream's existing `scripts/rid-map.mjs` and
`scripts/pack-platform.mjs` and runs from a clean upstream checkout.

Export it to a fork branch:

```powershell
git switch -c feat/portable-packaging upstream/main
Copy-Item <path-to-this-repo>/scripts/package-portable.mjs scripts/package-portable.mjs
git add scripts/package-portable.mjs
git commit -m "feat: add portable packaging script"
```

The path in this repository is already the upstream path, so no translation is needed.
Keep wrapper workflows, mise configuration and documentation off the upstream PR branch.
GitHub has no setting that restricts PR contents to a path; the separation comes from the
repository, the branch and the commits.

Consider opening an issue upstream first to ask whether a portable ZIP is welcome and
where the script should live.

## License

This repository uses the MIT license, the same terms as upstream Astra Gate. The root
[`LICENSE`](LICENSE) names this wrapper's maintainer. The portable ZIP contains the
upstream `LICENSE` (with the upstream copyright notice) and `THIRD_PARTY_NOTICES.md`,
copied from the built tag by `scripts/package-portable.mjs` because the ZIP redistributes
upstream binaries.

Upstream: [239573049/Astra-Gate](https://github.com/239573049/Astra-Gate).

## Limitations

- Windows only; there are no macOS or Linux portable builds here.
- No installer integration, auto-update integration or code signing.
- Data is not relocated automatically: use `ASTRA_HOME` if you want a self-contained
  directory.
- Preview upstream versions are not discovered automatically.
