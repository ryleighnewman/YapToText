#!/bin/zsh
# Archive for the App Store and upload, with the SAME wedge cure build-open.sh uses.
#
# The Xcode 26 wedge: SWBBuildService's `clang -v -E -dM` probe blocks writing to a pipe
# the service never drains; both sit in mach_msg forever and the archive never starts
# compiling. A healthy probe exits in <1s, so any probe alive >10s is stuck. Killing JUST
# the probe hands the service EOF and the build proceeds. Never kill xcodebuild or
# SWBBuildService themselves - that only loses the work in flight.
set -u
PROJ="/Users/ryleighnewman/Desktop/Apps/YapToText"
DD="$HOME/Library/Caches/YapToTextDD-Release"
VER=$(/usr/bin/grep -m1 "MARKETING_VERSION" "$PROJ/YapToText.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
BLD=$(/usr/bin/grep -m1 "CURRENT_PROJECT_VERSION" "$PROJ/YapToText.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
ARCHIVE="$DD/YapToText-$VER-$BLD.xcarchive"
ALOG="/tmp/yap-archive7c.log"
ULOG="/tmp/yap-upload7.log"

# Wedge PREVENTION: keep the compilation-cache (CAS) layer out of the build entirely.
rm -rf "$DD/CompilationCache.noindex" 2>/dev/null
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex" 2>/dev/null
rm -rf "$ARCHIVE" 2>/dev/null
: > "$ALOG"

xcodebuild archive -project "$PROJ/YapToText.xcodeproj" -scheme YapToText \
  -configuration Release -archivePath "$ARCHIVE" -derivedDataPath "$DD" \
  -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM=65JK8K8VGM -allowProvisioningUpdates \
  COMPILATION_CACHE_ENABLE_CACHING=NO >> "$ALOG" 2>&1 &
BPID=$!

# THE WEDGE CURE, running for the life of the archive.
while kill -0 $BPID 2>/dev/null; do
  sleep 15
  for pid in $(pgrep -f "clang -v -E -dM"); do
    ET=$(ps -o etime= -p "$pid" | tr -d ' ')
    case "$ET" in ??:*|?:??) kill -9 "$pid" 2>/dev/null && echo "unstuck a wedged clang probe (pid $pid)" >> "$ALOG";; esac
  done
done
wait $BPID 2>/dev/null
echo "ARCHIVE-EXIT=$?" >> "$ALOG"

MODELS="$ARCHIVE/Products/Applications/YapToText.app/Contents/Resources/Models"
if grep -q "ARCHIVE SUCCEEDED" "$ALOG" \
   && [ -f "$MODELS/ggml-large-v3-turbo-q5_0.bin" ] \
   && [ ! -f "$MODELS/ggml-large-v3-turbo.bin" ] \
   && [ -z "$(xattr -r "$ARCHIVE/Products/Applications/YapToText.app" 2>/dev/null)" ]; then
  plutil -p "$ARCHIVE/Info.plist" | grep -E "ShortVersion|BundleVersion" >> "$ALOG"
  du -sh "$ARCHIVE/Products/Applications/YapToText.app/Contents/Resources/Models" >> "$ALOG" 2>&1
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$PROJ/Marketing/tools/exportOptions.plist" \
    -allowProvisioningUpdates > "$ULOG" 2>&1
  echo "UPLOAD-EXIT=$?" >> "$ULOG"
else
  echo "ARCHIVE FAILED, WRONG MODELS, OR EXTENDED ATTRIBUTES PRESENT - upload skipped" >> "$ALOG"
  xattr -r "$ARCHIVE/Products/Applications/YapToText.app" 2>/dev/null | head >> "$ALOG"
  ls -la "$MODELS" >> "$ALOG" 2>&1
fi

# A successful App Store upload is only step 1 of 3. Say so LOUDLY here, at the exact
# moment the release feels finished, because this is where Homebrew gets forgotten.
if grep -q "UPLOAD-EXIT=0" "$ULOG" 2>/dev/null; then
  VER=$(/usr/bin/grep -m1 "MARKETING_VERSION" "$PROJ/YapToText.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
  BLD=$(/usr/bin/grep -m1 "CURRENT_PROJECT_VERSION" "$PROJ/YapToText.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
  echo ""
  echo "=============================================================="
  echo " App Store upload done: $VER ($BLD).  TWO STEPS REMAIN."
  echo ""
  echo "   2. GitHub    git tag v$VER-$BLD, push, gh release create"
  echo "   3. Homebrew  ./Scripts/release-homebrew.sh, then push the tap"
  echo ""
  echo " Full procedure: Scripts/RELEASE.md"
  echo "=============================================================="
fi
