#!/usr/bin/env bash
# Publish (create or update) the portable GitHub release.
#
# Wrapper-only helper: it is not upstream code and must never be copied into the
# packaged ZIP. The release workflow runs it from the wrapper checkout after the
# build matrix has uploaded its artifacts. It can also be run by hand once the
# assets of a previous run are staged in `dist/`:
#
#   TAG=v0.14.3103 VERSION=0.14.3103 bash wrapper/publish-release.sh
#
# Required environment:
#   TAG       upstream release tag, e.g. v0.14.3103
#   VERSION   the same tag without the leading v, e.g. 0.14.3103
#
# Optional environment:
#   BUILT_RIDS         space-separated RIDs built in this run, e.g. "win-x64 win-arm64"
#   LATEST_STABLE_TAG  tag that must stay GitHub's "latest"; anything older is
#                      published with --latest=false so backfilling a version
#                      cannot steal the marker from a newer one
#   DIST_DIR           directory holding the assets to publish (default: <repo>/dist)
#   UPSTREAM_FILE      file holding the upstream slug (default: <repo>/UPSTREAM)
#   GH_REPO            owner/repo to publish to; gh infers the remote when unset
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SHA
#
# The release is always described from the assets that are actually attached to
# it, not from what one run happened to build. That keeps the notes and the
# hashes correct when a run only fills in one missing RID.
#
# Exit status is non-zero only when nothing could be published. A partially
# failed build matrix still publishes the RIDs that succeeded; the next run
# rebuilds the missing ones because the resolver checks the assets that are
# attached to the release.

set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=lib/semver.sh
source "$script_dir/lib/semver.sh"

die() { printf '::error::%s\n' "$*" >&2; exit 1; }
log() { printf '[publish-release] %s\n' "$*"; }

: "${TAG:?TAG is required}"
: "${VERSION:?VERSION is required}"

dist_dir="${DIST_DIR:-$repo_root/dist}"
upstream_file="${UPSTREAM_FILE:-$repo_root/UPSTREAM}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
built_rids="${BUILT_RIDS:-}"
latest_stable_tag="${LATEST_STABLE_TAG:-}"

release_tag="portable-$TAG"
title="Astra Gate portable $VERSION (unofficial)"

flags=()
case "$VERSION" in
  *-preview.*) flags+=(--prerelease) ;;
esac

# Is the newer stable version actually downloadable? A planned version can fail
# to build, and marking every remaining release as "not latest" would leave
# releases/latest (and Scoop's `$url`) pointing at nothing.
newer_release_available() {
  local candidate="${1#v}" names
  semver_valid "$candidate" || return 1
  names="$(gh release view "portable-v$candidate" --json assets --jq '.assets[].name' 2>/dev/null)" || return 1
  # Anchor the pattern: `<zip>.sha256` also contains "portable.zip", and a
  # release that only holds a checksum is not a usable download.
  grep -Eq -- '-portable\.zip$' <<< "$names"
}

# GitHub marks the most recently created release as "latest", which would make a
# manual backfill of an older version the download behind `releases/latest`.
# Publishing an older version therefore has to opt out explicitly.
superseded_by=""
if semver_is_stable "$VERSION"; then
  if [ -z "$latest_stable_tag" ] || [ "v$VERSION" = "$latest_stable_tag" ]; then
    flags+=(--latest)
  elif newer_release_available "$latest_stable_tag"; then
    flags+=(--latest=false)
    superseded_by="$latest_stable_tag"
  else
    log "warning: $latest_stable_tag is newer but has no release yet; keeping 'latest' on $release_tag"
    flags+=(--latest)
  fi
fi

[ -d "$dist_dir" ] || die "asset directory not found: $dist_dir"

# ---------------------------------------------------------------- local assets

shopt -s nullglob

local_zips=("$dist_dir"/Astra-*-win32-*-portable.zip)
if [ "${#local_zips[@]}" -eq 0 ]; then
  ls -la "$dist_dir" >&2 || true
  die "no portable ZIP in $dist_dir; nothing to publish"
