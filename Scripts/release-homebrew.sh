#!/bin/zsh
# Build the Homebrew distribution of YapToText: a Developer ID signed, notarized,
# models-free .app, zipped and attached to the GitHub release, with the tap's cask
# checksum updated to match.
#
# This is NOT the App Store build. Two deliberate differences:
#   1. Signed with Developer ID Application (not the Mac App Store cert), then notarized,
#      because anything downloaded outside the App Store is blocked by Gatekeeper without it.
#   2. The models are EXCLUDED. With them the bundle is 2.8 GB, which is past GitHub's 2 GB
#      per-asset ceiling; without them it is ~18 MB. The app downloads models on demand and
#      falls back to Apple's speech engine until one is installed.
set -eu

PROJ="/Users/ryleighnewman/Desktop/Apps/YapToText"
TAP="/Users/ryleighnewman/Desktop/Apps/homebrew-yaptotext"
DD="$HOME/Library/Caches/YapToTextDD-Homebrew"
STAGE="$DD/stage"
LOG="/tmp/yap-homebrew.log"
: > "$LOG"

VERSION=$(/usr/bin/grep -m1 "MARKETING_VERSION" "$PROJ/YapToText.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
BUILD=$(/usr/bin/grep -m1 "CURRENT_PROJECT_VERSION" "$PROJ/YapToText.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
TAG="v${VERSION}-${BUILD}"
ZIP="$DD/YapToText-${VERSION}.zip"

DEVID=$(security find-identity -v -p codesigning | /usr/bin/grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$DEVID" ]; then
  echo "FATAL: no 'Developer ID Application' certificate in the keychain." | tee -a "$LOG"
  echo "Create one in Xcode > Settings > Accounts > Manage Certificates > + Developer ID Application," | tee -a "$LOG"
  echo "then re-run. Without it every Homebrew user is blocked by Gatekeeper." | tee -a "$LOG"
  exit 1
fi
echo "signing identity: $DEVID" >> "$LOG"

# 1. Build Release WITHOUT the bundled models.
rm -rf "$DD/Build" "$STAGE"
xcodebuild -project "$PROJ/YapToText.xcodeproj" -scheme YapToText \
  -configuration Release -derivedDataPath "$DD" \
  -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY="$DEVID" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=65JK8K8VGM OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  COMPILATION_CACHE_ENABLE_CACHING=NO >> "$LOG" 2>&1

APP="$DD/Build/Products/Release/YapToText.app"
[ -d "$APP" ] || { echo "FATAL: build produced no app" | tee -a "$LOG"; exit 1; }

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/YapToText.app"
APP="$STAGE/YapToText.app"
rm -rf "$APP/Contents/Resources/Models"          # models are downloaded, not shipped
xattr -cr "$APP"                                  # ITMS-91109 lesson: no stray attributes

# 2. Sign the whole bundle with Developer ID + hardened runtime, WITH the app's entitlements.
#    codesign --force without --entitlements writes an EMPTY entitlement set, and under the
#    hardened runtime that means no microphone (com.apple.security.device.audio-input), no
#    sandbox, no Music control. The first Homebrew release shipped exactly that: a dictation
#    app that could not hear. The repo entitlements file is the right source (the xcodebuild
#    product also carries get-task-allow, which notarization rejects).
ENT="$PROJ/YapToText.entitlements"
[ -f "$ENT" ] || { echo "FATAL: entitlements file missing at $ENT" | tee -a "$LOG"; exit 1; }
codesign --force --deep --timestamp --options=runtime \
  --entitlements "$ENT" --sign "$DEVID" "$APP" >> "$LOG" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP" >> "$LOG" 2>&1
# HARD GATE: never notarize or ship a build that cannot use the microphone.
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input"; then
  echo "FATAL: signed app has no microphone entitlement - refusing to notarize" | tee -a "$LOG"; exit 1
fi

# 3. Notarize, then staple so it works offline and on first launch.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "submitting for notarization (this takes a few minutes)..." | tee -a "$LOG"
xcrun notarytool submit "$ZIP" --keychain-profile "YapToTextNotary" --wait >> "$LOG" 2>&1
xcrun stapler staple "$APP" >> "$LOG" 2>&1
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"           # re-zip WITH the staple

# 4. Verify Gatekeeper would actually let a user open it.
spctl --assess --type execute --verbose=4 "$APP" >> "$LOG" 2>&1 \
  || { echo "FATAL: Gatekeeper would reject this build" | tee -a "$LOG"; exit 1; }

# 5. Attach to the GitHub release and point the cask at it.
gh release upload "$TAG" "$ZIP" --clobber --repo ryleighnewman/YapToText >> "$LOG" 2>&1
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
/usr/bin/sed -i '' "s|^  version .*|  version \"${VERSION}\"|" "$TAP/Casks/yaptotext.rb"
/usr/bin/sed -i '' "s|^  sha256 .*|  sha256 \"${SHA}\"|" "$TAP/Casks/yaptotext.rb"
/usr/bin/sed -i '' "s|releases/download/v#{version}-[0-9]*|releases/download/v#{version}-${BUILD}|" "$TAP/Casks/yaptotext.rb"

echo "DONE  $ZIP" | tee -a "$LOG"
echo "  version $VERSION ($BUILD)   sha256 $SHA" | tee -a "$LOG"
echo "  cask updated: $TAP/Casks/yaptotext.rb" | tee -a "$LOG"
