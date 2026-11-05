#!/bin/bash
# Compiles the app icon's source, Resources/AppIcon.icon (an Icon Composer document: icon.json and
# the full-bleed 1024 px art in Assets/), into Resources/Assets.car, which is committed.
# Needs Xcode 26 or later: older actool can't read a .icon. CI and the release workflow use the
# committed Assets.car, so run this only after changing the .icon, and commit both.
#
# What the app ships (scripts/build.sh copies both into Contents/Resources):
#   Assets.car    Info.plist's CFBundleIconName. It holds the layered icon that macOS 26 and later
#                 mask to their own shape, and the flat, rounded images that actool renders from it
#                 for macOS 14 and 15, which read the same catalog.
#   AppIcon.icns  Info.plist's CFBundleIconFile: the rounded 824 px tile on the pre-26 grid, with a
#                 flat version at 16 and 32 px. For anything that reads the .icns directly. This
#                 script leaves it alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ICON="$ROOT/Resources/AppIcon.icon"
OUT="$ROOT/Resources/Assets.car"

die() { echo "app-icon: $*" >&2; exit 1; }

[ -f "$ICON/icon.json" ] || die "no $ICON/icon.json"
version="$(xcrun actool --version 2>/dev/null | plutil -extract com\\.apple\\.actool\\.version.short-bundle-version raw - 2>/dev/null || true)"
[ -n "$version" ] || die "no actool (install Xcode 26 or later)"
[ "${version%%.*}" -ge 26 ] || die "actool $version can't compile a .icon; it needs Xcode 26 or later"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out"
# Absolute paths only: actool hands the work to a long-lived agent that resolves relative paths
# against its own folder. dyld noise from that agent goes to stderr; the results go to the log.
xcrun actool "$ICON" --compile "$T/out" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$T/out/partial.plist" \
  --output-format human-readable-text --errors --warnings --notices >"$T/log" 2>/dev/null \
  || { cat "$T/log" >&2; die "actool failed"; }
if grep -qE '(error|warning):' "$T/log"; then cat "$T/log" >&2; die "actool reported problems"; fi
[ -f "$T/out/Assets.car" ] || { cat "$T/log" >&2; die "actool wrote no Assets.car"; }
[ "$(plutil -extract CFBundleIconName raw "$T/out/partial.plist")" = AppIcon ] \
  || die "the compiled catalog doesn't name AppIcon as the app icon"
# The layered icon macOS 26 reads, and the flat images macOS 14 and 15 read.
LC_ALL=C grep -qa 'AppIcon.iconstack' "$T/out/Assets.car" || die "Assets.car has no layered icon"
assetutil --info "$T/out/Assets.car" 2>/dev/null | grep -q '"AssetType" : "Icon Image"' \
  || die "Assets.car has no flat icon images for macOS 14 and 15"
cp "$T/out/Assets.car" "$OUT"
echo "app-icon: wrote $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' ')) with actool $version"
