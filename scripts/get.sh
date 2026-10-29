#!/usr/bin/env bash
# Hook's one-line installer: downloads the newest release (Hook-<version>.zip and its
# SHA256SUMS) with curl, checks the hash, and installs it. No git, no compiler.
#   curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash -s -- --local
# Arguments after `bash -s --` go to install.sh unchanged (see scripts/install.sh --help).
#
# Where things go: the release's support payload (CLI, clients, MCP server, skill and
# installer) and its Hook.app to ~/.local/share/hook/<version>, with
# ~/.local/share/hook/current linking to it. Then current/scripts/install.sh --prebuilt
# copies Hook.app to ~/Applications and does the rest. Once that succeeds, the version
# before is kept, for going back, and older ones are removed. When it fails, current
# links to the version before again and nothing is removed.
#
# Never touched: a developer's clone (one with changes, a local branch other than main,
# HOOK_DEV=1, or one the config records as a developer's, "updateMode": "developer"; HOOK_DEV=0
# ignores that record) that ~/.local/bin/relay links into. A clone of Hook at
# ~/.local/share/hook itself (0.9.3's get.sh put one there) is moved to
# ~/.local/share/hook-clone, and left for you to delete.
#
# Environment:
#   HOOK_VERSION=X.Y.Z  install that release instead of the newest
#   HOOK_ZIP, HOOK_SUMS with HOOK_VERSION: install from these downloaded files instead
#                       (Hook's updater does this; the hash is checked all the same)
# Test-only switch, used by scripts/test-get.sh and nothing else:
#   HOOK_RELEASES_URL   the releases base instead of https://github.com/xooxoxxo/hook/releases
#                       (a file:// folder or a local http server laid out the same way)
#
# Exit status 3: nothing was changed (a download, the hash or the zip failed), so a
# caller can fall back. Everything runs inside main, called on the last line: a
# download cut short runs nothing.

