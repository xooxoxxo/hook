#!/usr/bin/env bash
# Assembles Hook's support payload: the CLI, clients, MCP server, skill, schema, integration
# bundle and installer that ~/.local/share/hook/<version> holds.
#   scripts/bundle-support.sh <dest> [--version X.Y.Z]
# <dest> must not exist yet. --version defaults to Resources/Info.plist's.
# build.sh puts it in Hook.app at Contents/Resources/support, so it is signed and notarized
# with the app; package-release.sh copies it from there into the release zip as support/.
# Nothing in it is Mach-O: codesign seals it as the app's resources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

die() { echo "bundle-support: $*" >&2; exit 1; }

dest=""
version="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs X.Y.Z"; version="$2"; shift ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$dest" ] || die "one destination only"; dest="$1" ;;
  esac
  shift
done
[ -n "$dest" ] || die "usage: scripts/bundle-support.sh <dest> [--version X.Y.Z]"
[ ! -e "$dest" ] || die "$dest already exists"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version $version is not X.Y.Z"

S="$dest"
mkdir -p "$S/bin" "$S/clients" "$S/mcp" "$S/schema" "$S/scripts" "$S/skill"

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
# The integration bundle (instructions, the versioned skill, plugin and file templates and
# the harness table) that `relay integrations` installs into every agent harness.
python3 "$ROOT/clients/relay_bundle.py" build --version "$version" --out "$S/integration" >/dev/null \
  || die "the integration bundle did not build"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/get.sh" "$S/scripts/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$S/"
printf '%s\n' "$version" > "$S/VERSION"
find "$S" \( -name '.DS_Store' -o -name '__pycache__' -o -name '*.pyc' \) -prune -exec rm -rf {} +
chmod 755 "$S/bin/relay" "$S/scripts/install.sh" "$S/scripts/get.sh"
# Symlinks would break the app's signature (and the integration bundle refuses them); extended
# attributes are "detritus" codesign refuses to sign over.
if find "$S" -type l | grep -q .; then die "symlinks in the payload: $(find "$S" -type l | head -3)"; fi
xattr -cr "$S"
