# YapToText

**Yap it. Bam. It's typed.**

Free, private speech to text for your whole Mac. Press one key, talk, and your words land
wherever your cursor is. Everything runs on your Mac, and nothing ever leaves it.

[<img src=".github/assets/mac-app-store-badge.svg" alt="Download on the Mac App Store" height="48">](https://apps.apple.com/us/app/yaptotext/id6786382289?mt=12)

![YapToText](Marketing/posters-v4/01-hero.jpg)

## Why it exists

I built YapToText because I need it. My hands make typing difficult, so I dictate
everything. The good dictation apps all wanted a subscription and sent my voice to their
servers. I didn't want either, so I made my own, and I'm giving it away.

## What it does

- **Dictate anywhere.** One tap of Right Command starts dictation in any app. Your text is
  typed right at the cursor.
- **Quick Edit (new in 1.1).** Select text in any app, press your Quick Edit key, and say
  the change. Rewrite, shorten, fix tone, translate: it lands right where the selection was.
- **Hears you through anything (new in 1.1).** A rebuilt listening engine: background-noise
  removal, adaptive normalization, and deeper decoding when the room gets loud. Whispering
  next to a running 3D printer transcribes cleanly.
- **Fully on device.** The speech model and the AI cleanup model ship inside the app. It
  works offline from the first launch. No account, no cloud, no analytics.
- **Auto mode.** It reads each dictation and picks the right format on its own. An email
  comes out as an email, a quick message stays casual, everything else just gets cleaned up.
- **Modes for everything.** Raw Transcription, Clean Up, Email, Note, Message, Code, or
  write your own with custom instructions. Press 1 through 9 mid-dictation to switch.
- **Teach it your words.** Dictionaries fix the names it mishears. Commands type anything
  you say: "insert phone number" types your real number.
- **Never lose a word.** Crash recovery rescues interrupted dictations. Full history with
  playback, search, editing, and export.
- **Transcribe any file.** Drop in audio or video, get the text.
- **Built for accessibility.** Works with VoiceOver and Voice Control, one key runs
  everything, and dictation can fully replace typing.

![Quick Edit](Marketing/posters-v4/03-quick-edit.jpg)

![The listening engine](Marketing/posters-v4/04-listening-engine.jpg)

![AI pipelines](Marketing/posters-v4/06-ai-pipelines.jpg)

![Menu bar](Marketing/posters-v4/05-menubar.jpg)

![Watch the pipeline work](Marketing/posters-v4/07-pipeline-live.jpg)

![Teach it your words](Marketing/posters-v4/09-personalize.jpg)

![Privacy](Marketing/posters-v4/08-privacy.jpg)

## What's new in 1.1

- Quick Edit: edit any selected text by voice, in any app
- Rebuilt listening engine: noise removal, adaptive normalization, deep decoding in noise
- Voice corrections: "scratch that", "replace X with Y", "add this to my dictionary"
- Any key can be a trigger, not just modifiers
- Intelligent insert adapts mid-sentence dictation to the surrounding text
- Re-choreographed recording pop-up; the wave condenses into a spinning ring
- Faster AI cleanup (GPU context reused), lower idle CPU
- Custom colors with a full RGB mode; bring your own Whisper or GGUF models
- Dozens of fixes; the full changelog lives in the app under About

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon. On macOS 26 the interface picks up the new Liquid Glass look.
- Xcode 26+ to build from source.
- AI modes use Apple Intelligence when it's on, or the bundled local model when it isn't.
  Raw transcription needs neither.

## Permissions

- **Microphone (required):** so it can hear you.
- **Accessibility (required for automatic pasting):** macOS only lets apps with this
  permission type into other apps. Without it, YapToText still transcribes everything and
  copies the result to your clipboard.

## Privacy

The formal policy is in [PRIVACY.md](PRIVACY.md); the short version:

- Audio is processed on device and is never uploaded.
- History stores your transcripts as JSON in the app's own container on your Mac, and (by
  default) the audio of each dictation next to them so you can play a recording back. The
  audio stays on your Mac like everything else; turn off "save audio with history" in
  Settings to keep text only, choose how much history is retained, or delete any entry -
  its audio is removed with it.
- No network calls. No analytics, no account, no tracking of any kind.
- The entire source is here, so none of this has to be taken on faith.

### The boring details

The bullet points above are the promise; this is exactly where every byte lives and travels.

- **Audio.** Captured from the microphone, transcribed in memory on your Mac. While a
  dictation is running, the audio is also written to a file inside the app's sandboxed
  container as a crash-recovery net. With "save audio with history" on (the default) that
  file is kept alongside the History entry for playback; with it off, the file is deleted
  the moment the dictation ends. Deleting a History entry deletes its audio, and the
  history retention setting prunes old audio automatically. Nothing is ever sent anywhere.
- **Raw transcript.** What the speech model heard, before any cleanup. Kept in History
  (alongside the cleaned text) so you can always compare the two - each entry has a
  "Show what was heard" toggle. History is a plain JSON file in the app's container:
  `~/Library/Containers/.../Data/Library/Application Support/YapToText/history.json`.
- **Cleaned text.** Produced on device, either by Apple's on-device models or by the bundled
  local models. The prompt and your text never leave the machine.
- **Model downloads.** The ONLY network traffic the app can generate, and only when you
  explicitly click a download button: models are fetched over HTTPS from Hugging Face and
  stored in the app's container. No request carries anything about you or your dictations.
  The recommended models can also ship inside the app bundle, in which case even this
  traffic never happens.
- **Crash logs.** Standard Apple crash reporting only, governed by your macOS analytics
  settings. The app has no crash SDK of its own and phones home to nothing.
- **Update checks.** None. Updates come from the Mac App Store (or you rebuild from
  source); the app itself never checks a server.
- **Settings, dictionaries, modes.** JSON files in the same sandboxed container. Deleting
  the app deletes all of it.

## Building

```bash
git clone https://github.com/ryleighnewman/YapToText.git
open YapToText/YapToText.xcodeproj
```

Select the YapToText scheme and press Cmd-R. The app is sandboxed and builds the same way
it ships.

## Support

YapToText is free with no locked features. If it helps you, there's a tip jar in the app,
and that's it. Bug reports and ideas are welcome in
[Issues](https://github.com/ryleighnewman/YapToText/issues).
