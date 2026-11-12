#!/usr/bin/env bash
# Shared version helpers for the wrapper scripts.
#
# Versions here are upstream tags without the leading `v`:
#   MAJOR.MINOR.PATCH            stable
#   MAJOR.MINOR.PATCH-preview.N  preview (sorts before the matching stable)
#
# `semver_key` prints a fixed-width string. Comparing two keys with `[[ a > b ]]`
# therefore gives semantic ordering for arbitrary numbers of digits, which a
# plain string sort of the versions does not.

semver_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$ ]]
}

semver_is_stable() {
  case "$1" in
    *-preview.*) return 1 ;;
    *) return 0 ;;
  esac
}

semver_key() {
  local version="$1"
  local core="${1%%-*}"
  local stage=2 preview=0 major minor patch
  if [ "$core" != "$version" ]; then
    stage=1
    preview="${version##*.}"
    case "$preview" in
      '' | *[!0-9]*) preview=0 ;;
    esac
  fi
  local IFS=.
  # shellcheck disable=SC2086
  set -- $core
  # `10#` keeps printf from reading a leading zero as octal (014 -> 12).
  major=$((10#$1))
  minor=$((10#$2))
  patch=$((10#$3))
  preview=$((10#$preview))
  printf '%08d%08d%08d%01d%08d' "$major" "$minor" "$patch" "$stage" "$preview"
}
