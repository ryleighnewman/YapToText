# YapToText

Free, private, on-device voice-to-text for your whole Mac. A native rebuild of what
superwhisper does (system-wide dictation that inserts text into any app), with no
subscription, no account, and nothing leaving your machine. Positioned and built as an
accessibility (assistive voice input) tool.

The whole pipeline runs on Apple's on-device frameworks, so it is free:

- **Transcription:** macOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (streaming, no time limit).
- **AI cleanup / formatting:** Apple Intelligence `FoundationModels` (on-device LLM, no API keys).
- **Insertion anywhere:** synthesized key events posted to the HID event tap, with clipboard save-and-restore.
- **Optional downloaded models:** Whisper (speech) and GGUF LLMs (cleanup) stored in the app's data container.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Xcode 26+ to build.
- AI modes (Clean Up, Email, etc.) need Apple Intelligence enabled. Raw transcription works without it.

## Permissions

- **Microphone (required):** to hear you. This is the only required permission.
- **Accessibility (optional):** dictation and text insertion already work without it, because
  YapToText injects key events at the HID layer (the same technique Karabiner / BetterMouse /
  InputConfig use). Granting Accessibility only unlocks reading your selected text and detecting
  the active app for smarter per-app modes.

## Distribution and the sandbox

YapToText ships **sandboxed**, so it is eligible for the Mac App Store. System-wide insertion
still works because it posts to `.cghidEventTap`, which the sandbox permits. Entitlements:
app-sandbox, `device.audio-input`, `network.client`, `files.user-selected.read-write`.

To build the **non-sandboxed Developer ID** variant (which can additionally read other apps'
UI via the Accessibility API), set `com.apple.security.app-sandbox` to `false` in
`YapToText.entitlements`. Distribute that via notarized DMG / GitHub Releases.

## Build and run

```bash
open ~/Desktop/YapToText/YapToText.xcodeproj
```

Select the **YapToText** scheme and press Cmd-R. Set your team under Signing & Capabilities
for a real signed build (the project ships ad-hoc-signed so it also builds from the CLI):

```bash
cd ~/Desktop/YapToText
xcodebuild -scheme YapToText -configuration Debug build
```

YapToText runs as a menu-bar app (no Dock icon). Look for the microphone glyph in the menu bar.

## Using it

- Press the shortcut (default Control-Option-Space) to start; press again to stop. The text is
  cleaned (if the mode uses AI) and inserted at your cursor.
- Switch to hold-to-talk, set a cycle-mode shortcut, tune silence auto-stop and the pop-up
  animation/position in Settings > General.
- Pick a Mode from the menu bar. Download extra Whisper / LLM models in Settings > Models.

## Features

- System-wide dictation into any focused field; streaming live panel with a waveform.
- Built-in modes: Raw, Clean Up, Note, Email, Message, Code Comment. Plus unlimited custom modes.
- Per-app mode auto-activation. Output targets: insert, clipboard, or insert-and-Return.
- Downloadable models (Settings > Models), stored in the app data container so updates keep them.
- Custom vocabulary replacements. Searchable, exportable local history with retention controls.
- Silence auto-stop, max length, animated/positioned pop-up, launch at login, subtle sounds.
- Support tab: StoreKit tip jar plus GitHub Sponsors / issues / releases links.
- Secure-Input aware: falls back to typing when a password field blocks paste.

## Privacy

- Audio is processed on device and is never written to disk or uploaded.
- History stores text only, as JSON in the app's Application Support container.
- No network calls except model downloads you explicitly start. No analytics, no account.

## Project layout

| Area | Path |
|------|------|
| App shell | `YapToText/App/` (App, AppDelegate, AppState) |
| Capture | `YapToText/Audio/AudioRecorder.swift` |
| Transcription | `YapToText/Transcription/` (protocol, AppleSpeechEngine, WhisperEngine seam) |
| AI transform | `YapToText/Transformation/FoundationModelsTransformer.swift` |
| Models | `YapToText/Models/` (ModelInfo, ModelCatalog, ModelDownloadManager, ModelLibrary) |
| Insertion | `YapToText/Insertion/` (TextInserter, AccessibilityReader) |
| Trigger | `YapToText/Hotkey/` (HotkeyManager, KeyCombo) |
| Orchestration | `YapToText/Dictation/DictationController.swift` |
| Data | `Modes/`, `Vocabulary/`, `History/`, `Support/AppSettings.swift` |
| Support / tips | `YapToText/Support/` (TipJarService, SupportLinks) |
| UI | `YapToText/UI/`, `YapToText/Settings/` |

See `DESIGN.md` for the full spec and roadmap.

## Roadmap

Wire real whisper.cpp / llama.cpp inference for the downloaded models (the download, storage,
and selection framework is complete); ScreenCaptureKit meeting capture; Shortcuts / URL scheme
automation; notarization + DMG and App Store submission.

## App Store note

Your registered App ID is the explicit `YapToText`. The project uses
`com.ryleighnewman.YapToText` (conventional reverse-DNS). If you submit to the App Store, set
`PRODUCT_BUNDLE_IDENTIFIER` to exactly match your registered App ID, and add the tip-jar
products (`com.ryleighnewman.YapToText.tip.*`) in App Store Connect.
