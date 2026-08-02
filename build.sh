#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Token Usage Island"
BUNDLE_ID="com.pierre.tokenusageisland"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
BIN_NAME="TokenUsageIsland"

# Version: explicit $VERSION, else the latest git tag (v1.2.3 -> 1.2.3), else a dev marker.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0-dev}"

echo "▸ Building $APP_NAME $VERSION"
echo "▸ Compiling…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary. The notch UI needs an Apple Silicon MacBook, but the app is
# supposed to run on any Mac from macOS 14 — on a display without a notch it falls
# back to a floating card below the menu bar. An arm64-only build made that promise
# untrue for Intel Macs, which couldn't launch it at all. Each slice is compiled
# separately and lipo'd, because swiftc emits one architecture per invocation.
#
# Two binaries come out of this. The island is the app; `usage-status` is the same
# readings without a GUI, and it is compiled from the core WITHOUT Store.swift or
# anything under Sources/App. That list is the point: if the fetch layer ever grows a
# SwiftUI or AppKit dependency, the CLI target stops building, so the separation that
# makes a port possible is enforced here rather than trusted.
PORTABLE=(Sources/Core/Models.swift Sources/Core/Platform.swift Sources/Core/Fetchers.swift)
CORE=("${PORTABLE[@]}" Sources/Core/Store.swift)
APP_SOURCES=("${CORE[@]}" Sources/App/Appearance.swift Sources/App/IslandView.swift Sources/App/main.swift)
CLI_SOURCES=("${PORTABLE[@]}" Sources/CLI/main.swift)
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework Combine -framework CoreServices)
ARCHS=(arm64 x86_64)
CLI_NAME="usage-status"

# Compile one target for every arch and lipo the slices together.
# $1 output path · $2 name for the temp slices · rest: swiftc arguments
build_universal() {
  local out="$1" tag="$2"; shift 2
  local slices=() arch
  for arch in "${ARCHS[@]}"; do
    swiftc -O -o "$BUILD_DIR/$tag-$arch" "$@" -target "$arch-apple-macos14.0"
    slices+=("$BUILD_DIR/$tag-$arch")
  done
  lipo -create "${slices[@]}" -output "$out"
  rm -f "${slices[@]}"
  echo "  · $tag: $(lipo -archs "$out")"
}

build_universal "$APP/Contents/MacOS/$BIN_NAME" "$BIN_NAME" "${APP_SOURCES[@]}" "${FRAMEWORKS[@]}"
build_universal "$APP/Contents/MacOS/$CLI_NAME" "$CLI_NAME" "${CLI_SOURCES[@]}"

