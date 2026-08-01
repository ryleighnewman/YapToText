#!/bin/zsh
# Build YapToText (Debug) and open it - with wedge detection so it can never sit forever.
# Usage: Scripts/build-open.sh            build if needed, then open
#        Scripts/build-open.sh open       just open the latest built app instantly (no build)
set -u
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
DD="$HOME/Library/Caches/YapToTextDD"
APP="$DD/Build/Products/Debug/YapToText.app"
LOG="/tmp/yap-build.log"

open_app() {
  # NEVER kill the app mid-dictation: the recovery marker exists exactly while a recording
  # is in flight. Killing then looks like a crash to the user and loses their words
  # (happened live: a relaunch pkilled a just-started dictation). Wait up to 60s for the
  # dictation to end before swapping binaries.
  MARKER="$HOME/Library/Containers/YapToText/Data/Library/Application Support/YapToText/recovery-session.json"
  if [ -f "$MARKER" ]; then
    echo "Dictation in progress - waiting for it to finish before relaunching..."
    for _ in $(seq 1 60); do [ -f "$MARKER" ] || break; sleep 1; done
  fi
  pkill -x YapToText 2>/dev/null; sleep 1; open "$APP"; echo "OPEN: $APP"
}

if [ "${1:-}" = "open" ]; then open_app; exit 0; fi

# Skip the build entirely when no source is newer than the last successful build.
# Compare against a dedicated stamp, NOT the binary: re-signing bumps the binary's
# mtime, which made this check skip real rebuilds ("Already up to date" with stale code).
BIN="$APP/Contents/MacOS/YapToText"
STAMP="$HOME/Library/Caches/YapToTextDD/.build-stamp"
if [ -f "$BIN" ] && [ -f "$STAMP" ] && [ -z "$(find "$PROJ/YapToText" -name '*.swift' -newer "$STAMP" -print -quit)" ] \
   && [ ! "$PROJ/YapToText.xcodeproj/project.pbxproj" -nt "$STAMP" ]; then
  # Even without a rebuild, a binary produced outside this script may be missing the bundled
  # models or the stable signature - ensure both before opening.
  if [ ! -f "$APP/Contents/Resources/Models/ggml-large-v3-turbo.bin" ]; then
    STAGE="$HOME/Library/Application Support/YapToText-bundled-models"
    mkdir -p "$APP/Contents/Resources/Models"
    for m in ggml-large-v3-turbo.bin Phi-3.5-mini-instruct-Q4_K_M.gguf; do
      [ -f "$STAGE/$m" ] && cp -c "$STAGE/$m" "$APP/Contents/Resources/Models/" && echo "bundled $m"
    done
    ENT="/tmp/yaptotext-entitlements.plist"
    codesign -d --entitlements - --xml "$APP" > "$ENT" 2>/dev/null
    [ -s "$ENT" ] && "$PROJ/../devsign.sh" "$APP" --entitlements "$ENT" >/dev/null 2>&1 && echo "re-signed"
  fi
  echo "Already up to date."; open_app; exit 0
fi

: > "$LOG"

# PREFLIGHT (wedge PREVENTION): the Xcode 26 build wedge is a deadlock in the compilation-cache
# (CAS) layer of SWBBuildService - the clang -v -E -dM probe blocks writing to a pipe the service
# never drains, and both sit in mach_msg forever. Removing the CAS store before every build,
# together with COMPILATION_CACHE_ENABLE_CACHING=NO, keeps the CAS out of the build entirely so
# the deadlock can't form. This is cheap and safe (the cache is disabled anyway).
rm -rf "$DD/CompilationCache.noindex" 2>/dev/null
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex" 2>/dev/null

for attempt in 1 2; do
  xcodebuild -project "$PROJ/YapToText.xcodeproj" -scheme YapToText -configuration Debug \
    -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation -disableAutomaticPackageResolution \
    COMPILATION_CACHE_ENABLE_CACHING=NO \
    build >> "$LOG" 2>&1 &
  BPID=$!
  # THE WEDGE CURE (proven live, no restart needed): SWBBuildService's `clang -v -E -dM` probes
  # randomly deadlock - clang blocks on write() to a pipe the service never drains, and the
  # whole build sits forever. A healthy probe exits in <1s, so any probe alive >10s is stuck;
  # killing JUST the probe gives the service EOF and it moves on to the next task. The build
  # then completes normally. Never kill xcodebuild or SWBBuildService themselves.
  while kill -0 $BPID 2>/dev/null; do
    sleep 15
    for pid in $(pgrep -f "clang -v -E -dM"); do
      ET=$(ps -o etime= -p "$pid" | tr -d ' ')
      case "$ET" in ??:*|?:??) kill -9 "$pid" 2>/dev/null && echo "unstuck a wedged clang probe (pid $pid)";; esac
    done
  done
  wait $BPID 2>/dev/null
  break
done

if grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "BUILD SUCCEEDED"
touch "$HOME/Library/Caches/YapToTextDD/.build-stamp"
  # BUNDLE THE SPEECH/AI MODELS: plain xcodebuild does NOT copy the ~3.7GB Whisper + Phi models
  # into the .app (the App Store build does this via a separate step). Without them the loader
  # finds no model and every dictation transcribes to EMPTY ("Nothing was transcribed"). Clone
  # them from the staging dir (instant APFS copy, no extra disk) BEFORE re-signing so the seal
  # covers them. Falls back to the installed App Store app's copy if the staging dir is gone.
  MODELS_DEST="$APP/Contents/Resources/Models"
  STAGE="$HOME/Library/Application Support/YapToText-bundled-models"
  APPSTORE="/Applications/YapToText.app/Contents/Resources/Models"
  mkdir -p "$MODELS_DEST"
  for m in ggml-large-v3-turbo.bin Phi-3.5-mini-instruct-Q4_K_M.gguf; do
    if [ ! -f "$MODELS_DEST/$m" ]; then
      if [ -f "$STAGE/$m" ]; then cp -c "$STAGE/$m" "$MODELS_DEST/" && echo "bundled $m"
      elif [ -f "$APPSTORE/$m" ]; then cp -c "$APPSTORE/$m" "$MODELS_DEST/" && echo "bundled $m (from App Store app)"
      else echo "WARNING: model $m not found - dictation will transcribe empty until it's downloaded."; fi
    fi
  done
  # STABLE identity: Debug builds come out ad-hoc signed (cdhash requirement), so every
  # rebuild is a "new app" to TCC and the Microphone/Accessibility grants reset - dictation
  # then records pure silence and looks crashed. Re-sign with the Apple Development cert
  # (same entitlements) so grants stick across rebuilds. Grant once, keep forever.
  ENT="/tmp/yaptotext-entitlements.plist"
  codesign -d --entitlements - --xml "$APP" > "$ENT" 2>/dev/null
  if [ -s "$ENT" ]; then
    "$PROJ/../devsign.sh" "$APP" --entitlements "$ENT" >/dev/null 2>&1 \
      && echo "Re-signed with stable dev identity." \
      || echo "WARNING: stable re-sign failed; app stays ad-hoc (grants may reset)."
  fi
  osascript -e 'display notification "Build done - opening app" with title "YapToText build"' 2>/dev/null
  open_app
else
  echo "BUILD FAILED:"; grep -m 3 "error:" "$LOG"
  exit 1
fi
