#!/usr/bin/env bash
# Builds build/TempBar.app. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TempBar"

APP=build/TempBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TempBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable identity keeps Keychain access from re-prompting after every rebuild; fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x TempBar || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/TempBar.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/TempBar.app
    echo "Installed and launched ~/Applications/TempBar.app"
fi
