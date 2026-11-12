#!/usr/bin/env bash
# Work out what a portable-release run has to build.
#
# Wrapper-only helper. The release workflow runs it in the `resolve` job; it
# writes the GitHub Actions outputs that drive the build and release matrices.
#
# Required environment:
#   GH_TOKEN, GH_REPO, GITHUB_OUTPUT
#
# Optional environment:
#   INPUT_TAG       explicit upstream tag; when set, only that tag is considered
#   INPUT_RID       win-x64, win-arm64, or both      (default: both)
#   INPUT_FORCE     "true" rebuilds every requested RID, even if published
#   INPUT_CATCH_UP  "true" also builds stable versions released since the newest
#                   published portable release (scheduled runs enable this)
#   MAX_CATCH_UP    cap on how many missed versions one run builds (default: 5)
#   UPSTREAM_FILE   file holding the upstream slug (default: <repo>/UPSTREAM)
#
# Outputs:
#   build_matrix    dynamic matrix (`{"include":[...]}`) of {tag, version, rid}
#   release_matrix  dynamic matrix (`{"include":[...]}`) of {tag, version}
#   latest_stable   tag that must stay GitHub's "latest" release (may be empty)
#   skip            "true" when there is nothing to build
#
# Policy for versions released between two polls: a scheduled run builds the
# newest stable version and, when catch-up is enabled, every stable version
# released after the newest portable release we already have. Superseded
# versions are still worth publishing: if the newest upstream tag does not
# build, users fall back to the previous one instead of an old release. The
# oldest of a very large gap are dropped, because those are the ones nobody
# will install.

set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=lib/semver.sh
source "$script_dir/lib/semver.sh"

die() { printf '::error::%s\n' "$*" >&2; exit 1; }
log() { printf '[resolve-release] %s\n' "$*"; }

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required; run this from GitHub Actions}"
repo="${GH_REPO:-}"
[ -n "$repo" ] || die "GH_REPO is required"

upstream_file="${UPSTREAM_FILE:-$repo_root/UPSTREAM}"
max_catch_up="${MAX_CATCH_UP:-5}"
case "$max_catch_up" in
  '' | *[!0-9]*) die "MAX_CATCH_UP must be a positive integer, got: $max_catch_up" ;;
esac
[ "$max_catch_up" -ge 1 ] || die "MAX_CATCH_UP must be at least 1"

force="${INPUT_FORCE:-false}"
requested_rid="${INPUT_RID:-both}"
case "$requested_rid" in
  both) rids=(win-x64 win-arm64) ;;
  win-x64 | win-arm64) rids=("$requested_rid") ;;
  *) die "Unsupported rid: $requested_rid" ;;
esac

# ------------------------------------------------------------ published so far

if ! releases_raw=$(gh api "repos/$repo/releases?per_page=100" --paginate \
  --jq '.[] | select(.draft == false) | .tag_name' 2>&1); then
  die "Cannot list the releases of $repo: $releases_raw"
fi

existing_versions=()
while IFS= read -r release_name; do
  [ -n "$release_name" ] || continue
  case "$release_name" in
    portable-v*) ;;
    *) continue ;;
  esac
  published="${release_name#portable-v}"
  semver_valid "$published" || continue
  existing_versions+=("$published")
done <<< "$releases_raw"

newest_published_key=""
newest_published=""
for published in "${existing_versions[@]}"; do
  semver_is_stable "$published" || continue
  key="$(semver_key "$published")"
  if [ -z "$newest_published_key" ] || [[ "$key" > "$newest_published_key" ]]; then
    newest_published_key="$key"
    newest_published="$published"
  fi
done
if [ -n "$newest_published" ]; then
  log "newest published stable build: v$newest_published"
else
  log "no stable portable release has been published yet"
fi

# ---------------------------------------------------------- candidate versions

candidates=()
catch_up=false
if [ -n "${INPUT_TAG:-}" ]; then
  log "explicit tag requested (${INPUT_TAG}); catch-up disabled"
  candidates=("$INPUT_TAG")
else
  latest="$(node "$repo_root/wrapper/latest-upstream-tag.mjs")" \
    || die "Could not resolve the latest upstream release"
  case "$latest" in
    v*) ;;
    *) latest="v$latest" ;;
  esac
  candidates=("$latest")
  # Repair the newest published build when its release is partial (e.g. the
  # ARM64 leg failed). Without this a half-published release would never be
  # completed once a newer upstream version exists.
  if [ -n "$newest_published" ]; then
    candidates+=("v$newest_published")
  fi
  if [ "${INPUT_CATCH_UP:-false}" = "true" ]; then
    catch_up=true
  fi
fi

slug=""
if [ -f "$upstream_file" ]; then
  slug="$(tr -d '[:space:]' < "$upstream_file")"
fi

if [ "$catch_up" = "true" ] && [ -z "$newest_published" ]; then
  # Nothing published yet: the "gap" is the whole history, and nobody needs
  # those versions. Start from the latest and let the next ticks catch up.
  log "no stable build published yet; skipping catch-up"
