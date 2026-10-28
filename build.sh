#!/bin/zsh
# Builds ClipStack.app (universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClipStack.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework CoreData -framework CryptoKit -framework ImageIO -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework CoreImage \
    Sources/*.swift -o build/ClipStack-$arch
done
lipo -create build/ClipStack-arm64 build/ClipStack-x86_64 -output "$APP/Contents/MacOS/ClipStack"
rm build/ClipStack-arm64 build/ClipStack-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# iCloud sync needs an Apple Developer signing identity plus a provisioning profile for
# com.omid.clipstack with the iCloud (CloudKit) and Push Notifications capabilities:
#   SIGN_IDENTITY="Apple Development: You (XXXXXXXXXX)" PROFILE=~/Downloads/ClipStack.provisionprofile ./build.sh
# Without them the app is signed ad-hoc and runs local-only.
if [[ -n "${SIGN_IDENTITY:-}" && -n "${PROFILE:-}" ]]; then
  TEAM_ID=$(security cms -D -i "$PROFILE" | plutil -extract TeamIdentifier.0 raw -)
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  sed "s/TEAM_ID/$TEAM_ID/g" ClipStack.entitlements.template > build/ClipStack.entitlements
  codesign --force --options runtime --entitlements build/ClipStack.entitlements --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with iCloud entitlements (team $TEAM_ID)"
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Developer ID without a profile: distributable and notarizable, but local-only.
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -c icnC "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE"
DMG=build/ClipStack-$VERSION.dmg
hdiutil create -volname "ClipStack $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Notarize when a Developer ID build has a stored notarytool profile:
#   xcrun notarytool store-credentials clipstack --apple-id you@example.com --team-id TEAMID
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=clipstack ./build.sh
if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "Built $DMG"
