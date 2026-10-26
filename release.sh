#!/bin/bash
# Build + package + publish pathcop. One command, no Xcode GUI.
#
#   ./release.sh              build and package DMGs only
#   ./release.sh --publish    also commit, tag, push, and create the GitHub release
#
# Needs: Command Line Tools, and for --publish a working `gh auth login`.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.3"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

# The version lives in three places; a mismatch ships a DMG that lies about
# what it is, so refuse to build until they agree.
echo "==> version check"
for f in Sources/App/Info.plist Sources/Ext/Info.plist; do
  got=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$f")
  if [ "$got" != "$VERSION" ]; then
    echo "    $f says $got, expected $VERSION" >&2
    exit 1
  fi
done
if ! grep -q "releases/download/${VERSION}/" README.md; then
  echo "    README.md does not link to ${VERSION}" >&2
  exit 1
fi
echo "    ok, $VERSION"

echo "==> build (arm64 + x86_64)"
./build-split.sh

# Package each app into a DMG with the usual drag-to-Applications target.
# Hidden files (.DS_Store, stray xattrs) are excluded or Finder shows junk.
package() {
  local app=$1 out=$2
  echo "==> dmg ${out}"
  local stage
  stage=$(mktemp -d)
  cp -R "${app}" "${stage}/pathcop.app"
  ln -s /Applications "${stage}/Applications"
  rm -f "${out}"
  hdiutil create -volname "pathcop" -srcfolder "${stage}" \
    -fs HFS+ -format UDZO -ov -quiet "${out}"
  rm -rf "${stage}"
  du -h "${out}"
  # Unsigned-by-Apple apps must be Gatekeeper-stripped by the user; verify the
  # ad-hoc signature survived packaging so the DMG isn't dead on arrival.
  local mnt
  mnt=$(mktemp -d)
  hdiutil attach "${out}" -mountpoint "${mnt}" -nobrowse -quiet
  if codesign -v "${mnt}/pathcop.app" 2>/dev/null; then
    echo "    signature ok"
  else
    echo "    WARNING: signature check failed" >&2
  fi
  lipo -info "${mnt}/pathcop.app/Contents/MacOS/pathcop"
  lipo -info "${mnt}/pathcop.app/Contents/PlugIns/pathcop.appex/Contents/MacOS/pathext"
  hdiutil detach "${mnt}" -quiet
  rmdir "${mnt}"
}

package pathcop-arm.app   "pathcop-${VERSION}-arm64.dmg"
package pathcop-intel.app "pathcop-${VERSION}-intel.dmg"

echo "==> done"
ls -lh "pathcop-${VERSION}-arm64.dmg" "pathcop-${VERSION}-intel.dmg"

if [ "$PUBLISH" -eq 0 ]; then
  cat <<EOF

Built only. To publish:
  ./release.sh --publish

Or manually:
  git add -A && git commit -m "menu inside external volumes, v${VERSION}"
  git tag ${VERSION} && git push origin main --tags
  gh release create ${VERSION} \\
    "pathcop-${VERSION}-arm64.dmg" "pathcop-${VERSION}-intel.dmg" \\
    --title "${VERSION}" --notes-file CHANGELOG-${VERSION}.md
EOF
  exit 0
fi

echo "==> commit + tag"
git add -A
git commit -m "menu inside external volumes, v${VERSION}" || echo "    (nothing to commit)"
# Re-tagging over an existing tag would silently ship the wrong commit.
if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
  echo "    tag ${VERSION} already exists" >&2
  exit 1
fi
git tag "${VERSION}"
git push origin main
git push origin "${VERSION}"

echo "==> github release"
gh release create "${VERSION}" \
  "pathcop-${VERSION}-arm64.dmg" "pathcop-${VERSION}-intel.dmg" \
  --title "${VERSION}" --notes-file "CHANGELOG-${VERSION}.md"

echo "==> released"
gh release view "${VERSION}"
