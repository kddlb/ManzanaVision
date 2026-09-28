#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Builds a signed, notarised and stapled ManzanaVision.app and DMG.
#
#   scripts/release.sh [version]
#
# version defaults to the project's MARKETING_VERSION; the build number is
# the commit count. Needs the Developer ID Application certificate in the
# keychain and a notarytool profile (xcrun notarytool store-credentials):
#
#   TEAM_ID          default 8WHB6LKY28
#   NOTARY_PROFILE   default ManzanaVision-notary
#
# Output: build/release/ManzanaVision-<version>.dmg
set -eu

cd "$(dirname "$0")/.."
TEAM_ID=${TEAM_ID:-8WHB6LKY28}
NOTARY_PROFILE=${NOTARY_PROFILE:-ManzanaVision-notary}
PROJECT=App/ManzanaVision/ManzanaVision.xcodeproj
IDENTITY="Developer ID Application"
OUT=build/release
ARCHIVE=$OUT/ManzanaVision.xcarchive
APP=$OUT/export/ManzanaVision.app

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

VERSION=${1:-$(xcodebuild -project "$PROJECT" -target ManzanaVision -configuration Release -showBuildSettings 2>/dev/null |
    awk '$1 == "MARKETING_VERSION" { print $3 }')}
BUILD=$(git rev-list --count HEAD)
DMG=$OUT/ManzanaVision-$VERSION.dmg
[ -n "$VERSION" ] || fail "can't work out the version"
[ -z "$(git status --porcelain)" ] || echo "warning: the working tree has uncommitted changes" >&2

SIGNER=$(security find-identity -v -p codesigning | sed -n "s/.*\"\($IDENTITY: .*($TEAM_ID)\)\"/\1/p" | head -n 1)
[ -n "$SIGNER" ] || fail "no \"$IDENTITY\" certificate for team $TEAM_ID in the keychain"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "notarytool profile \"$NOTARY_PROFILE\" missing or invalid (xcrun notarytool store-credentials)"

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving $VERSION ($BUILD)"
xcodebuild archive -quiet \
    -project "$PROJECT" -scheme ManzanaVision -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNER" \
    OTHER_CODE_SIGN_FLAGS=--timestamp

step "Exporting"
cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$SIGNER</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"

step "Checking the app"
codesign --verify --deep --strict "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" || fail "hardened runtime is off"
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" || fail "not signed by team $TEAM_ID"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox; then fail "the app is sandboxed"; fi
BIN=$APP/Contents/MacOS/ManzanaVision
[ "$(lipo -archs "$BIN")" = arm64 ] || fail "expected an arm64-only binary, got $(lipo -archs "$BIN")"
if otool -L "$BIN" | grep -E '/opt/homebrew|/usr/local|libusb'; then fail "links a library outside the system"; fi
[ -f "$APP/Contents/Resources/dvb-usb-dib0700-1.20.fw" ] || fail "firmware not bundled"
for f in LICENSE.dib0700 LICENSE.ManzanaVision-GPL-2.0 COPYING.libusb-LGPL-2.1; do
    [ -f "$APP/Contents/Resources/Licenses/$f" ] || fail "licence $f not bundled"
done
echo "signed, hardened, arm64, self-contained, firmware and licences present"

notarise() {
    step "Notarising $(basename "$1")"
    out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
    id=$(printf '%s' "$out" | plutil -extract id raw - 2>/dev/null || true)
    status=$(printf '%s' "$out" | plutil -extract status raw - 2>/dev/null || true)
    echo "submission $id: $status"
    if [ "$status" != Accepted ]; then
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        fail "notarisation failed"
    fi
}

# the app first, so it carries its own ticket once copied out of the DMG
ditto -c -k --keepParent "$APP" "$OUT/ManzanaVision.zip"
notarise "$OUT/ManzanaVision.zip"
xcrun stapler staple -q "$APP"
rm "$OUT/ManzanaVision.zip"

step "Building $(basename "$DMG")"
STAGE=$OUT/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ManzanaVision.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ManzanaVision $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
rm -rf "$STAGE"
codesign --sign "$SIGNER" --timestamp "$DMG"

notarise "$DMG"
xcrun stapler staple -q "$DMG"

step "Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate -q "$APP" && xcrun stapler validate -q "$DMG" && echo "tickets stapled"

step "Done"
shasum -a 256 "$DMG"
