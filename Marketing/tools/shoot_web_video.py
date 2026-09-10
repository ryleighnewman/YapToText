#!/usr/bin/env python3
"""Silent website clips of the real pop-up, driven by synthetic speech.

No microphone, no audio track, nothing on screen but the panel over a flat studio desktop.
Same staging system as shoot_web.py: the marketing look is applied in memory with writes
suspended, and the user's own settings are restored byte-for-byte at the end.

Run from Marketing/:  python3 tools/shoot_web_video.py [--install]
"""
import os, sys, time, json, shutil, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shoot_v5 as r
from PIL import Image

OUT = os.path.join(r.MK, "video-web"); os.makedirs(OUT, exist_ok=True)
SITE_VIDEO = os.path.expanduser("~/Desktop/Apps/yaptotext.com/assets/video")
SENTENCE = "Accessibility made free and beautiful."

def record(name, rect, seconds):
    """screencapture -v writes a silent H.264 file; -V is the duration, -x kills the shutter."""
    x, y, w, h = rect
    mp4 = os.path.join(OUT, f"{name}.mp4")
    # screencapture REFUSES to overwrite an existing file and only says "Failed to save to
    # final location"; the transcode then silently re-encodes the previous take.
    if os.path.exists(mp4): os.remove(mp4)
    p = subprocess.Popen(["screencapture", "-v", "-V", str(seconds), "-R", f"{x},{y},{w},{h}", "-x", mp4])
    return p, mp4