elif [ "$catch_up" = "true" ]; then
  if [ -z "$slug" ]; then
    log "warning: $upstream_file is missing; a missed version cannot be discovered"
  elif ! upstream_raw=$(gh api "repos/$slug/releases?per_page=100" --paginate \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' 2>&1); then
    log "warning: cannot list the releases of $slug ($upstream_raw); only the latest tag is considered"
  else
    missed=()
    while IFS= read -r upstream_tag; do
      [ -n "$upstream_tag" ] || continue
      case "$upstream_tag" in
        v*) ;;
        *) continue ;;
      esac
      candidate="${upstream_tag#v}"
      semver_valid "$candidate" || continue
      semver_is_stable "$candidate" || continue
      key="$(semver_key "$candidate")"
      # Anything at or below the newest published build is either done or has
      # a release of its own that the per-tag check below will repair.
      if [ -n "$newest_published_key" ] && [[ ! "$key" > "$newest_published_key" ]]; then
        continue
      fi
      missed+=("$key $upstream_tag")
    done <<< "$upstream_raw"

    if [ "${#missed[@]}" -gt 0 ]; then
      mapfile -t missed < <(printf '%s\n' "${missed[@]}" | LC_ALL=C sort)
      if [ "${#missed[@]}" -gt "$max_catch_up" ]; then
        log "warning: ${#missed[@]} versions were released while polling was idle; dropping the $((${#missed[@]} - max_catch_up)) oldest"
        missed=("${missed[@]: -$max_catch_up}")
      fi
      for entry in "${missed[@]}"; do
        candidates+=("${entry#* }")
      done
      log "catching up on: $(for entry in "${missed[@]}"; do printf '%s ' "${entry#* }"; done)"
    fi
  fi
fi

# --------------------------------------------------- per-tag missing RIDs

declare -A seen_tag=()
plan_items=()
tag_items=()
planned_versions=()

build_json_array() {
  local out="[" sep="" item
  for item in "$@"; do
    out="${out}${sep}${item}"
    sep=","
  done
  printf '%s]' "$out"
}

# Newest first: the release matrix then publishes the newest version before the
# older fallbacks, which matters when a run is cancelled half way through.
normalised=()
for raw_tag in "${candidates[@]}"; do
  tag="$raw_tag"
  case "$tag" in
    v*) ;;
    *) tag="v$tag" ;;
  esac
  version="${tag#v}"
  semver_valid "$version" || die "Unsupported upstream tag: $tag"
  normalised+=("$(semver_key "$version") $tag")
done
if [ "${#normalised[@]}" -gt 0 ]; then
  mapfile -t normalised < <(printf '%s\n' "${normalised[@]}" | LC_ALL=C sort -r -u)
fi
candidates=()
for entry in "${normalised[@]}"; do
  candidates+=("${entry#* }")
done

for raw_tag in "${candidates[@]}"; do
  tag="$raw_tag"
  if [ -n "${seen_tag[$tag]:-}" ]; then
    continue
  fi
  seen_tag["$tag"]=1

  version="${tag#v}"
  release_name="portable-$tag"

  assets=""
  if [ "$force" != "true" ]; then
    if raw_assets=$(gh release view "$release_name" --json assets --jq '.assets[].name' 2>&1); then
      assets="$raw_assets"
    else
      case "$raw_assets" in
        # No release for this tag yet: every RID is missing, not an error.
        *"release not found"* | *"Not Found"* | *404*)
          assets=""
          ;;
        *)
          die "Cannot read the assets of $release_name: $raw_assets"
          ;;
      esac
    fi
  fi

  missing=()
  for rid in "${rids[@]}"; do
    case "$rid" in
      win-x64) arch=x64 ;;
      win-arm64) arch=arm64 ;;
    esac
    asset="Astra-$version-win32-$arch-portable.zip"
    if [ "$force" = "true" ] \
      || ! grep -Fxq "$asset" <<< "$assets" \
      || ! grep -Fxq "$asset.sha256" <<< "$assets"; then
      missing+=("$rid")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "$release_name already has the requested assets (${rids[*]})"
    continue
  fi

  log "$release_name needs: ${missing[*]}"
  tag_items+=("{\"tag\":\"$tag\",\"version\":\"$version\"}")
  planned_versions+=("$version")
  for rid in "${missing[@]}"; do
    plan_items+=("{\"tag\":\"$tag\",\"version\":\"$version\",\"rid\":\"$rid\"}")
  done
done

# ------------------------------------------------- GitHub's "latest" release

# Which release must carry the `latest` marker. Publishing an older version by
# hand must never take the marker away from a newer one, and GitHub otherwise
# marks whatever was created last as latest. Computed here from the releases
# that exist plus the ones this run will publish, so the build jobs do not race
# each other when several versions are published in one run.
latest_stable_tag=""
latest_stable_key=""
consider_latest() {
  local candidate="$1" key
  semver_is_stable "$candidate" || return 0
  key="$(semver_key "$candidate")"
  if [ -z "$latest_stable_key" ] || [[ "$key" > "$latest_stable_key" ]]; then
    latest_stable_key="$key"
    latest_stable_tag="v$candidate"
  fi
}
for published in "${existing_versions[@]}"; do
  consider_latest "$published"
done
for published in "${planned_versions[@]}"; do
  consider_latest "$published"
done

plan_json="$(build_json_array "${plan_items[@]}")"
tags_json="$(build_json_array "${tag_items[@]}")"

# `include` is the documented shape for a dynamic matrix: the workflow passes the
# object straight to `strategy.matrix`, so an empty plan is still a valid (empty)
# matrix instead of a half-built one.
{
  echo "build_matrix={\"include\":$plan_json}"
  echo "release_matrix={\"include\":$tags_json}"
  echo "latest_stable=$latest_stable_tag"
  if [ "${#plan_items[@]}" -eq 0 ]; then
    echo "skip=true"
  else
    echo "skip=false"
  fi
} >> "$GITHUB_OUTPUT"

if [ "${#plan_items[@]}" -eq 0 ]; then
  log "nothing to build"
else
  log "plan: $(printf '%s ' "${plan_items[@]}")"
  log "latest stable release will be: ${latest_stable_tag:-<none>}"
fi
