#!/bin/zsh
# Clears the Xcode build-service wedge WITHOUT restarting the Mac.
#
# Root cause of the wedge: a killed/overlapped build leaves stale SwiftPM lock files and
# clang module caches in the PER-BOOT directories under /var/folders. Ordinary cache
# clearing (DerivedData, ~/Library/Caches/org.swift.swiftpm) never touched these, which is
# why only a reboot "fixed" it - a reboot wipes /var/folders. This script removes exactly
# that state by hand.
set -u

echo "1/4 Killing build processes..."
pkill -9 -x XCBBuildService xcodebuild swift-frontend SourceKitService swift-build swift-package clang 2>/dev/null
sleep 1

TMP="$(getconf DARWIN_USER_TEMP_DIR)"
CACHE="$(getconf DARWIN_USER_CACHE_DIR)"

echo "2/4 Removing stale SwiftPM locks + xcrun db in $TMP..."
rm -f "$TMP"/_*swiftpm*.lock "$TMP"/_*manifest.db.lock "$TMP"/xcrun_db 2>/dev/null

echo "3/4 Removing per-boot clang/Xcode caches in $CACHE..."
rm -rf "$CACHE/org.llvm.clang" "$CACHE/clang" "$CACHE/com.apple.dt.Xcode" 2>/dev/null

echo "4/4 Removing SwiftPM caches + build DB..."
rm -rf "$HOME/Library/Caches/org.swift.swiftpm" 2>/dev/null
DD="$HOME/Library/Caches/YapToTextDD"
rm -rf "$DD/SourcePackages" 2>/dev/null
find "$DD" -type d -name XCBuildData -exec rm -rf {} + 2>/dev/null

echo "Done. Build again with Scripts/build-open.sh"
