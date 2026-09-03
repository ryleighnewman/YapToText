# YapToText - Mac App Store listing

## Name
YapToText

## Subtitle (30 chars max)
Private on-device dictation

## Category
Primary: Productivity. Secondary: Utilities.

## Price
Free. Optional tip jar (non-consumable + subscription tips, already configured in the app).

## Promotional text (170 chars max)
Talk, and your words land in any app: cleaned up, punctuated, and private. Everything runs on your Mac. Your voice never leaves it.

## Description

YapToText turns your voice into polished text in any app on your Mac, and it does all of it on your Mac. Press one key, talk, and your words appear where your cursor is.

WHY IT'S DIFFERENT
- 100 percent on-device. Speech recognition and cleanup run locally. Your voice and your words never leave your Mac.
- No feature gates. Every feature is available the moment you install it.
- Built for accessibility first: dictation that can fully replace typing, alongside VoiceOver and Voice Control.
- Open source. Every line of code is public, so the privacy claims can be verified.

DICTATION THAT BEHAVES LIKE DICTATION
- Say "question mark" or "exclamation point" and the mark lands where you said it, with no stray period left behind. Mention a punctuation name mid-sentence and it stays a word.
- Intelligent insert: dictate into the middle of a sentence and the case, spacing, and punctuation adapt to the text around your cursor.
- Quick Edit: select text in any app, hold a key, and say the change. "Make this shorter." "Fix the spelling."

AUTO MODE: IT KNOWS AN EMAIL WHEN IT HEARS ONE
- Auto reads each dictation and picks the right format by itself: emails get formatted as emails, casual messages stay as spoken, everything else is cleaned up.
- It listens to context: the app you're dictating into, spoken requests like "make that formal," even the text you have selected.
- Conservative by design. It fixes what the mic misheard and never rewrites your voice, drops a sentence, or adds words you did not say.

SPEAK HOWEVER YOU WANT
- Whisper if you need to: auto-amplify measures your voice against the room, not a fixed level, and lifts a quiet voice to full clarity. If your Mac's input volume is set low, the app tells you and can raise it. Background noise is removed before transcription.
- Push-to-talk or toggle, pause and resume, cancel with Esc, silence auto-stop.
- One tap of the Right Command key starts everything, or remap it to any shortcut, down to a single bare key.

WHISPER-CLASS ACCURACY, BUILT IN
- Ships with Whisper Large v3 Turbo for speech and a bundled cleanup model for polish, both inside the app. No downloads, no setup: fully offline from first launch.
- Cleanup fixes filler words, false starts, and punctuation on every Mac, with no cloud and no account.
- Bring your own: any Whisper speech model or GGUF cleanup model drops into the model library.

MODES: YOUR WORDS, FORMATTED
- Auto, Raw Transcription, Clean Up, Note, Email, Message, and Code built in. Press 1-9 while dictating to pick one on the fly.
- Create your own modes with custom instructions; assign a default per app.
- Regenerate any past dictation or selected text as a different mode from the menu bar.

MAKE IT YOURS
- Dictionaries shape what the app hears, not just what it types. Fix the same word twice and it offers to remember it.
- Commands: say "insert phone number" and get your real number; say "smiley face" and get the emoji.
- Insert your way: instant paste, character-by-character typing, or clipboard only, with per-app overrides.
- A floating live panel with a real waveform: expanded or compact, your position, size, and colors.
- Energy settings: the models follow your power source, full-size plugged in and lighter on battery.

NEVER LOSE A WORD
- Crash recovery: if anything interrupts a dictation, it's rescued on next launch and waiting in History.
- Full history with audio playback, search, editing, and export. Statistics on pace, time saved, and streaks, all computed locally.

PRIVACY
- No analytics, no tracking, no accounts. The only network use is a model download you start yourself.
- Microphone is the one required permission. Accessibility lets the app type into other apps and read the text around your cursor; without it, your text goes to the clipboard.

Made by one person who dictates for a living.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://github.com/ryleighnewman/YapToText#privacy

## Keywords (100 chars max)
dictation,speech to text,whisper,voice typing,transcribe,transcription,private,offline,voice,speech

## What's New (1.4)

- Spoken punctuation follows the standard dictation convention: say “is it working now, question mark” and get “is it working now?” with no stray mark left behind
- Punctuation names spoken in the middle of a sentence stay as words; they become the mark only at the end of a clause
- Quiet speech: auto-amplify now measures your voice against the room instead of a fixed level, and the app warns when the Mac’s input volume is low and can raise it for you
- Cleanup can no longer drop a sentence or add an ellipsis you did not say
- A long dictation that ends in silence no longer repeats its last sentence over and over, and long dictations clean up faster
- Fixed a crash when changing the input device; the microphone meter in Settings now follows the chosen input
- Fixed hallucinated speaker labels such as “Male speaker:” appearing in transcripts and being learned as vocabulary
- Intelligent insert reads around the cursor more reliably in web and Electron apps, with fewer keystrokes and fewer system beeps
- A notice under Intelligent insert explains the beep and how to silence it in Sound settings
- The menu bar spinner is visible on a light menu bar
- Light mode has a firmer window background and clearer card edges
- The first dictation after idle is faster, and the microphone lets go properly after every dictation
- Restore Defaults in Settings > Advanced puts every setting back, with a confirmation and an Undo button
- The Homebrew build can use the microphone

## URLs
- Marketing/support: https://ryleighnewman.com
- Privacy policy: https://github.com/ryleighnewman/YapToText (PRIVACY section)
- Source: https://github.com/ryleighnewman/YapToText

## Privacy questionnaire
Data Not Collected. No data is gathered, stored, or transmitted. Model downloads are anonymous fetches.

## Review notes (for App Review)
- The app is a sandboxed assistive voice-input tool. Automatic text insertion posts synthetic key events, which macOS permits only with the Accessibility permission; without it the app still transcribes and copies results to the clipboard. Accessibility also enables reading selected text for the Regenerate feature.
- The tip jar is voluntary; all features work without paying (guideline 3.2.1 friendly).
- Speech models are downloaded on demand from public model hosts chosen by the user; nothing is uploaded.
