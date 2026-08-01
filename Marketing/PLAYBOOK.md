# App Store Marketing Playbook

How the YapToText App Store screenshots were made, end to end. Written so it can be
handed to a fresh chat for ANY app and reproduce the same quality. Everything referenced
lives in `tools/` (scripts), `shots/` (raw captures), and `posters/` (final 2880x1800 JPGs).

The formula in one line: **stage the Mac like a photo studio, capture real app windows over
liquid glass, then composite them onto Apple-style typographic posters with Python/PIL.**

---

## 0. The spec

- Mac App Store screenshots: **2880x1800** (or 1280x800 / 1440x900 / 2560x1600). Use 2880x1800.
- 10 images maximum. Order matters: hero first, best features next, housekeeping last.
- JPG quality 95 is fine. No transparency in the final files.
- Every screenshot is a POSTER: big headline, one-line subhead, one (or two) real app
  captures with soft shadows on a near-white field. That's the whole Apple look.

## 1. The compositor (`tools/posters.py`)

One Python/PIL script generates all ten posters from raw PNG captures. Core conventions:

- Canvas `2880x1800`, background `#FBFBFD` (Apple near-white), ink `#1D1D1F`,
  secondary gray `#6E6E73`, accent = system blue `#0A84FF`.
- Type is real SF Pro: `ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)` then
  `font.set_variation_by_name("Bold" | "Semibold" | "Regular")`. Titles ~150-200px,
  subheads 56-60px Regular in the secondary gray, one accent-colored punch line max.
- `load_shot()` opens a capture and TRIMS transparent margins (`img.getbbox()`).
  **Never use it for layered art that must stay registered** (see section 7 bug).
- `with_shadow()` puts every capture on a soft double shadow: one big ambient blur
  (radius ~70, alpha ~54, offset-y ~34) plus one tight contact shadow (radius ~22,
  alpha ~46, offset-y ~10). This is what makes flat screenshots look like product photos.
- `place(canvas, sheet, pad, centerX, top, target_width)` scales and positions.
- Poster recipes are just: headline block, capture(s) with shadow, save. Variants used:
  - Hero: brand name small + punchy title + 2 subheads + accent line + main window with
    two floating panels overlapping its corners.
  - Feature pages: title + subhead(s) + one big window capture (target width ~1980).
  - Pair page: two windows staggered diagonally + example captions with arrows.
  - Typography-led pages (privacy, accessibility): giant two-line title, copy, smaller art.
- Decorative extras that worked: the app's own icon/glyph PNGs flanking a capture with
  ±10 degree tilts; a row of gray SF Symbols; state variants of the menu bar glyph
  recolored in code.

Run it FROM the `Marketing/` folder: `python3 tools/posters.py` (needs Pillow). It reads
`../shots` and writes `../posters` — all paths relative, nothing points at a temp directory.

**Layout is hand-tuned by eye, and that is normal.** Every window/panel position is just a
`place(canvas, sheet, pad, centerX, topY, targetWidth)` call. Two knobs do everything:
`topY` moves a capture up/down, `targetWidth` makes it bigger/smaller (a paired window grows
"down and to the left" by lowering its centerX and raising its width). Expect the person you
are working for to review each poster and say "move it up," "make it bigger," "equal spacing
under the title" — that is the real workflow, not a failure. Change ONE number, regenerate,
show them, repeat. Do not try to nail all positions in one shot.

## 2. Staging the Mac (do this BEFORE any capture)

Liquid glass makes windows gorgeous but it shows EVERYTHING behind them. The staging
ritual, in order:

1. **Save state to restore later**: current wallpaper path, list of visible apps
   (`osascript -e 'tell application "System Events" to get name of every process whose visible is true'`).
2. **Wallpaper**: set a colorful one so the glass shimmers:
   `osascript -e 'tell application "System Events" to tell every desktop to set picture to "/System/Library/Desktop Pictures/Mac Purple.heic"'`
   Wait ~6-8s for the crossfade before the first capture.
3. **Hide every other app**:
   `set visible of (every process whose visible is true and name is not "Finder" and name is not "<YourApp>") to false`
   If ANY app stays visible its text will read through the glass. This leaked a browser
   window with personal content once - always hide, always re-check in the capture.
4. **Desktop widgets CANNOT be hidden** on current macOS (`StandardHideWidgets` is a no-op).
   If a widget sits behind a translucent window, don't fight it - use the per-window
   alpha capture + synthetic backdrop trick from section 5.
5. **Seed demo data**: back up the app's real data files byte-for-byte (history, etc.),
   write believable fake records, capture, restore. Never let real user content into a
   screenshot. Quit the app while swapping files.
