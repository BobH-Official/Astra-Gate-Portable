#!/usr/bin/env bash
# Print the toolchain an upstream tag builds with.
#
# Wrapper-only helper. Upstream does not publish one machine-readable toolchain
# file: the .NET SDK lives in `global.json`, pnpm in `package.json`
# (`packageManager`), and Node only in their release workflow. That is also why
# their own release.yml has to be edited by hand when a pin moves — v0.14.3103
# asked for the RC SDK and v0.14.3104 for the GA one, which broke any workflow
# that hardcoded either.
#
# Every value is read from the tag being built, so a pin change needs no edit
# here:
#   dotnet  global.json  -> sdk.version          (required)
#   pnpm    package.json -> packageManager       (falls back to 9.15.0)
#   node    release.yml  -> first node-version   (falls back to 24)
#
# Only `gh` is required: the JSON is read with `gh api --jq`, so there is no
# node/jq dependency and no stdin piping that breaks under WSL interop.
#
# Usage:
#   bash wrapper/upstream-toolchain.sh                  # all values, KEY=VALUE
#   bash wrapper/upstream-toolchain.sh v0.14.3104       # specific tag
#   bash wrapper/upstream-toolchain.sh --get dotnet v0.14.3104
#
# Environment:
#   GH_TOKEN       optional; avoids the anonymous API rate limit
#   UPSTREAM_FILE  overrides the UPSTREAM path (default: <repo>/UPSTREAM)
#
# With --get the output is exactly one value, so it can be captured directly.
#
# Every helper returns a status instead of relying on `errexit`: a command
# substitution that is part of a `||` test runs with errexit disabled, so a
# failing `die` inside it would not stop this script.

set -uo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd -- "$script_dir/.." && pwd)"

readonly default_pnpm="9.15.0"
readonly default_node="24"

# Set by the helpers below instead of being captured from a subshell.
toolchain_body=""
toolchain_value=""

die() { printf '::error::%s\n' "$*" >&2; exit 1; }
fail() { printf '::error::%s\n' "$*" >&2; return 1; }
warn() { printf '::warning::%s\n' "$*" >&2; }

want=""
if [ "${1:-}" = "--get" ]; then
  want="${2:-}"
  shift 2
  case "$want" in
    dotnet | pnpm | node) ;;
    *) die "--get expects dotnet, pnpm or node; got '${want:-<empty>}'" ;;
  esac
fi

upstream_file="${UPSTREAM_FILE:-$repo_root/UPSTREAM}"
[ -f "$upstream_file" ] || die "UPSTREAM file not found: $upstream_file"
slug="$(tr -d '[:space:]' < "$upstream_file")"
[ -n "$slug" ] || die "UPSTREAM is empty: $upstream_file"

tag="${1:-}"
if [ -z "$tag" ]; then
  # No tag given: follow the same "latest stable" rule as the build. gh's
  # "latest" excludes drafts and prereleases, matching /releases/latest.
  tag="$(gh release view --repo "$slug" --json tagName --jq .tagName 2>/dev/null)" \
    || die "Could not resolve the latest release of $slug"
  [ -n "$tag" ] || die "The latest release of $slug has no tag name"
fi
case "$tag" in
  v*) ;;
  *) tag="v$tag" ;;
esac

# Raw body of one file at the tag, in `toolchain_body`. Used for non-JSON files.
read_file() {
  local file="$1" body
  body="$(gh api "repos/$slug/contents/$file?ref=$tag" \
    -H 'Accept: application/vnd.github.raw' 2>&1)"
  if [ $? -ne 0 ]; then
    toolchain_body="$body"
    return 1
  fi
  toolchain_body="$body"
  return 0
}

# One jq expression against a JSON file at the tag, in `toolchain_value`. An
# empty result means the key is absent; a failed request is fatal, because
# guessing the .NET SDK wastes a whole build.
json_value() {
  local file="$1" expr="$2" value status
  value="$(gh api "repos/$slug/contents/$file?ref=$tag" \
    -H 'Accept: application/vnd.github.raw' --jq "$expr" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    toolchain_value="$value"
    return 1
  fi
  toolchain_value="$value"
  return 0
}

resolve_dotnet() {
  if ! json_value global.json '.sdk.version'; then
    fail "Cannot read global.json at $tag from $slug: $toolchain_value"
    return 1
  fi
  if [ -z "$toolchain_value" ]; then
    fail "global.json at $tag has no sdk.version; cannot pick a .NET SDK"
    return 1
  fi
  printf '%s' "$toolchain_value"
}

resolve_pnpm() {
  local manager
  if ! json_value package.json '.packageManager'; then
    fail "Cannot read package.json at $tag from $slug: $toolchain_value"
    return 1
  fi
  manager="$toolchain_value"
  # `packageManager` is `<manager>@<version>[+<hash>]`; only pnpm is meaningful
  # here because that is what the wrapper installs.
  case "$manager" in
    pnpm@*)
      manager="${manager#pnpm@}"
      printf '%s' "${manager%%+*}"
      ;;
    '')
      warn "package.json at $tag has no packageManager; using pnpm $default_pnpm"
      printf '%s' "$default_pnpm"
      ;;
    *)
      warn "package.json at $tag uses '$manager' instead of pnpm; using pnpm $default_pnpm"
      printf '%s' "$default_pnpm"
      ;;
  esac
}

resolve_node() {
  local version
  # Their release workflow is the only place the Node version is recorded.
  if ! read_file .github/workflows/release.yml; then
    fail "Cannot read .github/workflows/release.yml at $tag from $slug: $toolchain_body"
    return 1
  fi
  version="$(printf '%s\n' "$toolchain_body" |
    sed -nE 's/^[[:space:]]*node-version:[[:space:]]*//p' |
    head -n 1 |
    tr -d "\"" | tr -d "'" | tr -d '[:space:]')"
  # A matrix value such as `[24, 26]` still starts with the version to use.
  version="${version%%,*}"
  version="${version#[}"
  version="${version%]}"
  if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    warn "release.yml at $tag has no usable node-version; using Node $default_node"
    printf '%s' "$default_node"
    return 0
  fi
  printf '%s' "$version"
}

resolve() {
  case "$1" in
    dotnet) resolve_dotnet ;;
    pnpm) resolve_pnpm ;;
    node) resolve_node ;;
  esac
}

if [ -n "$want" ]; then
  if ! value="$(resolve "$want")"; then
    exit 1
  fi
  printf '%s\n' "$value"
  exit 0
fi

# All values: KEY=VALUE lines that can be sourced or appended to $GITHUB_OUTPUT.
dotnet_version="$(resolve dotnet)" || exit 1
pnpm_version="$(resolve pnpm)" || exit 1
node_version="$(resolve node)" || exit 1

printf 'dotnet=%s\n' "$dotnet_version"
printf 'pnpm=%s\n' "$pnpm_version"
printf 'node=%s\n' "$node_version"
