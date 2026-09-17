# YapToText release history

Newest first. The build number is in parentheses; the Mac App Store and Homebrew ship the same build.

## 1.5.2

- Bluetooth hearing aids and headsets keep their full sound quality: the app uses the microphone you chose instead of switching to the Bluetooth one
- Fixed a crash and a freeze when a Bluetooth device connected mid-dictation
- Intelligent Insert is more reliable in Gmail, chat pages, and Electron apps, and dictating over a selection now replaces it the way it was written
- Quick Edit swaps a word or phrase exactly as you say it, instantly
- Cleanup no longer drops words you said
- Hallucinated speaker labels like "Name:" and stage directions are gone
- Miscellaneous bug fixes

## 1.5.1

- Dictating into a terminal works better: reading the text around your cursor uses invisible keystrokes that a terminal treats as its own shortcuts, so that read is now skipped there instead of triggering commands and losing the text
- Intelligent Insert can be turned off for particular apps: the list sits right under its switch on the Dictation page, with terminals already in it
- Cancelling a dictation no longer throws it away: it is still transcribed and saved to History, marked as cancelled, so a stray Escape cannot lose what you said. It is never inserted anywhere
- Keeping cancelled dictations is on by default, alongside the other saving options in Settings > History & audio
- The app watches how well it can actually hear you: if the microphone signal drops well below your own normal, the Dictation page says so and names the likely cause, instead of quietly mishearing more and more

## 1.5

- Send it for me: choose a key per app (Return or ⌘Return) that is pressed the moment your words land, so a dictated message or prompt goes out on its own
- Quick Edit follows your request: rewrite, change tone, translate, capitalize. Case changes apply instantly, and it says so when nothing changed or when what you said was not an edit
- Quick Edit has its own pop-up: pick where it opens, drag it anywhere and it stays, and give it its own colors. The key taps to start and stop by default
- The dictation pop-up stays wherever you drag it; layout, position, snap-back, and colors live on the Dictation page with a live preview
- Cancelling a dictation closes the pop-up in one motion, the same way every time
- Intelligent Insert follows you when you switch apps mid-dictation, keeps working in chat apps, and closes the previous sentence when you dictate just before its period
- Dictionaries group every spelling of a word into one folder, the app's own name is recognized however it is heard, and suggested sound-alikes never include plurals, truncations, or real words
- A sign-off is spelled the way you gave the app your name
- Cleanup never bleeps a word you said or adds a label or a copy of the original; invented speaker names, wrapping quotes, and silent-clip phrases are removed
- Erase All Data in Settings > Advanced starts the app over from the welcome screen
- Every setting has one home, and onboarding shows the real pop-ups with their controls

## 1.4

- Spoken punctuation follows the standard dictation convention: say “is it working now, question mark” and get “is it working now?” with no stray mark left behind
- Punctuation names spoken in the middle of a sentence stay as words; they become the mark only at the end of a clause
- Quiet speech: auto-amplify now measures your voice against the room instead of a fixed level, and the app warns when the Mac’s input volume is low and can raise it for you
- Cleanup can no longer drop a sentence or add an ellipsis you did not say
- A long dictation that ends in silence no longer repeats its last sentence over and over, and long dictations clean up faster
- Fixed a crash when changing the input device; the microphone meter in Settings now follows the chosen input
- Fixed hallucinated speaker labels such as “Male speaker:” appearing in transcripts and being learned as vocabulary
- Intelligent Insert reads around the cursor more reliably in web and Electron apps, with fewer keystrokes and fewer system beeps
- A notice under Intelligent Insert explains the beep and how to silence it in Sound settings
- The menu bar spinner is visible on a light menu bar
- Light mode has a firmer window background and clearer card edges
- The first dictation after idle is faster, and the microphone lets go properly after every dictation
- Restore Defaults in Settings > Advanced puts every setting back, with a confirmation and an Undo button
- The Homebrew build can use the microphone

## 1.3.1

- Dictation is over twice as fast, with a new default speech model
- The app is about a gigabyte smaller
- Intelligent Insert is faster and now works in far more apps
- Your clipboard is handed back right after a dictation is pasted
- Auto mode no longer turns what you say into a list on its own
- Energy settings now switch the cleanup model with the power source, not just the dictation model
- The AI Models page shows what each model is for, with accuracy and speed ratings
- A rewritten in-app Help covering Quick Edit, Intelligent Insert, and energy
- Bug fixes, including the menu bar spinner running backwards

1.3 shipped this same work but bundled the wrong speech model, so the speed and size
gains only actually arrive in 1.3.1.

## 1.2

- Dramatically faster from stop to text: models warm at launch, the AI cleanup reuses its work between dictations, and needless extra passes were trimmed
- New master switch: turn off post-transcription analysis for the fastest possible raw transcription
- Your dictionary now shapes what the app hears, not just what it types; fix the same misheard word twice and it offers to remember it for good
- Energy-aware transcription: the full model plugged in, a lighter one on battery, automatically or per mode, with an Energy page that reads your Mac and recommends the right models
- A diagnostic history: raw transcript, cleaned text, delivered text, delivery outcome, processing time, and optional audio playback for every dictation
- A microphone health check in Settings with specific tips
- Long recordings stream out as you go, cut at natural pauses
- Better accuracy in noisy rooms and for fast speech; words finished right at the stop key are no longer clipped
- Ending a dictation never starts audio that was not already playing; a paused player is only resumed if the app paused it
- Fixed a rare crash when the audio device changed mid-dictation, and a freeze at dictation start while checking Music

## 1.1.1

- The microphone releases as soon as a dictation ends; the recording indicator only shows while you dictate
- The Quick Edit key is consistent: press on / press off in toggle mode, press on / release off in hold mode
- The recording pop-up opens the same way every time, and inserting text no longer stalls its closing animation
- Intelligent Insert reads the surrounding text more reliably

## 1.1

- Quick Edit: edit any selected text by voice, in any app
- Rebuilt listening engine: noise removal, adaptive normalization, deep decoding in noise
- Voice corrections: "scratch that", "replace X with Y", "add this to my dictionary"
- Any key can be a trigger, not just modifiers
- Intelligent Insert adapts mid-sentence dictation to the surrounding text
- Re-choreographed recording pop-up; the wave condenses into a spinning ring
- Faster AI cleanup (GPU context reused), lower idle CPU
- Custom colors with a full RGB mode; bring your own Whisper or GGUF models
- Dozens of fixes; the full changelog lives in the app under About
