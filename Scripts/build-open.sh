#!/bin/zsh
# Build YapToText (Debug) and open it - with wedge detection so it can never sit forever.
# Usage: Scripts/build-open.sh            build if needed, then open
#        Scripts/build-open.sh open       just open the latest built app instantly (no build)
set -u
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
DD="$HOME/Library/Caches/YapToTextDD"
APP="$DD/Build/Products/Debug/YapToText.app"
LOG="/tmp/yap-build.log"

open_app() { pkill -x YapToText 2>/dev/null; sleep 1; open "$APP"; echo "OPEN: $APP"; }

if [ "${1:-}" = "open" ]; then open_app; exit 0; fi

# Skip the build entirely when no source is newer than the binary.
BIN="$APP/Contents/MacOS/YapToText"
if [ -f "$BIN" ] && [ -z "$(find "$PROJ/YapToText" -name '*.swift' -newer "$BIN" -print -quit)" ] \
   && [ ! "$PROJ/YapToText.xcodeproj/project.pbxproj" -nt "$BIN" ]; then
  echo "Already up to date."; open_app; exit 0
fi

: > "$LOG"
for attempt in 1 2; do
  xcodebuild -project "$PROJ/YapToText.xcodeproj" -scheme YapToText -configuration Debug \
    -derivedDataPath "$DD" -skipPackagePluginValidation -disableAutomaticPackageResolution \
    build >> "$LOG" 2>&1 &
  BPID=$!
  while kill -0 $BPID 2>/dev/null; do
    sleep 15
    C=$(pgrep -x swift-frontend | wc -l | tr -d ' ')
    if [ "$C" = "0" ] && tail -c 300 "$LOG" | grep -q "clang -v -E -dM"; then
      sleep 30
      C2=$(pgrep -x swift-frontend | wc -l | tr -d ' ')
      if [ "$C2" = "0" ] && tail -c 300 "$LOG" | grep -q "clang -v -E -dM"; then
        kill -9 $BPID 2>/dev/null; pkill -9 -x XCBBuildService 2>/dev/null
        if [ $attempt = 2 ]; then
          echo "XCODE IS WEDGED (twice). Restart the Mac - no build will succeed until then."
          osascript -e 'display notification "Xcode build service is wedged. Restart the Mac." with title "YapToText build"' 2>/dev/null
          exit 1
        fi
        echo "Wedge detected - retrying once..."
        : > "$LOG"
        continue 2
      fi
    fi
  done
  wait $BPID 2>/dev/null
  break
done

if grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "BUILD SUCCEEDED"
  osascript -e 'display notification "Build done - opening app" with title "YapToText build"' 2>/dev/null
  open_app
else
  echo "BUILD FAILED:"; grep -m 3 "error:" "$LOG"
  exit 1
fi
