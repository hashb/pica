#!/usr/bin/env bash
# Builds Pica.app into ./build. Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Pica.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pica" "$APP/Contents/MacOS/Pica"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so macOS remembers folder-access permissions between launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app will still run)"

echo "Built $APP"
echo "Run it with:  open $APP     (or copy it to /Applications)"
