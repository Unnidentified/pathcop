#!/bin/bash
# Split-arch builds for pathcop. Leaves build.sh and all sources alone.
# arm64 floor 11.0 = first macOS on Apple Silicon. x86_64 floor 11.0 =
# Big Sur runs Intel Macs back to 2013, and 11.0 is the lowest version
# with SF Symbols, which the code uses. Older would need fallbacks.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)

build_one() {
  ARCH=$1     # arm64 | x86_64
  MINVER=$2   # 11.0
  OUT=$3      # pathcop-arm.app | pathcop-intel.app
  TARGET="${ARCH}-apple-macos${MINVER}"
  echo "==> ${ARCH} (macOS ${MINVER}+) -> ${OUT}"
  rm -rf "build-${ARCH}" "${OUT}"
  mkdir -p "build-${ARCH}" "build-${ARCH}/src"

  # Workaround without touching the user's sources: the checked-in
  # main.swift targets a newer SDK, so patch the availability guards
  # for the macOS 11 build copies.
  cp Sources/Ext/FinderSync.swift "build-${ARCH}/src/"
  python3 - "build-${ARCH}/src/main.swift" Sources/App/main.swift <<'PYEOF'
import sys
out_path, in_path = sys.argv[1], sys.argv[2]
text = open(in_path).read()
text = text.replace(
    'if #available(macOS 13.0, *) {',
    'if #unavailable(macOS 13.0) {',
    1,  # isLoginItem only
)
open(out_path, 'w').write(text)
PYEOF

  swiftc -target "$TARGET" -sdk "$SDK" -O -parse-as-library -module-name pathcopExtension \
    -emit-object -o "build-${ARCH}/FinderSync.o" \
    "build-${ARCH}/src/FinderSync.swift"

  clang -target "$TARGET" -isysroot "$SDK" -O2 -c \
    -o "build-${ARCH}/extmain.o" Sources/Ext/main.m

  swiftc -target "$TARGET" -sdk "$SDK" -O \
    -o "build-${ARCH}/pathext" \
    "build-${ARCH}/FinderSync.o" "build-${ARCH}/extmain.o" \
    -framework Cocoa -framework FinderSync

  swiftc -target "$TARGET" -sdk "$SDK" -O -module-name pathcop \
    -o "build-${ARCH}/pathcop" \
    "build-${ARCH}/src/main.swift" \
    -framework Cocoa -framework ServiceManagement

  mkdir -p "${OUT}/Contents/MacOS"
  mkdir -p "${OUT}/Contents/PlugIns/pathcop.appex/Contents/MacOS"
  mkdir -p "${OUT}/Contents/PlugIns/pathcop.appex/Contents/Resources"
  mkdir -p "${OUT}/Contents/Resources"
  cp "build-${ARCH}/pathcop" "${OUT}/Contents/MacOS/"
  cp "build-${ARCH}/pathext" "${OUT}/Contents/PlugIns/pathcop.appex/Contents/MacOS/pathext"
  cp Sources/Ext/Info.plist "${OUT}/Contents/PlugIns/pathcop.appex/Contents/Info.plist"
  cp Sources/App/Info.plist "${OUT}/Contents/Info.plist"
  cp Resources/AppIcon.icns "${OUT}/Contents/Resources/"
  printf 'APPL????' > "${OUT}/Contents/PkgInfo"

  codesign -s - -f --entitlements "$(pwd)/Resources/ext.entitlements" "${OUT}/Contents/PlugIns/pathcop.appex"
  codesign -s - -f "${OUT}"

  lipo -info "${OUT}/Contents/MacOS/pathcop" "${OUT}/Contents/PlugIns/pathcop.appex/Contents/MacOS/pathext"
  du -sh "${OUT}"
}

build_one arm64 11.0 pathcop-arm.app
build_one x86_64 11.0 pathcop-intel.app
echo "DONE"
