#!/bin/zsh
# Builds an unsigned build/ClipStack.ipa for iPhone and iPad (iOS 17+), for signing elsewhere.
# Needs full Xcode (the Command Line Tools have no iOS SDK):
#   sudo xcode-select -s /Applications/Xcode.app
# iCloud sync: if the signing profile includes the container iCloud.com.omid.clipstack, build with
#   CLOUDKIT=1 ./build-ios.sh
# so the app turns sync on (it can't read its own entitlements, and CloudKit traps without them).
set -euo pipefail
cd "$(dirname "$0")"

# Use Xcode even if xcode-select still points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) || {
  echo "No iOS SDK found. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
}

OUT=build/ios
APP=$OUT/Payload/ClipStack.app
rm -rf "$OUT" && mkdir -p "$APP"

xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target arm64-apple-ios17.0 \
  Sources/Shared/*.swift Sources/iOS/*.swift \
  -o "$APP/ClipStack"

cp iOS/Info.plist "$APP/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Info.plist"
if [[ -n "${CLOUDKIT:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :ClipStackCloudKitContainer string iCloud.com.omid.clipstack" "$APP/Info.plist"
fi

# Compile the icon into Assets.car and merge the icon keys actool reports into Info.plist.
xcrun actool iOS/Assets.xcassets --compile "$APP" --platform iphoneos --minimum-deployment-target 17.0 \
  --app-icon AppIcon --target-device iphone --target-device ipad \
  --output-partial-info-plist "$OUT/assets.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Merge $OUT/assets.plist" "$APP/Info.plist"

# Platform keys some installers and signing services check for.
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
/usr/libexec/PlistBuddy \
  -c "Add :DTPlatformName string iphoneos" \
  -c "Add :DTPlatformVersion string $SDK_VERSION" \
  -c "Add :DTSDKName string iphoneos$SDK_VERSION" \
  "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"

IPA=build/ClipStack-$VERSION.ipa
rm -f "$IPA"
(cd "$OUT" && zip -qry "../ClipStack-$VERSION.ipa" Payload)
echo "Built $IPA (unsigned)"
