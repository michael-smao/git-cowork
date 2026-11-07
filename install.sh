#!/bin/bash
# Installs or updates git-cowork from the newest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/michael-smao/git-cowork/main/install.sh | bash
#
# No Xcode or Swift needed. Downloading with curl (not a browser) means macOS
# doesn't quarantine the app, so it opens without a Gatekeeper warning.
#
# Optional settings (environment variables):
#   GIT_COWORK_VERSION=0.2.0       a specific release instead of the newest
#   GIT_COWORK_PREFIX=~/Applications  where the app goes (default: /Applications
#                                  if you can write there, else ~/Applications)
#   GIT_COWORK_BINDIR=~/bin        where `git cowork` is linked (default ~/.local/bin)
#   GIT_COWORK_REPO=owner/name     install from a fork
set -euo pipefail

say() { printf '%s\n' "$*"; }
fail() { printf 'git-cowork install: %s\n' "$*" >&2; exit 1; }

# Everything runs from main, called on the last line: if the download of
# this script stops halfway (curl | bash), nothing runs at all.
main() {
  local REPO="${GIT_COWORK_REPO:-michael-smao/git-cowork}"
  # For testing against a local copy of the release files.
  local DOWNLOADS="${GIT_COWORK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
  local API="${GIT_COWORK_API_BASE:-https://api.github.com/repos/$REPO}"
  local BINDIR="${GIT_COWORK_BINDIR:-$HOME/.local/bin}"

  [ "$(uname -s)" = "Darwin" ] || fail "git-cowork is a Mac app."
  [ "$(uname -m)" = "arm64" ] || fail "this build needs an Apple Silicon Mac."
  local MACOS_MAJOR
  MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$MACOS_MAJOR" -ge 14 ] || fail "needs macOS 14 Sonoma or newer (you have $(sw_vers -productVersion))."

  # Which version: the one asked for, or the newest release.
  local VERSION="${GIT_COWORK_VERSION:-}"
  if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "$API/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)" || true
    [ -n "$VERSION" ] || fail "couldn't find the newest release of $REPO."
  fi
  VERSION="${VERSION#v}"
  # It becomes part of URLs and file names, so only plain versions.
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "\"$VERSION\" isn't a version number like 1.2.3."

  # Where the app goes.
  local PREFIX="${GIT_COWORK_PREFIX:-}"
  if [ -z "$PREFIX" ]; then
    if [ -w /Applications ]; then PREFIX=/Applications; else PREFIX="$HOME/Applications"; fi
  fi
  mkdir -p "$PREFIX" 2>/dev/null || fail "couldn't create $PREFIX. Install somewhere you can write: GIT_COWORK_PREFIX=~/Applications"
  local APP="$PREFIX/git-cowork.app"
  # Replacing the app means writing in $PREFIX and moving the old app (an
  # app installed by an admin or another user can't be moved).
  if [ ! -w "$PREFIX" ] || { [ -e "$APP" ] && [ ! -w "$APP" ]; }; then
    fail "can't write to $APP (it may belong to another user). Install into your own folder instead: GIT_COWORK_PREFIX=~/Applications"
  fi

  local ZIP="git-cowork-$VERSION-macos-arm64.zip"
  local WORK
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-cowork-install.XXXXXX")"
  # Next to the app, so the swap is a rename on the same volume.
  local NEW="$PREFIX/.git-cowork.app.new" OLD="$PREFIX/.git-cowork.app.old"
  # On any exit before the swap is done: drop the partial copy, put the old
  # app back if it was moved aside, and clean up the downloads.
  CLEANUP_WORK="$WORK" CLEANUP_NEW="$NEW" CLEANUP_OLD="$OLD" CLEANUP_APP="$APP"
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  say "→ Downloading git-cowork $VERSION"
  curl -fSL --progress-bar -o "$WORK/$ZIP" "$DOWNLOADS/v$VERSION/$ZIP" || fail "download failed: $DOWNLOADS/v$VERSION/$ZIP"
  curl -fsSL -o "$WORK/$ZIP.sha256" "$DOWNLOADS/v$VERSION/$ZIP.sha256" || fail "checksum download failed."
  (cd "$WORK" && shasum -a 256 -c "$ZIP.sha256" >/dev/null 2>&1) || fail "checksum doesn't match; the download is damaged. Try again."

  ditto -x -k "$WORK/$ZIP" "$WORK/unpacked" || fail "couldn't unpack the download."
  [ -d "$WORK/unpacked/git-cowork.app" ] || fail "the download doesn't contain git-cowork.app."
  codesign --verify "$WORK/unpacked/git-cowork.app" 2>/dev/null || fail "the app's signature doesn't verify."
  # curl doesn't quarantine downloads; clear it anyway in case the zip came another way.
  xattr -dr com.apple.quarantine "$WORK/unpacked/git-cowork.app" 2>/dev/null || true

  # Swap in the new app: copy it next to the old one first, then two renames.
  # Until the last rename the old app stays where it is.
  rm -rf "$NEW" "$OLD"
  ditto "$WORK/unpacked/git-cowork.app" "$NEW" || fail "couldn't write to $PREFIX. Install somewhere you can write: GIT_COWORK_PREFIX=~/Applications"
  if [ -e "$APP" ]; then
    say "→ Replacing $APP"
    mv "$APP" "$OLD" || fail "couldn't move the old $APP aside. Quit git-cowork, or install with GIT_COWORK_PREFIX=~/Applications"
  else
    say "→ Installing to $APP"
  fi
  mv "$NEW" "$APP" || fail "couldn't put the new app in place."
  CLEANUP_OLD=""   # done: the old app is not restored any more
  rm -rf "$OLD"

  # `git cowork` on the PATH.
  mkdir -p "$BINDIR"
  ln -sf "$APP/Contents/Helpers/git-cowork" "$BINDIR/git-cowork"

  say "✓ git-cowork $VERSION installed in $APP"
  say "✓ git cowork linked in $BINDIR"
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) say "  To use \`git cowork\` in Terminal, add $BINDIR to your PATH:"
       say "    echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc" ;;
  esac
  if ! xcode-select -p >/dev/null 2>&1; then
    say "  git-cowork needs git. Install Apple's command line tools:  xcode-select --install"
  fi
  if pgrep -xq GitCowork; then
    say "  git-cowork is running; quit and reopen it to use the new version."
  fi
}

CLEANUP_WORK="" CLEANUP_NEW="" CLEANUP_OLD="" CLEANUP_APP=""
cleanup() {
  [ -n "$CLEANUP_NEW" ] && rm -rf "$CLEANUP_NEW"
  if [ -n "$CLEANUP_OLD" ] && [ -d "$CLEANUP_OLD" ]; then
    # Moved aside but the new app never arrived: put the old one back.
    if [ -e "$CLEANUP_APP" ]; then rm -rf "$CLEANUP_OLD"; else mv "$CLEANUP_OLD" "$CLEANUP_APP"; fi
  fi
  [ -n "$CLEANUP_WORK" ] && rm -rf "$CLEANUP_WORK"
  return 0
}

main "$@"