def transcode(name):
    """Web pair: a faststart mp4 and a vp9 webm, both silent, plus a poster frame."""
    src = os.path.join(OUT, f"{name}.mp4")
    fin = os.path.join(OUT, f"{name}.web.mp4")
    webm = os.path.join(OUT, f"{name}.webm")
    poster = os.path.join(OUT, f"{name}.jpg")
    r.sh(f'ffmpeg -loglevel error -y -i "{src}" -an -c:v libx264 -profile:v high -pix_fmt yuv420p '
         f'-crf 23 -movflags +faststart "{fin}"')
    r.sh(f'ffmpeg -loglevel error -y -i "{src}" -an -c:v libvpx-vp9 -b:v 0 -crf 34 -row-mt 1 "{webm}"')
    r.sh(f'ffmpeg -loglevel error -y -ss 1 -i "{src}" -vframes 1 -q:v 3 "{poster}"')
    os.replace(fin, src)
    for f in (src, webm, poster):
        print("  ", os.path.basename(f), os.path.getsize(f) // 1024, "KB")

def crop_to_wave_band(name):
    """Trim a recording of the expanded panel down to its waveform strip.
    The card is found on the first frame (anything brighter than the flat studio ground),
    and the band starts 8px below the card top and runs 110px, measured off the matching
    still in shots-web/panel-expanded.png."""
    src = os.path.join(OUT, f"{name}.mp4")
    probe = os.path.join(OUT, f"_frame-{name}.png")
    r.sh(f'ffmpeg -loglevel error -y -ss 1 -i "{src}" -vframes 1 "{probe}"')
    im = Image.open(probe).convert("RGB")
    ground = im.getpixel((2, 2))
    def lit(x, y):
        p = im.getpixel((x, y))
        return sum(abs(p[i] - ground[i]) for i in range(3)) > 24
    xs = [x for x in range(im.width) if any(lit(x, y) for y in range(0, im.height, 4))]
    ys = [y for y in range(im.height) if any(lit(x, y) for x in range(0, im.width, 4))]
    os.remove(probe)
    if not xs or not ys:
        print("   card not found, leaving", name, "uncropped"); return
    x, y, w = xs[0], ys[0] + 8, xs[-1] - xs[0] + 1
    h = min(110, im.height - y)
    w -= w % 2; h -= h % 2
    out = os.path.join(OUT, f"_band-{name}.mp4")
    r.sh(f'ffmpeg -loglevel error -y -i "{src}" -filter:v "crop={w}:{h}:{x}:{y}" -an "{out}"')
    os.replace(out, src)
    print(f"   cropped to the wave band {w}x{h} at {x},{y}")

def typewriter(proc_seconds, text, lead=1.6):
    """Reveal the sentence a word at a time while the wave keeps running."""
    words = text.split()
    time.sleep(lead)
    per = max(0.18, (proc_seconds - lead - 2.2) / max(1, len(words)))
    for i in range(1, len(words) + 1):
        r.note("yap.debug.stagetext", " ".join(words[:i]))
        time.sleep(per)

def main():
    r.stage_begin()
    try:
        r.quit_app()
        r.sh(f'python3 "{os.path.join(r.TOOLS, "seed_demo_data.py")}" "{r.DATA}"')
        for _ in range(3):
            r.launch_app(); time.sleep(9)
            r.note("yap.debug.whatsnew", "close"); r.note("yap.debug.welcome", "close"); time.sleep(1.5)
            live = json.load(open(os.path.join(r.DATA, "history.json")))
            if len(live) == 48 and "mockups" in json.dumps(live): break
            r.quit_app(); time.sleep(2)
            r.sh(f'python3 "{os.path.join(r.TOOLS, "seed_demo_data.py")}" "{r.DATA}"')
        else:
            raise SystemExit("seed did not take - aborting")
        r.stage_settings()

        flat = os.path.join(r.BACKUP, "flat-violet.png")
        Image.new("RGB", (640, 400), (18, 22, 24)).save(flat)   # the site's own page ground:
        # yap.css body is rgb(18,22,24), and the hero backdrop blends with mix-blend-mode:
        # screen, where anything near black reads as transparent. Shooting the glass over
        # this exact color is what makes the pop-up sit ON the page instead of in a box.
        r.osa(f'tell application "System Events" to tell every desktop to set picture to "{flat}"')
        r.osa('tell application "System Events" to set visible of (every process whose visible is true and name is not "Finder" and name is not "YapToText") to false')
        time.sleep(6)
        r.note("yap.debug.closeWindow"); time.sleep(1.5)
        r.note("yap.debug.panellook", "accent||0.35|accent|")

        # hero-panel: the expanded pop-up typing a sentence out, 12s
        r.note("yap.debug.waveboost", "2.3")
        r.note("yap.debug.stagepanel", f"expanded| |1.7"); time.sleep(3.0)
        pw = r.window_id(280, 620, 420, layer_min=1)
        if pw:
            proc, _ = record("hero-panel", r.rect_of(pw[0]), 12)
            typewriter(12, SENTENCE)
            proc.wait(timeout=60); transcode("hero-panel")
        else: print("no panel for hero-panel")
        r.note("yap.debug.stagepanel", "off"); time.sleep(1.4)

        # panel-live: the hero BACKDROP. It sits behind the headline at 38% with
        # mix-blend-mode: screen, so it has to be the wave band alone. The compact layout
        # carries its transport buttons, which showed up as ghost circles behind the title;
        # the expanded layout with no text gives a clean wide strip once cropped.
        r.note("yap.debug.waveboost", "2.3")
        r.note("yap.debug.stagepanel", "expanded| |1.7"); time.sleep(3.0)
        pw = r.window_id(280, 620, 420, layer_min=1)
        if pw:
            proc, _ = record("panel-live", r.rect_of(pw[0]), 12)
            proc.wait(timeout=60)
            crop_to_wave_band("panel-live")
            transcode("panel-live")
        else: print("no panel for panel-live")
        r.note("yap.debug.stagepanel", "off"); time.sleep(1)
        r.note("yap.debug.waveboost", "1")
    finally:
        r.stage_end()

def install():
    n = 0
    for name in ("hero-panel", "panel-live"):
        for ext in ("mp4", "webm", "jpg"):
            src = os.path.join(OUT, f"{name}.{ext}")
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(SITE_VIDEO, f"{name}.{ext}"))
                print("installed", f"{name}.{ext}", os.path.getsize(src) // 1024, "KB"); n += 1
    print(f"{n} files -> {SITE_VIDEO}")

if __name__ == "__main__":
    if "--install" in sys.argv: install()
    else: main()