echo "▸ Copying resources…"
cp Resources/* "$APP/Contents/Resources/"

echo "▸ Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The `usage` CLI ships INSIDE the bundle so the Homebrew cask can symlink it
# onto PATH at install time (see the `binary` stanza in the cask formula).
# Users then run: `usage island` to launch, plus quit/version/help subcommands.
echo "▸ Embedding CLI launcher…"
cat > "$APP/Contents/Resources/usage" <<LAUNCH
#!/bin/bash
# CLI launcher for $APP_NAME. Installed on PATH as \`usage\`.
APP="$APP_NAME"

# Resolve this script through any symlinks — Homebrew links it onto PATH — so the
# sibling binaries inside the bundle can be found wherever the app is installed,
# rather than assuming /Applications.
SRC="\${BASH_SOURCE[0]}"
while [ -L "\$SRC" ]; do
  LDIR="\$(cd -P "\$(dirname "\$SRC")" && pwd)"
  SRC="\$(readlink "\$SRC")"
  case "\$SRC" in /*) ;; *) SRC="\$LDIR/\$SRC" ;; esac
done
RES_DIR="\$(cd -P "\$(dirname "\$SRC")" && pwd)"
STATUS_BIN="\$RES_DIR/../MacOS/usage-status"

print_help() {
  cat <<'HELP'
usage — control $APP_NAME from the terminal

USAGE
    usage <command>

COMMANDS
    island     Launch the app (default)
    status     Print usage in the terminal, no GUI  (--watch, --json)
    off        Turn the app off        (aliases: quit, stop)
    restart    Relaunch the app
    version    Print the installed version
    help       Show this help

EXAMPLES
    usage island          # start it
    usage status          # read the numbers here in the terminal
    usage status --watch  # keep them updating
    usage off             # stop it
HELP
}

case "\${1:-island}" in
  status|stat)
    # Headless read of the same three providers. Runs whether or not the app is up —
    # it reads the same files and endpoint, it just prints instead of drawing.
    shift
    if [ ! -x "\$STATUS_BIN" ]; then
      echo "usage: status helper not found at \$STATUS_BIN" >&2
      exit 1
    fi
    exec "\$STATUS_BIN" "\$@" ;;
  island|start|open|"")
    # -g: launch WITHOUT foreground-activating. The app lives in the notch and never
    # wants app focus; activating it makes WindowServer flash the Spaces bar on launch.
    open -g -a "\$APP" ;;
  quit|stop|off)
    # Graceful quit, then force-kill any survivor. osascript can return 0 without
    # actually quitting an app that only just launched, so we always mop up.
    osascript -e "quit app \"\$APP\"" >/dev/null 2>&1
    sleep 1
    pkill -x "$BIN_NAME" 2>/dev/null
    exit 0 ;;
  restart)
    osascript -e "quit app \"\$APP\"" >/dev/null 2>&1
    sleep 1
    pkill -x "$BIN_NAME" 2>/dev/null
    sleep 1
    open -a "\$APP" ;;
  version|-v|--version)
    defaults read "/Applications/\$APP.app/Contents/Info" CFBundleShortVersionString 2>/dev/null \\
      || echo "unknown" ;;
  help|-h|--help)
    print_help ;;
  *)
    echo "usage: unknown command '\$1'" >&2
    echo "Run 'usage help' to see available commands." >&2
    exit 1 ;;
esac
LAUNCH
chmod +x "$APP/Contents/Resources/usage"

# zsh tab-completion for the \`usage\` command. Ships in the bundle; `install`
# copies it into Homebrew's site-functions dir (already on fpath).
echo "▸ Embedding zsh completion…"
cat > "$APP/Contents/Resources/_usage" <<'COMPLETION'
#compdef usage
local -a cmds
cmds=(
  'island:Launch the app'
  'status:Print usage in the terminal'
  'off:Turn the app off'
  'restart:Relaunch the app'
  'version:Print the installed version'
  'help:Show this help'
)
_describe 'command' cmds
COMPLETION

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built: $APP ($VERSION)"

# `./build.sh install` — copy into /Applications and symlink the bundled CLI on PATH.
if [ "${1:-}" = "install" ]; then
  CMD_NAME="${CMD_NAME:-usage}"
  # Pick a PATH dir we can write to (Apple Silicon brew, then Intel brew).
  for d in /opt/homebrew/bin /usr/local/bin; do
    [ -d "$d" ] && [ -w "$d" ] && BIN_DIR="$d" && break
  done
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$BIN_DIR"

  echo "▸ Installing app to /Applications…"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"

  # Symlink the bundled launcher so updates propagate automatically.
  echo "▸ Linking CLI: $BIN_DIR/$CMD_NAME → the app bundle"
  ln -sf "/Applications/$APP_NAME.app/Contents/Resources/usage" "$BIN_DIR/$CMD_NAME"
  # Clean up the old single-word launcher from earlier installs.
  [ -f "$BIN_DIR/island" ] && rm -f "$BIN_DIR/island"

  # Install zsh tab-completion into Homebrew's site-functions (already on fpath).
  if command -v brew >/dev/null 2>&1; then
    COMPDIR="$(brew --prefix)/share/zsh/site-functions"
    if mkdir -p "$COMPDIR" 2>/dev/null && [ -w "$COMPDIR" ]; then
      ln -sf "/Applications/$APP_NAME.app/Contents/Resources/_usage" "$COMPDIR/_usage"
      echo "▸ Installed zsh completion → $COMPDIR/_usage"
      echo "  (open a new terminal, or run 'autoload -Uz compinit && compinit' to enable now)"
    fi
  fi

  echo "✓ Installed. Run '$CMD_NAME island' from anywhere."
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "⚠ $BIN_DIR is not on your PATH — add it to ~/.zshrc:"
       echo "    export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
fi