main() {
  set -euo pipefail

  local base="${HOOK_RELEASES_URL:-https://github.com/xooxoxxo/hook/releases}"
  base="${base%/}"
  local hook_home="$HOME/.local/share/hook"
  local bundle_id="io.github.xooxoxxo.relay"
  local version="${HOOK_VERSION:-}"
  version="${version#v}"

  die() { echo "get: $*" >&2; exit 1; }
  unchanged() { echo "get: $*" >&2; exit 3; }
  # shellcheck disable=SC2088  # a literal ~ for messages
  tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
  is_version() { printf '%s' "$1" | grep -Eq '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'; }

  # A developer's clone is never moved or relinked: HOOK_DEV=1, the clone a developer's
  # install recorded in the config (updateMode "developer", repoPath naming it; HOOK_DEV=0
  # ignores it), changes that aren't committed, or a local branch other than main.
  # Without the Command Line Tools git can't run, and nobody develops in that clone.
  local config="$HOME/.config/relay/config.json"
  dev_clone() {
    [ -e "$1/.git" ] || return 1
    [ "${HOOK_DEV:-0}" = "1" ] && return 0
    if [ "${HOOK_DEV:-}" != "0" ] && [ -f "$config" ] \
      && [ "$(plutil -extract updateMode raw -o - "$config" 2>/dev/null)" = "developer" ]; then
      local recorded
      recorded="$(plutil -extract repoPath raw -o - "$config" 2>/dev/null || true)"
      if [ -n "$recorded" ] && [ "$(cd "$recorded" 2>/dev/null && pwd -P)" = "$(cd "$1" 2>/dev/null && pwd -P)" ]; then
        return 0
      fi
    fi
    xcode-select -p >/dev/null 2>&1 || return 1
    local changes branch
    changes="$(git -C "$1" status --porcelain 2>/dev/null)" || return 0
    [ -z "$changes" ] || return 0
    for branch in $(git -C "$1" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null); do
      [ "$branch" = "main" ] || return 0
    done
    return 1
  }

  fetch() {   # fetch <url> <file>: https only once redirected (GitHub sends downloads elsewhere)
    curl -q -fsSL --retry 2 --proto-redir '=https' -o "$2" "$1"
  }

  # --- checks --------------------------------------------------------------------

  [ "$(uname -s)" = "Darwin" ] || die "Hook runs on macOS only"
  local macos
  macos="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  [ "${macos%%.*}" -ge 14 ] 2>/dev/null || die "Hook needs macOS 14 or newer (this Mac has $macos)"
  local tool
  for tool in curl shasum ditto; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found; it comes with macOS"
  done
  if [ -n "$version" ]; then is_version "$version" || die "HOOK_VERSION must be X.Y.Z, not $version"; fi
  if [ -n "${HOOK_ZIP:-}" ] || [ -n "${HOOK_SUMS:-}" ]; then
    [ -n "${HOOK_ZIP:-}" ] && [ -n "${HOOK_SUMS:-}" ] && [ -n "$version" ] \
      || die "HOOK_ZIP and HOOK_SUMS need each other and HOOK_VERSION"
  fi

  # An install from a developer's clone stays one; it updates with git pull there.
  local link="$HOME/.local/bin/relay" target
  if [ -L "$link" ]; then
    target="$(readlink "$link")"
    case "$target" in
      /*/bin/relay)
        target="${target%/bin/relay}"
        if dev_clone "$target"; then
          die "$(tilde "$link") links into the developer clone $(tilde "$target"); left alone. Update it there (git pull && ./scripts/install.sh), or remove the link to switch to the release build"
        fi ;;
    esac
  fi
  if [ -e "$hook_home/.git" ] && dev_clone "$hook_home"; then
    die "$(tilde "$hook_home") is a developer clone; left alone. Move it, then run this again"
  fi

  # --- download and check, before anything changes ----------------------------------

  mkdir -p "$HOME/.local/share"
  local work
  work="$(mktemp -d "$HOME/.local/share/.hook-incoming.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT

  local sums="$work/SHA256SUMS" zip
  if [ -n "${HOOK_ZIP:-}" ]; then
    cp "$HOOK_SUMS" "$sums" || unchanged "can't read $HOOK_SUMS"
  else
    local sums_url="$base/latest/download/SHA256SUMS"
    [ -z "$version" ] || sums_url="$base/download/v$version/SHA256SUMS"
    fetch "$sums_url" "$sums" || unchanged "couldn't download $sums_url"
  fi
  # SHA256SUMS lines read "<sha256>  Hook-X.Y.Z.zip"; the zip's name gives the version.
  local listed
  listed="$(grep -E '^[0-9a-f]{64}  Hook-[0-9]+\.[0-9]+\.[0-9]+\.zip$' "$sums" || true)"
  if [ -z "$version" ]; then
    [ "$(printf '%s\n' "$listed" | grep -c .)" = "1" ] || unchanged "the newest release's SHA256SUMS doesn't name one Hook zip"
    version="$(printf '%s' "$listed" | sed -E 's/.*  Hook-(.*)\.zip$/\1/')"
    is_version "$version" || unchanged "the newest release's SHA256SUMS names Hook-$version.zip"
  fi
  zip="Hook-$version.zip"
  local expected
  expected="$(printf '%s\n' "$listed" | awk -v name="$zip" '$2 == name { print $1; exit }')"
  [ -n "$expected" ] || unchanged "SHA256SUMS has no line for $zip"

  if [ -n "${HOOK_ZIP:-}" ]; then
    cp "$HOOK_ZIP" "$work/$zip" || unchanged "can't read $HOOK_ZIP"
  else
    echo "get: downloading Hook $version"
    fetch "$base/download/v$version/$zip" "$work/$zip" || unchanged "couldn't download $base/download/v$version/$zip"
  fi
  local actual
  actual="$(shasum -a 256 "$work/$zip" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || unchanged "$zip does not match SHA256SUMS (got $actual); refused. Nothing was changed"
  echo "get: $zip matches SHA256SUMS"

  mkdir -p "$work/x"
  ditto -x -k "$work/$zip" "$work/x" || unchanged "couldn't unpack $zip"
  local app="$work/x/Hook.app" support="$work/x/support" id app_version
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$id" = "$bundle_id" ] || unchanged "$zip holds no Hook.app (bundle id ${id:-none})"
  [ "$app_version" = "$version" ] || unchanged "$zip holds Hook ${app_version:-?}, not $version"
  [ -f "$support/scripts/install.sh" ] && [ "$(cat "$support/VERSION" 2>/dev/null)" = "$version" ] \
    || unchanged "$zip has no support payload for $version"

  # --- put it in place ----------------------------------------------------------------

  # 0.9.3's get.sh cloned Hook to ~/.local/share/hook; it moves aside, unchanged.
  if [ -e "$hook_home/.git" ]; then
    local aside="$hook_home-clone"
    [ ! -e "$aside" ] || aside="$hook_home-clone-$(date +%Y%m%d-%H%M%S)"
    mv "$hook_home" "$aside"
    echo "get: moved the old clone $(tilde "$hook_home") to $(tilde "$aside")"
    echo "get: the old copy in $(tilde "$aside") is no longer used; you can delete it"
  fi
  [ ! -e "$hook_home" ] || [ -d "$hook_home" ] || die "$(tilde "$hook_home") is not a folder; left alone. Move it, then run this again"
  mkdir -p "$hook_home"

  # The version to go back to: the one current links to, unless that is this version
  # (a retry, or a rerun) or gone; then the newest other version here.
  local dest="$hook_home/$version" previous="" entry name
  if [ -L "$hook_home/current" ]; then
    previous="$(readlink "$hook_home/current")"
    previous="${previous%/}"
    previous="${previous##*/}"
  fi
  if [ "$previous" = "$version" ] || ! is_version "$previous" || [ ! -d "$hook_home/$previous" ] || [ -L "$hook_home/$previous" ]; then
    previous="$(
      for entry in "$hook_home"/*; do
        name="${entry##*/}"
        if [ -d "$entry" ] && [ ! -L "$entry" ] && is_version "$name" && [ "$name" != "$version" ]; then echo "$name"; fi
      done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
    )"
  fi
  if [ -e "$dest" ]; then mv "$dest" "$work/replaced"; fi   # the same version again: a fresh copy
  mv "$support" "$dest"
  mv "$app" "$dest/Hook.app"
  ln -sfn "$version" "$hook_home/current"
  echo "get: $(tilde "$hook_home/current") -> $version"

  local status=0
  "$hook_home/current/scripts/install.sh" --prebuilt "$@" || status=$?
  if [ "$status" -ne 0 ]; then
    # current goes back to the version that worked; nothing is removed.
    if [ -n "$previous" ]; then
      ln -sfn "$previous" "$hook_home/current"
      echo "get: installing Hook $version failed; $(tilde "$hook_home/current") links to $previous again (the CLI, MCP server and skill use it)" >&2
      echo "get: to put Hook $previous's app back too, run: '$hook_home/current/scripts/install.sh' --prebuilt" >&2
    else
      echo "get: installing Hook $version failed, and there is no earlier version here to go back to" >&2
    fi
    return "$status"
  fi

  # Only now that it installed: keep this version and the one before; remove older ones.
  # Anything else stays.
  for entry in "$hook_home"/*; do
    name="${entry##*/}"
    if [ ! -d "$entry" ] || [ -L "$entry" ] || ! is_version "$name"; then continue; fi
    if [ "$name" = "$version" ] || [ "$name" = "$previous" ]; then continue; fi
    rm -rf "$entry"
    echo "get: removed Hook $name"
  done
}

main "$@"
