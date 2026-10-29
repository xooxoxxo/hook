#!/usr/bin/env bash
# Hook's one-line installer: clones (or updates) the repo, checks out the newest
# release and runs scripts/install.sh there.
#   curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash -s -- --local
# Arguments after `bash -s --` go to install.sh unchanged (see scripts/install.sh --help).
# The clone goes to the repo ~/.local/bin/relay already links into, else to
# ${HOOK_DIR:-~/.local/share/hook}. A folder that is not a clone of Hook, or one with
# local changes, is never touched.
# Test-only switch, used by scripts/test-get.sh and nothing else:
#   HOOK_REPO_URL  the repo to clone instead of GitHub's (a local bare repo)
#
# Everything runs inside main, called on the last line: a download cut short runs nothing.

main() {
  set -euo pipefail

  local url="${HOOK_REPO_URL:-https://github.com/xooxoxxo/hook.git}"

  die() { echo "get: $*" >&2; exit 1; }

  # github.com/xooxoxxo/hook or xooxoxxo/relay (the name before the rename), over
  # https or ssh, as the in-app updater accepts it; or the URL this run clones.
  is_ours() {
    local origin
    origin="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    origin="${origin%/}"
    origin="${origin%.git}"
    case "$origin" in
      https://github.com/xooxoxxo/hook|https://github.com/xooxoxxo/relay) return 0 ;;
      ssh://git@github.com/xooxoxxo/hook|ssh://git@github.com/xooxoxxo/relay) return 0 ;;
      git@github.com:xooxoxxo/hook|git@github.com:xooxoxxo/relay) return 0 ;;
    esac
    [ "$1" = "$url" ]
  }

  # --- checks --------------------------------------------------------------------

  [ "$(uname -s)" = "Darwin" ] || die "Hook runs on macOS only"
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "the Xcode Command Line Tools are missing. The installer has started; when it finishes, run this command again."
  fi
  command -v git >/dev/null 2>&1 || die "git not found; install the Command Line Tools: xcode-select --install"
  command -v python3 >/dev/null 2>&1 || die "python3 not found; install the Command Line Tools: xcode-select --install"

  # --- where: the existing install's repo, else HOOK_DIR ---------------------------
  # install.sh links ~/.local/bin/relay to <repo>/bin/relay.

  local dir="" link="$HOME/.local/bin/relay" target
  if [ -L "$link" ]; then
    target="$(readlink "$link")"
    case "$target" in
      /*/bin/relay)
        target="${target%/bin/relay}"
        if [ -f "$target/scripts/install.sh" ]; then dir="$target"; fi ;;
    esac
  fi
  [ -n "$dir" ] || dir="${HOOK_DIR:-$HOME/.local/share/hook}"

  # --- clone, or check and fetch the clone that is there ---------------------------

  if [ ! -e "$dir" ] || { [ -d "$dir" ] && [ -z "$(ls -A "$dir")" ]; }; then
    mkdir -p "$(dirname "$dir")"
    echo "get: cloning $url into $dir"
    git clone --quiet "$url" "$dir" || die "git clone $url failed"
  else
    [ -d "$dir/.git" ] || die "$dir is not a clone of Hook; left alone. Move it, or set HOOK_DIR to another folder"
    local origin
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    is_ours "$origin" || die "$dir is not a clone of Hook (origin: ${origin:-none}); left alone. Move it, or set HOOK_DIR to another folder"
    local changes
    changes="$(git -C "$dir" status --porcelain)" || die "git couldn't read $dir"
    [ -z "$changes" ] || die "$dir has local changes; left alone. Commit or stash them (git -C \"$dir\" status), then run this again"
    echo "get: updating $dir"
    git -C "$dir" fetch --quiet --tags --force origin || die "git fetch in $dir failed"
  fi

  # --- the newest release: vX.Y.Z, highest by version ------------------------------

  local tag
  tag="$(git -C "$dir" tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n 1p || true)"
  [ -n "$tag" ] || die "$dir has no release tag (vX.Y.Z)"
  git -C "$dir" -c advice.detachedHead=false checkout --quiet "$tag" || die "git checkout $tag in $dir failed"
  echo "get: $dir is at $tag"

  cd "$dir"
  exec ./scripts/install.sh "$@"
}

main "$@"
