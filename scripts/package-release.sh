#!/usr/bin/env bash
# Packs a release from a built Hook.app:
#   <out>/Hook-<version>.zip  Hook.app, and support/ (the CLI, clients, MCP server, skill,
#                             schema and installer that ~/.local/share/hook/<version> holds)
#   <out>/SHA256SUMS          the zip's SHA-256, as `shasum -a 256` prints it
#   scripts/package-release.sh [--app <Hook.app>] [--out <dir>]
# --app defaults to ./build/Hook.app (build it with BUILD_ONLY=1 scripts/build.sh), --out to ./dist.
# The version is the app's CFBundleShortVersionString, which must match Resources/Info.plist
# and, when RELEASE_TAG is set (the release workflow sets it), the tag vX.Y.Z.
# This script signs nothing: build.sh signs the app before it is packed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUNDLE_ID="io.github.xooxoxxo.relay"

die() { echo "package: $*" >&2; exit 1; }

app="$ROOT/build/Hook.app"
out="$ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || die "--app needs a path"; app="$2"; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a folder"; out="$2"; shift ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
# --app and --out may be relative to the folder this runs in; the zip is written from
# inside the staging folder, so both become absolute.
[ -d "$app" ] || die "$app is not an app (no such folder)"
app="$(cd "$app" && pwd -P)"

[ -f "$app/Contents/Info.plist" ] || die "$app is not an app (no Contents/Info.plist)"
id="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$id" = "$BUNDLE_ID" ] || die "$app is not Hook (bundle id ${id:-none})"
version="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
app_version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$app_version" = "$version" ] || die "$app is ${app_version:-unversioned}, but Resources/Info.plist says $version; rebuild it"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version $version is not X.Y.Z"
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
  die "tag $RELEASE_TAG does not match the version in Resources/Info.plist (v$version)"
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
S="$stage/support"
mkdir -p "$S/bin" "$S/clients" "$S/mcp" "$S/schema" "$S/scripts" "$S/docs" "$S/skill"

# The payload: what the CLI, the MCP server, the skill, the app's Connect tab and the
# installer read. Tests, fixtures and caches stay out.
cp "$ROOT/bin/relay" "$S/bin/relay"
for f in "$ROOT"/clients/*.py; do
  case "${f##*/}" in test_*|answers_fixture.py) continue ;; esac
  cp "$f" "$S/clients/"
done
cp "$ROOT/mcp/relay_mcp.py" "$S/mcp/"
cp "$ROOT"/schema/*.json "$S/schema/"
ditto --norsrc "$ROOT/skill/instructables" "$S/skill/instructables"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/get.sh" "$S/scripts/"
cp "$ROOT/docs/claude-md-section.md" "$S/docs/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$S/"
printf '%s\n' "$version" > "$S/VERSION"
find "$S" \( -name '.DS_Store' -o -name '__pycache__' -o -name '*.pyc' \) -prune -exec rm -rf {} +
chmod 755 "$S/bin/relay" "$S/scripts/install.sh" "$S/scripts/get.sh"

# ditto keeps the app's signature intact (zip would drop extended attributes).
ditto "$app" "$stage/Hook.app"

mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
zip="Hook-$version.zip"
rm -f "$out/$zip" "$out/SHA256SUMS"
(cd "$stage" && ditto -c -k --norsrc . "$out/$zip")
(cd "$out" && shasum -a 256 "$zip" > SHA256SUMS)
echo "package: $out/$zip"
echo "package: $out/SHA256SUMS ($(cut -c1-12 "$out/SHA256SUMS")…)"
