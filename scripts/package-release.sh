#!/usr/bin/env bash
# Packs a release from a built Hook.app:
#   <out>/Hook-<version>.zip  Hook.app, and support/ (the CLI, clients, MCP server, skill,
#                             schema, integration bundle and installer that
#                             ~/.local/share/hook/<version> holds), copied from the app's
#                             Contents/Resources/support, where build.sh puts it
#   <out>/Hook-<version>.dmg  with --dmg: Hook.app and a link to /Applications to drag it to
#   <out>/SHA256SUMS          the zip's (and the DMG's) SHA-256, as `shasum -a 256` prints them
#   scripts/package-release.sh [--app <Hook.app>] [--out <dir>] [--dmg]
#   scripts/package-release.sh --sums [--out <dir>]
#                             only rewrites SHA256SUMS for the zip and DMG in <out>: the
#                             release workflow runs it once the DMG is signed, notarized and
#                             stapled, which changes its bytes
# --app defaults to ./build/Hook.app (build it with BUILD_ONLY=1 scripts/build.sh), --out to ./dist.
# The version is the app's CFBundleShortVersionString, which must match Resources/Info.plist
# and, when RELEASE_TAG is set (the release workflow sets it), the tag vX.Y.Z.
# This script signs nothing: build.sh signs the app before it is packed, and the release
# workflow signs the DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUNDLE_ID="io.github.xooxoxxo.relay"

die() { echo "package: $*" >&2; exit 1; }

app="$ROOT/build/Hook.app"
out="$ROOT/dist"
dmg=0
sums_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || die "--app needs a path"; app="$2"; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a folder"; out="$2"; shift ;;
    --dmg) dmg=1 ;;
    --sums) sums_only=1 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

version="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version $version is not X.Y.Z"
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
  die "tag $RELEASE_TAG does not match the version in Resources/Info.plist (v$version)"
fi
zip="Hook-$version.zip"
image="Hook-$version.dmg"

# write_sums <dir>: SHA256SUMS with the zip's line, then the DMG's when there is one.
# get.sh and Hook's updater read only the zip's line.
write_sums() {
  [ -f "$1/$zip" ] || die "no $1/$zip to list in SHA256SUMS"
  local files=("$zip")
  [ ! -f "$1/$image" ] || files+=("$image")
  (cd "$1" && shasum -a 256 "${files[@]}" > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS)
}

if [ "$sums_only" -eq 1 ]; then
  [ -d "$out" ] || die "$out is not a folder"
  write_sums "$out"
  echo "package: $out/SHA256SUMS ($(wc -l < "$out/SHA256SUMS" | tr -d ' ') files)"
  exit 0
fi

# --app and --out may be relative to the folder this runs in; the zip is written from
# inside the staging folder, so both become absolute.
[ -d "$app" ] || die "$app is not an app (no such folder)"
app="$(cd "$app" && pwd -P)"

[ -f "$app/Contents/Info.plist" ] || die "$app is not an app (no Contents/Info.plist)"
id="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$id" = "$BUNDLE_ID" ] || die "$app is not Hook (bundle id ${id:-none})"
app_version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$app_version" = "$version" ] || die "$app is ${app_version:-unversioned}, but Resources/Info.plist says $version; rebuild it"
# The payload is sealed into the app (build.sh). The zip carries a copy of it beside the app,
# where get.sh, and the updater of every earlier Hook, look for it.
bundled="$app/Contents/Resources/support"
[ -f "$bundled/scripts/install.sh" ] \
  || die "$app has no support payload in Contents/Resources/support; rebuild it with scripts/build.sh"
[ "$(cat "$bundled/VERSION" 2>/dev/null)" = "$version" ] \
  || die "$app's support payload is $(cat "$bundled/VERSION" 2>/dev/null || echo unversioned), not $version; rebuild it"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/zip" "$stage/dmg"
# ditto keeps the app's signature intact (zip would drop extended attributes).
ditto "$bundled" "$stage/zip/support"
ditto "$app" "$stage/zip/Hook.app"

mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
rm -f "$out/$zip" "$out/$image" "$out/SHA256SUMS"
(cd "$stage/zip" && ditto -c -k --norsrc . "$out/$zip")
echo "package: $out/$zip"

if [ "$dmg" -eq 1 ]; then
  command -v hdiutil >/dev/null 2>&1 || die "--dmg needs hdiutil (macOS)"
  ditto "$app" "$stage/dmg/Hook.app"
  ln -s /Applications "$stage/dmg/Applications"
  # hdiutil create can fail with "Resource busy" on a busy runner; it gets two more tries.
  made=0
  for _ in 1 2 3; do
    if hdiutil create -quiet -volname "Hook $version" -srcfolder "$stage/dmg" -fs HFS+ \
        -format UDZO -imagekey zlib-level=9 -ov "$out/$image"; then
      made=1
      break
    fi
    sleep 2
  done
  [ "$made" -eq 1 ] || die "hdiutil could not create $image"
  echo "package: $out/$image"
fi

write_sums "$out"
echo "package: $out/SHA256SUMS ($(cut -c1-12 "$out/SHA256SUMS" | tr '\n' ' ' | sed 's/ $//'))"