6. **Restore everything after**: wallpaper, hidden apps, real data files.

## 3. Driving the app headlessly

Add DEBUG-only DistributedNotificationCenter hooks to the app (wrapped in `#if DEBUG` so
they can't ship). YapToText's set, all callable from shell:

- `yap.debug.goto <page>` - navigate the main window
- `yap.debug.menupopover` - open/close the menu bar popover
- `yap.debug.toggle` / `yap.debug.cancel` - start/stop/cancel a real dictation
- `yap.debug.switcher` - open the mode-switcher overlay

Post one:
```
swift - yap.debug.toggle <<'EOF'
import Foundation
DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(CommandLine.arguments[1]), object: nil, userInfo: nil, deliverImmediately: true)
EOF
```

For clicking real UI (no hook available): `tools/click.swift x y` posts a CGEvent click at
screen coordinates. Coordinate math from a window screenshot displayed at width D:
`screenX = windowX + displayPx * (imageScale/2)`. Two gotchas:
- **Sidebar selection renders GRAY** unless the window was activated AND a sidebar item
  was clicked once first. Activate, click Home, click your target, THEN capture.
- To type into the app, click its field first; to dictate into it, use the app's own
  Dictate button + `say`.

## 4. Window geometry helpers (`tools/*.swift`)

- `winbounds.swift` - bounds of the app's main (layer-0) window
- `winids.swift` - all windows as `id WxH layer=N` (panels/popovers are layer 3-25)
- `winrect.swift <id>` - rect of one window id
- `panelrect.swift` - rect of the floating panel by size range

## 5. Capturing (the part everyone gets wrong)

Three capture modes, each for a different job:

1. **Region capture** - `screencapture -x -R "x,y,w,h"` - the ONLY way to keep real
   liquid-glass blur (WindowServer composites it; window-id capture loses it).
   Use for: main-window pages, panels, anything where the glass look matters.
   Then round the corners in PIL - but NEVER with a plain 1-bit `rounded_rectangle` mask:
   that gives pixelated staircase corners that read as distortion at App Store size.
   ALWAYS supersample: draw the mask at 4x, `resize(size, LANCZOS)` down, and inset the
   rectangle ~2px from the edge so the anti-aliased curve lands on real pixels, not on
   already-transparent ones. (52px radius at 2x for standard windows.)

2. **Window-id capture** - `screencapture -o -x -l <id>` - transparent background,
   loses behind-glass blur. Use for: (a) alpha MASKS to re-apply to region captures of
   the same window (capture once with -l, keep the alpha channel, `putalpha` it onto the
   region capture, then `crop(getbbox())`), and (b) windows that must be isolated from an
   uncontrollable background (desktop widgets): capture with -l, then composite your OWN
   backdrop behind the translucent pixels in PIL - a vertical purple gradient with a
   60px gaussian blur reads exactly like glass and you control every pixel of it.

3. **Live-action shots** (dictation panel with waveform + finished sentence):
   - unmute first (`set volume output volume 62` + unmute), restore mute after
   - start the feature, `say "Your marketing sentence."` (blocking)
   - wait ~2.6s AFTER say ends so letter-by-letter text finishes rendering
   - fire a SECOND background `say` and capture ~0.9s into it - the waveform is alive
     while the finished sentence is on screen. One say = either flat wave or cut-off text.
   - cancel the dictation afterward so nothing pastes anywhere.
   - Make the demo sentence a brand line ("Accessibility made free and beautiful."),
     never lorem-ipsum or quick-brown-fox.

More hard-won rules:
- The app being photographed is translucent too: CLOSE its main window (System Events
  click button 1 of window 1) before capturing its floating panels/popovers, or the
  window text reads through them. Hiding the process does NOT work - it un-hides itself
  when the feature activates.
- Popovers anchored to the menu bar always open over the desktop space; you cannot put a
  fullscreen cover behind them. Use the -l + synthetic backdrop trick.
- First capture after a staging change is often washed out - give every transition 1-6s.
- Check EVERY capture at full size before compositing. Glass leaks read as tiny text.
- VERIFY CORNERS AT ZOOM before calling a poster done. Crop a ~200px box around a window
  corner and `resize(x3, NEAREST)` — pixelated staircase edges are invisible at page size
  but obvious once zoomed, and the person WILL see them on their screen. Do this after any
  masking change. A clean corner is a smooth anti-aliased curve; a bad one has hard steps.
- NEVER hand-crop a panel's edges to remove fringe (a fixed "crop 13px off the left"). It
  mangles the shape and makes backgrounds look wrong. The correct trim is always the
  window's OWN alpha from a `-l` capture of the same window: region-capture for the glass,
  `-l` capture for the mask, `putalpha` + `crop(getbbox())`. Exact shape, zero guesswork.
- Translucent panels INHERIT the wallpaper color through their glass. A purple wallpaper
  makes a purple panel - that is not a crop problem and cannot be cropped away. If the
  tint is wrong, change the wallpaper and re-capture; if it's right, leave it alone.
- Multi-word colored eyebrow lines ("Introducing AppName"): draw as ONE string with one
  font and one fill. Split draws drift in perceived size/weight and users notice.

## 6. Special assets

- **SF Symbol rows** (e.g. accessibility icons): render with `tools/symbols.swift` - it
  rasterizes named symbols at 320px, tinted a single gray (#8E8E93), one PNG each.
  Composite in a spaced row at ~120px.
- **Menu bar glyph states**: load the app's own layer PNGs (body + bubble) with
  `Image.open` (NOT the trimming loader), flat-fill each layer's alpha with a color
  (ink body + red/green/orange bubble), draw spinner spokes in PIL for the processing
  state, then `crop(getbbox())` at the END. Layers share one canvas - trim only after
  compositing, never before (trimming first destroys registration; see section 7).
- **App icon flanking**: the 512px app icon rotated ±10-12 degrees with expand=True and
  a lighter shadow, placed either side of a centered capture at ~430-460px width.

## 7. Bugs we actually hit (so you don't)

- `load_shot()` trims each PNG to content; loading layered art through it scaled the
  layers to different sizes -> garbled composites. Open layers raw, composite, trim last.
- Fractional NSImage canvas (27.1x20.9) = permanently blurry menu bar icon. Integral only.
- `wait` in a shell script waits on the nohup'd APP process too - it hangs forever.
  Use `( say ... & )` subshell or kill by PID.
- The panel got taller after a code change and the size-range filter missed it - print
  ALL windows when a filter comes back empty.
- Poster copy must track the app: we renamed "Words / minute" to "Speaking pace" and the
  old label lived on in a screenshot. Re-capture pages after UI copy changes.
- Chip/pill rows can clip against their scroll container tops - if marketing shots show
  cropped UI, treat it as an APP bug first (ours was), fix it, then re-shoot.

## 8. Poster set that shipped (order + one-line brief)

1. **Hero** - brand name, punch title, feature-buzzword subheads, one accent bash line,
   main window + both panel styles floating over its corners.
2. **Accessibility** - two-line giant title, copy, gray macOS accessibility icon row, panel.
3. **Keyboard** - number-key mode switcher overlay capture.
4. **Modes/Auto** - Modes page with the headline feature at top.
5. **Menu bar** - full popover (demo data) flanked by menu-bar glyph states.
6. **Workbench/Utility** - the feature captured IN ACTION (mid-dictation), never empty UI.
7. **Privacy** - typography-led + the models/settings page that proves the claim.
8. **Personalize** - two staggered windows + concrete example captions with arrows
   ("Riley" -> "Ryleigh", Say "insert phone number" -> (555) 123-4567).
9. **History** - crash-recovery story over the seeded history page.
10. **Statistics** - the stats page with seeded data.

Copy rules that survived many review rounds: name the app's REAL trigger phrases and
labels (check the source, don't guess); every claimed feature must be visible or true in
the app; one cocky line max per set; "open source" and the privacy proof belong together;
no vendor names for models in user-facing copy ("on-device speech recognition", not the
model's name).

## 9. Review-screenshot for IAPs

App Store Connect wants a review screenshot per in-app purchase. Capture the app's real
tip/purchase UI (even in its "unavailable until App Store" state - reviewers see that
constantly), center it on a dark 2880x1800 canvas, upload the same image for all tips.

## 10. Durability rules

- The session scratchpad lives in /private/tmp and is WIPED on every Mac restart. The
  repo's `Marketing/` folder (tools/ shots/ posters/) is the source of truth - sync every
  new capture and script change into it IMMEDIATELY, not at the end.
- If a "good" capture gets overwritten by an experiment, check Time Machine LOCAL
  snapshots before re-shooting: `tmutil listlocalsnapshots /`, then
  `mount_apfs -s <snap> /System/Volumes/Data /tmp/snap` and pull the file out. This
  recovered the shipped panel captures once already.
- Run `python3 tools/posters.py` FROM the Marketing folder; it reads ../shots and writes
  ../posters. Keep it that way - no absolute paths to temp directories.

## 11. Restore checklist (run EVERY time you finish)

- [ ] wallpaper back to the user's own
- [ ] all hidden apps visible again
- [ ] real data files restored byte-for-byte
- [ ] test documents/dictations discarded, volume re-muted if it was
- [ ] the app relaunched from the normal build
