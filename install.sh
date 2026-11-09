#!/bin/bash
# Installs LabelIt, the newest release, into Applications:
#
#   curl -fsSL https://raw.githubusercontent.com/arifamir/labelit/main/install.sh | bash
#
# Uninstall:   curl -fsSL https://raw.githubusercontent.com/arifamir/labelit/main/install.sh | bash -s -- --uninstall
#
# What it does: downloads LabelIt.zip from the latest GitHub release, checks it against the release's SHA-256, puts
# LabelIt.app in /Applications (or ~/Applications when /Applications isn't writable), and opens it. Nothing else on
# the Mac changes. Read it before you run it: it's short.
#
# For testing: LABELIT_DOWNLOAD_URL (the zip; its .sha256 beside it), LABELIT_INSTALL_DIR, LABELIT_NO_OPEN=1.
set -euo pipefail

# Everything runs from main, called on the last line: a download cut short never runs half a script.
main() {
  local repo="${LABELIT_REPO:-arifamir/labelit}"
  local url="${LABELIT_DOWNLOAD_URL:-https://github.com/$repo/releases/latest/download/LabelIt.zip}"
  local bundle_id="com.kodberry.labelit"

  say() { printf '\033[1m%s\033[0m\n' "$*"; }
  fail() { printf '\033[31mLabelIt installer: %s\033[0m\n' "$*" >&2; exit 1; }

  [[ "$(uname -s)" == Darwin ]] || fail "LabelIt is a Mac app. On Linux, build it from source: see the README."
  [[ "$(uname -m)" == arm64 ]] || fail "LabelIt needs a Mac with Apple Silicon (M1 or later)."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 26 )) || fail "LabelIt needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

  local dir="${LABELIT_INSTALL_DIR:-/Applications}"
  if [[ -z "${LABELIT_INSTALL_DIR:-}" && ! -w /Applications ]]; then
    dir="$HOME/Applications"
  fi

  if [[ "${1:-}" == "--uninstall" ]]; then
    quit_running "$bundle_id" "$dir"
    rm -rf "$dir/LabelIt.app"
    say "LabelIt is uninstalled. Renamed files keep their names."
    echo "To remove its history, settings and model download as well:"
    echo "  rm -rf ~/Library/Application\\ Support/LabelIt && defaults delete $bundle_id && tccutil reset All $bundle_id"
    return
  fi

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expanded now: $work is local and gone by the time the trap runs
  trap "rm -rf '$work'" EXIT

  say "Downloading LabelIt…"
  curl -fL --progress-bar "$url" -o "$work/LabelIt.zip" || fail "couldn't download $url"
  curl -fsSL "$url.sha256" -o "$work/LabelIt.zip.sha256" || fail "couldn't download the checksum ($url.sha256)"
  local expected actual
  expected="$(awk '{print $1}' "$work/LabelIt.zip.sha256")"
  actual="$(shasum -a 256 "$work/LabelIt.zip" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || fail "the download doesn't match its checksum; nothing was installed"

  ditto -x -k "$work/LabelIt.zip" "$work/unpacked"
  [[ -d "$work/unpacked/LabelIt.app" ]] || fail "the download doesn't contain LabelIt.app"
  codesign --verify --deep --strict "$work/unpacked/LabelIt.app" 2>/dev/null \
    || fail "LabelIt.app's signature doesn't check out; nothing was installed"

  quit_running "$bundle_id" "$dir"
  mkdir -p "$dir"
  rm -rf "$dir/LabelIt.app"
  ditto "$work/unpacked/LabelIt.app" "$dir/LabelIt.app"
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dir/LabelIt.app/Contents/Info.plist" 2>/dev/null || echo "")"
  say "Installed LabelIt ${version} in $dir."

  if [[ -z "${LABELIT_NO_OPEN:-}" ]]; then
    open "$dir/LabelIt.app"
    echo "LabelIt is in your menu bar (a tag icon near the clock). A welcome window walks you through the rest."
  fi
}

# Quits LabelIt when the copy that's running is the one about to be replaced, and waits for it to finish
# (it frees its model before quitting).
quit_running() {
  local bundle_id="$1" dir="$2" pid path
  for pid in $(pgrep -x LabelIt || true); do
    path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    if [[ "$path" == "$dir/LabelIt.app/"* ]]; then
      osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    fi
  done
}

main "$@"
