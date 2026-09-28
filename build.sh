#!/bin/bash
# Tiny FinderSync "Copy Path" builder. No Xcode required, just Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="com.gefaass.pathcop"
EXT_ID="com.gefaass.pathcop.ext"
SDK=$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
TARGET="arm64-apple-macos13.0"

rm -rf build pathcop.app
mkdir -p build pathcop.app/Contents/MacOS pathcop.app/Contents/PlugIns

echo "==> extension"
swiftc -target "$TARGET" -sdk "$SDK" -O -parse-as-library -module-name pathcopExtension \
  -emit-object -o build/FinderSync.o \
  Sources/Ext/FinderSync.swift

clang -target arm64-apple-macos13.0 -isysroot "$SDK" -O2 -c \
  -o build/extmain.o Sources/Ext/main.m

swiftc -target "$TARGET" -sdk "$SDK" -O \
  -o build/pathext \
  build/FinderSync.o build/extmain.o \
  -framework Cocoa -framework FinderSync

echo "==> host app"
swiftc -target "$TARGET" -sdk "$SDK" -O -module-name pathcop \
  -o build/pathcop \
  Sources/App/main.swift \
  -framework Cocoa -framework ServiceManagement

echo "==> bundle"
mkdir -p pathcop.app/Contents/PlugIns/pathcop.appex/Contents/MacOS
mkdir -p pathcop.app/Contents/PlugIns/pathcop.appex/Contents/Resources
mkdir -p pathcop.app/Contents/Resources
cp build/pathcop pathcop.app/Contents/MacOS/
cp build/pathext pathcop.app/Contents/PlugIns/pathcop.appex/Contents/MacOS/pathext
cp Sources/Ext/Info.plist pathcop.app/Contents/PlugIns/pathcop.appex/Contents/Info.plist
cp Sources/App/Info.plist pathcop.app/Contents/Info.plist
cp Resources/AppIcon.icns pathcop.app/Contents/Resources/
cp PkgInfo pathcop.app/Contents/ 2>/dev/null || printf 'APPL????' > pathcop.app/Contents/PkgInfo

codesign -s - -f --entitlements "$(pwd)/Resources/ext.entitlements" pathcop.app/Contents/PlugIns/pathcop.appex
codesign -s - -f pathcop.app

du -sh pathcop.app
echo "OK -> ./pathcop.app"
echo "Install: cp -R pathcop.app /Applications/ && open /Applications/pathcop.app"
echo "Then: System Settings > General > Login Items & Extensions > Finder Extensions > enable pathcop"
echo "Then: killall Finder"
