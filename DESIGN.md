# YapToText - Product & Technical Design

A free, fully native, on-device macOS alternative to superwhisper: the same system-wide
hold-to-talk dictation, but free, private by default, and with every power feature unlocked.
This document is the synthesized spec that drove the build (from research on superwhisper, its
Modes system, pricing, rivals, user complaints, and the macOS-26 technical approach).

## Positioning

superwhisper is a paid app (subscription, and a lifetime tier that climbed to ~$849 in
2026). YapToText delivers the same core - system-wide hold-to-talk dictation inserted into
any app - for free, by running Apple's on-device stack:

- **Speech-to-text:** macOS 26 `SpeechAnalyzer` + `SpeechTranscriber` - streaming, no
  duration cap, models managed by the OS via `AssetInventory`.
- **AI transform:** Foundation Models framework (`SystemLanguageModel` /
  `LanguageModelSession`) - free on-device LLM, no API keys, scoped to cleanup / formatting
  / extraction.
- **Whisper fallback (seam):** whisper.cpp (`whisper.spm` + Core ML ANE) for Intel /
  older macOS or model pinning.

It answers the loudest superwhisper complaints: no subscription, never uploads audio,
never saves audio by default, sane one-hotkey defaults, and reliable insertion that works
in terminals and secure fields.

## The Mode system

A **Mode** is a reusable two-stage profile:

1. **Voice processing** - transcription with a chosen engine/model + per-mode vocabulary.
2. **AI processing (optional)** - a `LanguageModelSession` applies the mode's instruction
   prompt to the transcript, with selectable context blocks (active app, selected text,
   clipboard).

A mode bundles: engine/model, optional AI instructions, context toggles, output target,
vocabulary scope, and (roadmap) auto-activation rules.

**Built-in modes:** Raw Transcription, Clean Up (recommended default), Note, Email,
Message, Code Comment. **Custom modes:** unlimited, with your own prompt and context
toggles. Modes are stored as editable JSON.

**Scope guardrail:** because the default AI stage is Apple's on-device model, AI prompts
should be cleanup/formatting/extraction-shaped and are chunked to respect the context
window; heavier tasks are a future opt-in BYOK cloud path.

## Must-have features (v1 status)

- [x] System-wide dictation into any focused field (Carbon global hotkey, needs no extra permission).
- [x] On-device streaming STT via SpeechAnalyzer/SpeechTranscriber (uncapped).
- [x] Optional on-device AI transform via Foundation Models, chunked for the context window.
- [x] Reliable insertion: paste with clipboard save/restore; typing fallback; Secure-Input aware.
- [x] Modes system: built-ins + unlimited free custom modes with context toggles.
- [x] Per-app mode auto-activation (data model + resolver).
- [x] Custom vocabulary replacements (regex-backed, whole-word / case options).
- [x] Searchable, exportable local history (text only, JSON).
- [x] Output targets: insert / clipboard-only / insert-and-Return.
- [x] Privacy defaults: on-device only; audio never saved or uploaded.
- [x] First-run onboarding for Microphone + Accessibility with deep-links.
- [ ] Meeting / system-audio capture (ScreenCaptureKit) - roadmap.
- [ ] Broader languages via whisper.cpp - roadmap (Apple locales work now).

## Differentiators over superwhisper

- Genuinely free forever, no account, no subscription.
- Privacy-as-default: never uploads audio, never saves audio, no plaintext key files.
- Every power feature free and local (custom LLM modes, per-app switching, vocabulary, history).
- Developer-focused modes (code/commit/comment).
- No session timeout (beats native Dictation's ~30s cap).
- True streaming with volatile/committed distinction; instant cancel.
- Lightweight native SwiftUI/AppKit (no Electron).

## Architecture

Menu-bar agent (`.accessory`) + Settings window. Layered:

1. **Capture** - `AVAudioEngine.installTap`; deep-copy buffers and convert with
   `AVAudioConverter` **off** the real-time render thread (converting on it is a
   documented crash).
2. **Transcription** - `TranscriptionEngine` protocol; `AppleSpeechEngine` feeds an
   `AsyncStream<AnalyzerInput>` and consumes `transcriber.results` (`.volatileResults`
   for live guesses); `WhisperEngine` is the swappable seam.
3. **Transform** - `FoundationModelsTransformer` (availability-gated, `prewarm()`,
   chunking).
4. **Insertion** - `TextInserter`: Cmd+V CGEvent with clipboard restore, unicode typing
   fallback, `IsSecureEventInputEnabled()` check; `AccessibilityReader` for app/selection.
5. **Trigger** - `HotkeyManager` (Carbon `RegisterEventHotKey`, delivers press + release
   for push-to-talk).
6. **Orchestration** - `DictationController` state machine.
7. **Persistence** - JSON in `~/Library/Application Support/YapToText/`; settings in
   UserDefaults.

## Permissions

- **Microphone** (TCC) - the one required permission; `AVCaptureDevice.requestAccess`.
- **Accessibility** (TCC) - optional. Insertion works without it because TextInserter posts
  synthetic key events to `.cghidEventTap` (below the WindowServer's Accessibility-trust
  filter). Granting it only unlocks reading other apps' selected text and per-app context.
- **Input Monitoring** - only if a future modifier-hold trigger is enabled; not needed now.
- **Apple Intelligence** - must be enabled for AI modes; gated on `SystemLanguageModel`
  availability, with graceful fallback to raw transcription.
- Ships **sandboxed** with Hardened Runtime, so it is eligible for the Mac App Store while
  still inserting system-wide (via `.cghidEventTap`, the Karabiner / InputConfig technique).
  A non-sandboxed Developer ID variant (set `app-sandbox` to false), which can additionally
  read other apps' UI via the Accessibility API, is the opt-in alternative distributed by DMG.

## Key risks (and how YapToText handles them)

- **Platform lock-in** of the native path → `WhisperEngine` seam + raw-transcription fallback.
- **On-device LLM scope/context limit** → prompts scoped to cleanup; transcripts chunked.
- **Insertion fragility** (Secure Input, Electron, clipboard races) → typing fallback,
  clipboard save/restore, Secure-Input detection.
- **Carbon deprecation** → still stable and permission-free today; isolated behind `HotkeyManager`.

## Roadmap

1. whisper.cpp backend (Intel / older macOS / model pinning).
2. VAD hallucination suppression for the Whisper path.
3. Meeting/system-audio capture (ScreenCaptureKit) + file import.
4. Modifier-hold push-to-talk (Input Monitoring).
5. Per-app auto-activation UI + active-mode indicator.
6. URL scheme / Shortcuts / CLI automation.
7. Advanced vocabulary (phonetic hints, learned terms, shareable packs).
8. Optional BYOK cloud transform (Keychain-stored keys) for heavy prompts.
9. Ship engineering: Developer ID sign + notarize, Sparkle auto-update, DMG + Homebrew cask.
