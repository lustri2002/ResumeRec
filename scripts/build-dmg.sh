#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/ResumeRec.app}"
APP_DIR="${APP_DIR:A}"
PLIST="$APP_DIR/Contents/Info.plist"
[[ -f "$PLIST" ]] || { print -u2 "App bundle not found: $APP_DIR"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
[[ "$VERSION" == <->.<->.<-> ]] || { print -u2 "Unexpected version: $VERSION"; exit 1; }
[[ "$(lipo -archs "$APP_DIR/Contents/MacOS/$EXECUTABLE")" == arm64 ]] || {
    print -u2 "This beta package expects an Apple Silicon build."; exit 1
}
codesign --verify --strict "$APP_DIR"
DESTINATION="${2:-$PROJECT_DIR/dist/ResumeRec-$VERSION-beta-arm64.dmg}"
DESTINATION="${DESTINATION:A}"
[[ ! -e "$DESTINATION" && ! -e "$DESTINATION.sha256" ]] || {
    print -u2 "Output already exists; choose a new destination instead of overwriting it."; exit 1
}
mkdir -p "${DESTINATION:h}"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/ResumeRec-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
chmod 755 "$STAGING"
ditto "$APP_DIR" "$STAGING/ResumeRec.app"
ln -s /Applications "$STAGING/Applications"
cp "$PROJECT_DIR/Resources/Distribution/Read Me.txt" "$STAGING/Read Me.txt"
cp "$PROJECT_DIR/LICENSE" "$STAGING/LICENSE.txt"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING"
codesign --verify --strict "$STAGING/ResumeRec.app"
hdiutil create -volname "ResumeRec $VERSION Beta" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DESTINATION"
hdiutil verify "$DESTINATION"
cd "${DESTINATION:h}"
shasum -a 256 "${DESTINATION:t}" > "${DESTINATION:t}.sha256"
print "DMG: $DESTINATION"
print "SHA-256: $DESTINATION.sha256"
