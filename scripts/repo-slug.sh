#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# repo-slug.sh --name|--owner [ROOT] - the repository this tree is checked out
# as. The ONE definition: scripts/is-template-tree.sh and
# scripts/check-identity-matches-repo.sh both ask it.
#
#   --name    print the repository name.
#   --owner   print the owner, or print nothing and exit 1 when it is unknown.
#
# ROOT defaults to ".". Source, first that applies:
#   1. $GITHUB_REPOSITORY, when set and non-empty: owner is the part before
#      the first "/", name the part after the last "/". A value with no "/"
#      names a repository and no owner.
#   2. `git -C ROOT remote get-url origin`, a trailing "/" and ".git" stripped:
#      name is the last path segment. The owner is the segment just before the
#      name, and only when the URL is a forge URL: scheme://[user@]host[:port]/
#      .../owner/name, or scp-like [user@]host:owner/name. A path-like origin
#      (/abs, ./rel, ../rel, ~, file://) has no owner: the directory holding a
#      local bare repository is not one.
#   3. The basename of ROOT's absolute directory. Its owner is unknown.
#
# Exit: 0 printed; 1 --owner and the owner is unknown (nothing printed);
# 2 usage error, ROOT is not a directory, or no name can be found.
set -u

usage() { echo "usage: repo-slug.sh --name|--owner [ROOT]" >&2; exit 2; }
if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage; fi
mode="$1"
case "$mode" in --name|--owner) ;; *) usage ;; esac
root="${2:-.}"
[ -d "$root" ] || { echo "repo-slug.sh: not a directory: $root" >&2; exit 2; }

name=""; owner=""
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  name="${GITHUB_REPOSITORY##*/}"
  case "$GITHUB_REPOSITORY" in */*) owner="${GITHUB_REPOSITORY%%/*}" ;; esac
elif url="$(git -C "$root" remote get-url origin 2>/dev/null)" && [ -n "$url" ]; then
  url="${url%/}"; url="${url%.git}"
  path=""; forge=0
  case "$url" in
    /*|./*|../*|'~'*|file://*) path="$url" ;;
    *://*)
      rest="${url#*://}"
      case "$rest" in */*) path="${rest#*/}"; forge=1 ;; *) path="" ;; esac ;;
    *:*)
      # scp-like host:path, where no "/" comes before the ":".
      case "${url%%:*}" in */*) path="$url" ;; *) path="${url#*:}"; forge=1 ;; esac ;;
    *) path="$url" ;;
  esac
  name="${path##*/}"
  if [ "$forge" = 1 ]; then
    parent="${path%/*}"
    # With no "/" in the path there is a name and no owner.
    case "$path" in */*) owner="${parent##*/}" ;; esac
  fi
else
  name="$(basename "$(cd "$root" && pwd)")"
fi

[ -n "$name" ] || { echo "repo-slug.sh: cannot determine the repository name for $root" >&2; exit 2; }
if [ "$mode" = --name ]; then
  printf '%s\n' "$name"
else
  [ -n "$owner" ] || exit 1
  printf '%s\n' "$owner"
fi
