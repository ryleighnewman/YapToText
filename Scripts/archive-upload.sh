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
ARCHIVE="$DD/YapToText-1.2-8.xcarchive"
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

if grep -q "ARCHIVE SUCCEEDED" "$ALOG"; then
  plutil -p "$ARCHIVE/Info.plist" | grep -E "ShortVersion|BundleVersion" >> "$ALOG"
  du -sh "$ARCHIVE/Products/Applications/YapToText.app/Contents/Resources/Models" >> "$ALOG" 2>&1
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$PROJ/Marketing/tools/exportOptions.plist" \
    -allowProvisioningUpdates > "$ULOG" 2>&1
  echo "UPLOAD-EXIT=$?" >> "$ULOG"
else
  echo "ARCHIVE FAILED - upload skipped" >> "$ALOG"
fi
