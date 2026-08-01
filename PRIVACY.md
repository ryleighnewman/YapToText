# YapToText Privacy Policy

YapToText is private by design. The short version: **your voice, your words, and your
data never leave your Mac.**

## What the app processes

- **Audio** from your microphone is captured only while you are dictating (or while the
  mic route is kept warm for instant starts - warm audio is analyzed for levels only and
  never stored). Recordings are transcribed on your Mac by on-device models.
- **Transcripts** are produced on device, by Apple's speech engine or by models bundled
  with (or downloaded into) the app.
- **AI cleanup** runs on device, via Apple Intelligence or a local model. Your text is
  never sent to any server for processing.

## What the app stores

- **History** (transcripts, and optionally the audio of each dictation for playback)
  lives in the app's own sandboxed container on your Mac. You choose how much history is
  kept, can turn audio saving off, and can delete any entry - deleting an entry deletes
  its audio. Turning history off deletes stored recordings.
- **Settings, modes, dictionaries, and commands** are stored in the same container.
- Nothing is synced, uploaded, or backed up by the app itself.

## Network access

The app makes **no network calls** during normal use: no accounts, no analytics, no
telemetry, no crash reporting, no tracking of any kind. The single exception is
**model downloads** that you explicitly start from the AI Models page, which fetch model
files over HTTPS (e.g. from Hugging Face). No personal data accompanies those requests.

## Permissions

- **Microphone** - to hear your dictation. Requested on first use.
- **Accessibility** - optional; used to paste your words into other apps, to read the
  text around your cursor for context-aware insertion, and for global shortcut keys.
  Without it, results are copied to the clipboard instead.

## Your data, your machine

Everything described above is inspectable: history is a plain JSON file inside the app's
container, and this application's complete source code is public in this repository. The
privacy promise is not something you have to take on faith - it is checkable.

## Contact

Questions or concerns: open an issue on this repository, or reach out via
[ryleighnewman.com](https://ryleighnewman.com).

*Last updated: July 30, 2026.*
