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

swiftc -O \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  Sources/Data.swift Sources/History.swift Sources/IslandView.swift Sources/main.swift \
  -framework AppKit -framework SwiftUI -framework Combine -framework CoreServices \
  -target arm64-apple-macos14.0

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

print_help() {
  cat <<'HELP'
usage — control $APP_NAME from the terminal

USAGE
    usage <command>

COMMANDS
    island     Launch the app (default)
    off        Turn the app off        (aliases: quit, stop)
    restart    Relaunch the app
    version    Print the installed version
    help       Show this help

EXAMPLES
    usage island     # start it
    usage off        # stop it
HELP
}

case "\${1:-island}" in
  island|start|open|"")
    open -a "\$APP" ;;
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
