#!/bin/bash
# Builds build/Relinquish.app with the Command Line Tools (no Xcode needed).
#   ./build.sh            build only
#   ./build.sh test       build and run the self-test (fake Library in a temp folder)
#   ./build.sh install    build, copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Relinquish.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    src/*.swift \
    -o "$APP/Contents/MacOS/Relinquish"
cp Info.plist "$APP/Contents/"
if [ ! -f design/AppIcon.icns ]; then
    [ -x design/make_icon.sh ] && design/make_icon.sh || { echo "design/AppIcon.icns is missing" >&2; exit 1; }
fi
cp design/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
    test)
        "$APP/Contents/MacOS/Relinquish" --selftest
        ;;
    install)
        pkill -x Relinquish 2>/dev/null || true
        mkdir -p ~/Applications
        rm -rf ~/Applications/Relinquish.app
        cp -R "$APP" ~/Applications/
        open ~/Applications/Relinquish.app
        echo "Installed ~/Applications/Relinquish.app"
        ;;
esac
