#!/usr/bin/env bash
# fetch-build.sh <app> <android|ios> — make sure the build simulate.sh installs is at its path. With manifest.json
# "store": "release" it is downloaded from this repo's `builds` release and checked against the manifest's sha256.
# Runs on the macOS runner before Homebrew bash is installed, so it stays bash 3.2 compatible.
set -euo pipefail

APP="${1:?app}"
PLATFORM="${2:?platform}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/manifest.json"

build="$(jq -c --arg a "$APP" --arg p "$PLATFORM" '.apps[$a].platforms[$p] // empty' "$MANIFEST")"
[[ -n "$build" ]] || { echo "manifest.json has no $PLATFORM build for $APP" >&2; exit 1; }
artifact="$(jq -r .artifact <<< "$build")"

if [[ "$(jq -r '.store // "repo"' "$MANIFEST")" != "release" ]]; then
  echo "using $artifact from the repo"
  exit 0
fi

asset="$(jq -r '.release_asset // empty' <<< "$build")"
[[ -n "$asset" ]] || { echo "manifest.json has no release_asset for $APP $PLATFORM: publish with make mo-sync-push" >&2; exit 1; }
mkdir -p "$REPO/$(dirname "$artifact")"
gh release download builds --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}" --pattern "$asset" --output "$REPO/$artifact" --clobber
# shasum ships on both runner images; sha256sum is missing on macOS.
echo "$(jq -r .sha256 <<< "$build")  $REPO/$artifact" | shasum -a 256 -c - > /dev/null \
  || { echo "$asset does not match the sha256 in manifest.json" >&2; exit 1; }
echo "downloaded $asset -> $artifact"