fi

zip_names=()
for path in "${local_zips[@]}"; do
  zip_names+=("${path##*/}")
done
mapfile -t zip_names < <(printf '%s\n' "${zip_names[@]}" | LC_ALL=C sort)

declare -A local_hash=()
for name in "${zip_names[@]}"; do
  sha_file="$dist_dir/$name.sha256"
  [ -f "$sha_file" ] || die "missing checksum asset for $name"
  hash="$(awk 'NR == 1 { print $1 }' "$sha_file")"
  if ! [[ "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    die "invalid SHA-256 in $name.sha256"
  fi
  local_hash["$name"]="$hash"
done

log "verifying local checksums in $dist_dir"
( cd "$dist_dir" && sha256sum -c ./*.sha256 )

release_assets=()
for name in "${zip_names[@]}"; do
  release_assets+=("$dist_dir/$name" "$dist_dir/$name.sha256")
done
for extra in "$dist_dir"/build-info-*.json "$dist_dir"/*.ps1 "$dist_dir"/*.ps1.sha256; do
  release_assets+=("$extra")
done

log "prepared ${#release_assets[@]} asset(s) for $release_tag"

# ------------------------------------------------------- create or update tag

if gh release view "$release_tag" >/dev/null 2>&1; then
  log "release $release_tag exists; updating it"
else
  log "creating release $release_tag"
  target_args=()
  if [ -n "${GITHUB_SHA:-}" ]; then
    target_args=(--target "$GITHUB_SHA")
  fi
  placeholder="$(mktemp)"
  printf 'Publishing Astra Gate %s portable builds.\n' "$VERSION" > "$placeholder"
  gh release create "$release_tag" --title "$title" --notes-file "$placeholder" \
    "${target_args[@]}" "${flags[@]}"
  rm -f "$placeholder"
fi

# -------------------------------------------------------------------- upload

log "uploading ${#release_assets[@]} asset(s) with --clobber"
gh release upload "$release_tag" "${release_assets[@]}" --clobber

if [ -n "${GH_REPO:-}" ]; then
  release_api="repos/$GH_REPO/releases/tags/$release_tag"
else
  release_api="repos/{owner}/{repo}/releases/tags/$release_tag"
fi

assets_tsv="$(mktemp)"
trap 'rm -f "$assets_tsv"' EXIT
gh api "$release_api" --jq '.assets[] | "\(.name)\t\(.digest // "")"' | LC_ALL=C sort > "$assets_tsv"

declare -A attached=()
while IFS=$'\t' read -r name digest; do
  [ -n "$name" ] || continue
  attached["$name"]="$digest"
done < "$assets_tsv"

# Fail loudly if an upload is missing or landed with the wrong bytes.
verify_failed=0
for name in "${zip_names[@]}"; do
  if [ -z "${attached[$name]+x}" ]; then
    printf '::error::%s is not attached to %s after the upload\n' "$name" "$release_tag" >&2
    verify_failed=1
    continue
  fi
  got="${attached[$name]}"
  want="sha256:${local_hash[$name]}"
  if [ -z "$got" ]; then
    log "warning: the release API returned no digest for $name; upload not verified"
  elif [ "$got" != "$want" ]; then
    printf '::error::digest mismatch for %s: release has %s, local file is %s\n' \
      "$name" "$got" "$want" >&2
    verify_failed=1
  fi
done
[ "$verify_failed" -eq 0 ] || exit 1

# --------------------------------------------------------------------- notes

mapfile -t release_asset_names < <(printf '%s\n' "${!attached[@]}" | LC_ALL=C sort)

api_digest() { printf '%s' "${attached[$1]:-}"; }

# Keep a stable order (x64, then arm64) so the notes do not flip around when the
# asset listing is sorted by name.
declare -A zip_seen=()
release_zips=()
for arch in x64 arm64; do
  for name in "${release_asset_names[@]}"; do
    if [[ "$name" == *-portable.zip && "$name" == *-win32-"$arch"-portable.zip ]]; then
      release_zips+=("$name")
      zip_seen["$name"]=1
    fi
  done
done
for name in "${release_asset_names[@]}"; do
  if [[ "$name" == *-portable.zip && -z "${zip_seen[$name]:-}" ]]; then
    release_zips+=("$name")
  fi
done
if [ "${#release_zips[@]}" -eq 0 ]; then
  die "release $release_tag has no portable ZIP after the upload"
fi

# SHA-256 of a ZIP that is attached to the release but was built by an earlier
# run: prefer the digest the API reports, then the published .sha256 asset.
release_hash() {
  local name="$1" digest tmp
  if [ -n "${local_hash[$name]:-}" ]; then
    printf '%s' "${local_hash[$name]}"
    return 0
  fi
  digest="$(api_digest "$name")"
  if [ -n "$digest" ]; then
    printf '%s' "${digest#sha256:}"
    return 0
  fi
  tmp="$(mktemp -d)"
  if gh release download "$release_tag" --pattern "$name.sha256" --dir "$tmp" --clobber \
      >/dev/null 2>&1 && [ -f "$tmp/$name.sha256" ]; then
    awk 'NR == 1 { print $1 }' "$tmp/$name.sha256"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

arch_list=""
for name in "${release_zips[@]}"; do
  arch="${name#*win32-}"
  arch="${arch%-portable.zip}"
  case "$arch" in
    x64 | arm64) arch_list="${arch_list:+$arch_list, }win-$arch" ;;
  esac
done

upstream_slug=""
if [ -f "$upstream_file" ]; then
  upstream_slug="$(tr -d '[:space:]' < "$upstream_file")"
fi

notes_file="$(mktemp)"
trap 'rm -f "$assets_tsv" "$notes_file"' EXIT
{
  printf 'Unofficial Windows portable build of Astra Gate %s.\n' "$TAG"
  printf '\n'
  if [ -n "$upstream_slug" ]; then
    printf -- '- Upstream release: %s/%s/releases/tag/%s\n' "$server_url" "$upstream_slug" "$TAG"
  fi
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf -- '- Build run: %s/%s/actions/runs/%s\n' "$server_url" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  fi
  if [ -n "${GITHUB_SHA:-}" ]; then
    printf -- '- Wrapper commit: %s\n' "$GITHUB_SHA"
  fi
  if [ -n "$arch_list" ]; then
    printf -- '- Available builds: %s\n' "$arch_list"
  fi
  if [ -n "$superseded_by" ]; then
    printf -- '- Newer build available: %s. Install that one unless you specifically need %s.\n' \
      "portable-$superseded_by" "$VERSION"
  fi
  if [ -n "$built_rids" ]; then
    printf -- '- RIDs built in this run: %s\n' "$built_rids"
  fi
  printf -- '- Assets: unpack-and-run ZIPs and their SHA-256 files. No installer and no admin rights.\n'
  printf -- '- Scoop Notes helpers: scoop-register-protocol.ps1 and scoop-unregister-protocol.ps1 (with .sha256).\n'
  printf '\n'
  for name in "${release_zips[@]}"; do
    hash="$(release_hash "$name" || true)"
    if [ -n "$hash" ]; then
      printf -- '- %s SHA-256: %s\n' "$name" "$hash"
    else
      printf -- '- %s SHA-256: unknown, see %s.sha256\n' "$name" "$name"
    fi
    printf '  Scoop hash.url: %s/%s/releases/download/%s/%s.sha256\n' \
      "$server_url" "${GITHUB_REPOSITORY:-}" "$release_tag" "$name"
  done
  printf '\n'
  printf -- '- Not affiliated with the upstream project. Report portable-build issues in this repository.\n'
} > "$notes_file"

gh release edit "$release_tag" --title "$title" --notes-file "$notes_file" "${flags[@]}"

log "published $release_tag with ${#release_zips[@]} ZIP asset(s)"
for name in "${release_zips[@]}"; do
  log "  $name"
done
