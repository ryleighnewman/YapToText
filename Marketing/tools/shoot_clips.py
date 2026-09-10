#!/usr/bin/env python3
"""Custom animated clips for yaptotext.com, rendered frame by frame in the background.

Two rules this rig obeys, both from the user:
  1. It must not interrupt them. It drives an ISOLATED copy of the app (bundle id
     YapToTextShoot, launched with YAPTOTEXT_SHOOT=1) which has its own sandbox container and
     registers no global hotkeys, no menu bar item and no Dock tile. Their own app, settings
     and history are never read, quit, restaged or restored. Nothing is fronted, no window is
     hidden, and the wallpaper is not touched.
  2. The result has to be high quality. Frames come from `screencapture -l <windowid>`, which
     grabs one window's own buffer even while it is completely covered, at about 150ms each.
     That would be a choppy 6.7fps if it were a real-time recording, so instead the app's wave
     is pinned to a frame clock (yap.debug.stageframe) and stepped exactly 1/FPS per capture.
     Every frame is a deterministic render, so the assembled video is perfectly even.

Run from Marketing/:  python3 tools/shoot_clips.py [--install]
"""
import os, sys, time, json, shutil, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shoot_v5 as r

MK = r.MK
OUT = os.path.join(MK, "clips"); os.makedirs(OUT, exist_ok=True)
FRAMES = os.path.join(OUT, "frames")
SITE_VIDEO = os.path.expanduser("~/Desktop/Apps/yaptotext.com/assets/video")
SHOOT_APP = os.path.expanduser("~/Library/Caches/YapToTextDD-Shoot/Build/Products/Debug/YapToText.app")
SHOOT_BUNDLE = "YapToTextShoot"
SHOOT_CONTAINER = os.path.expanduser(f"~/Library/Containers/{SHOOT_BUNDLE}")
SHOOT_DATA = os.path.join(SHOOT_CONTAINER, "Data/Library/Application Support/YapToText")
FPS = 30

def sh(cmd, **kw): return r.sh(cmd, **kw)
def note(name, obj=None): return r.note(name, obj)

def shoot_running():
    out = sh(f'pgrep -f "{SHOOT_APP}/Contents/MacOS/YapToText"', check=False, capture=True)
    return bool(out.strip())

def launch_shoot():
    """Launch the isolated copy WITHOUT activating it, so focus stays where the user left it."""
    if shoot_running(): return
    sh(f'open -g -n --env YAPTOTEXT_SHOOT=1 "{SHOOT_APP}"', check=False)
    for _ in range(40):
        time.sleep(0.5)
        if shoot_running(): time.sleep(6); return
    raise SystemExit("the isolated copy did not launch")

def quit_shoot():
    sh(f'pkill -f "{SHOOT_APP}/Contents/MacOS/YapToText"', check=False)
    for _ in range(40):
        if not shoot_running(): return
        time.sleep(0.25)

def shoot_windows():
    """Windows belonging to the ISOLATED copy only, matched by pid so the user's app is never
    touched even though both processes are called YapToText."""
    pid = sh(f'pgrep -f "{SHOOT_APP}/Contents/MacOS/YapToText"', check=False, capture=True).split()
    if not pid: return []
    return json.loads(sh(f'swift {os.path.join(r.TOOLS, "winforpid.swift")} {pid[0]}', capture=True) or "[]")

def panel_window():
    for w in shoot_windows():
        if w["layer"] >= 1 and 200 <= w["w"] <= 700 and w["h"] <= 460:
            return w
    return None

def capture_frames(win_id, count, step, energy, on_frame=None):
    """Step the wave one deterministic frame at a time and grab the window each time."""
    os.makedirs(FRAMES, exist_ok=True)
    for f in os.listdir(FRAMES): os.remove(os.path.join(FRAMES, f))
    t = 0.0
    for i in range(count):
        if on_frame: on_frame(i, t)
        note("yap.debug.stageframe", f"{t:.4f}|{energy}")
        time.sleep(0.045)                       # let the pinned frame render before the grab
        sh(f'screencapture -o -x -l {win_id} "{FRAMES}/f{i:05d}.png"', check=False)
        t += step
    return len([f for f in os.listdir(FRAMES) if f.endswith(".png")])

def assemble(name, fps=FPS):
    mp4 = os.path.join(OUT, f"{name}.mp4")
    webm = os.path.join(OUT, f"{name}.webm")
    poster = os.path.join(OUT, f"{name}.jpg")
    # The captured frames are RGBA (the panel is a floating glass window, so everything around
    # it is transparent). Composite them onto the site's own page colour, rgb(18,22,24), so the
    # pop-up sits ON the page instead of inside a black rectangle. Without this ffmpeg flattens
    # the alpha onto pure black, which reads as a box against the hero's gradient.
    # Even dimensions are an h264 requirement; vp9 needs the pixel format spelled out too.
    chain = ("[0:v]scale=trunc(iw/2)*2:trunc(ih/2)*2[fg];"
             "color=c=0x121618:s=1x1[bgc];[bgc][fg]scale2ref[bg][fg];"
             "[bg][fg]overlay=shortest=1,format=yuv420p")
    sh(f'ffmpeg -loglevel error -y -framerate {fps} -i "{FRAMES}/f%05d.png" '
       f'-filter_complex "{chain}" -an -c:v libx264 -profile:v high -crf 20 '
       f'-movflags +faststart "{mp4}"')
    sh(f'ffmpeg -loglevel error -y -framerate {fps} -i "{FRAMES}/f%05d.png" '
       f'-filter_complex "{chain}" -an -c:v libvpx-vp9 -b:v 0 -crf 32 -row-mt 1 "{webm}"')
    sh(f'ffmpeg -loglevel error -y -i "{mp4}" -ss 1 -vframes 1 -q:v 3 "{poster}"')
    for f in (mp4, webm, poster):
        print("   ", os.path.basename(f), os.path.getsize(f) // 1024, "KB")

if __name__ == "__main__":
    print("director module ready")

# ---------------------------------------------------------------- clip: dictation
def clip_dictation(seconds=10, sentence="Accessibility made free and beautiful."):
    """The core loop: the pop-up listening while the sentence is recognised word by word."""
    quit_shoot(); launch_shoot()
    note("yap.debug.closeWindow"); time.sleep(1.2)
    note("yap.debug.marketing", "on"); time.sleep(1.5)
    note("yap.debug.waveboost", "2.3")
    note("yap.debug.panellook", "accent||0.35|accent|"); time.sleep(0.4)
    note("yap.debug.stagepanel", "expanded| |1.7"); time.sleep(2.5)
    park_offscreen()
    w = panel_window()
    if not w: raise SystemExit("no panel window on the isolated copy")
    total = int(seconds * FPS)
    words = sentence.split()
    lead = int(FPS * 1.2)                       # a beat of empty wave before the first word
    tail = int(FPS * 1.8)                       # and a beat holding the finished sentence
    per = max(1, (total - lead - tail) // max(1, len(words)))
    shown = -1
    def on_frame(i, t):
        nonlocal shown
        n = 0 if i < lead else min(len(words), (i - lead) // per + 1)
        if n != shown:
            shown = n
            note("yap.debug.stagetext", " ".join(words[:n]))
    got = capture_frames(w["id"], total, 1.0 / FPS, "1.7", on_frame=on_frame)
    print(f"   captured {got}/{total} frames")
    assemble("dictation")

def park_offscreen():
    """Push the isolated copy's windows to the screen edge. macOS clamps them a little way on,
    which is fine: screencapture -l reads a window's own buffer even when it is covered."""
    pid = sh(f'pgrep -f "{SHOOT_APP}/Contents/MacOS/YapToText"', check=False, capture=True).split()
    if pid: sh(f'swift /tmp/movewin.swift {pid[0]} -3000 200', check=False)
    time.sleep(0.6)

# ---------------------------------------------------------------- clip: quick edit
def clip_quick_edit(seconds=9, instruction="make it sound more formal"):
    """The Quick Edit card carrying an instruction from listening through to Done."""
    # A clean process each time: hidden panels from an earlier take still report as windows,
    # and the Quick Edit card is close enough in size to the dictation panel that a stale one
    # gets picked instead. Relaunching is cheaper than guessing which window is live.
    quit_shoot(); launch_shoot()
    note("yap.debug.closeWindow"); time.sleep(1.0)
    note("yap.debug.marketing", "on"); time.sleep(1.0)
    note("yap.debug.waveboost", "1.9"); time.sleep(0.3)
    note("yap.debug.qestage", f"listening|{instruction}"); time.sleep(2.5)
    park_offscreen()
    cards = [x for x in shoot_windows() if x["layer"] >= 1 and 300 <= x["w"] <= 420 and 110 <= x["h"] <= 200]
    w = max(cards, key=lambda x: x["id"]) if cards else None
    if not w: raise SystemExit(f"no Quick Edit card; windows={shoot_windows()}")
    print("   card window:", w)
    total = int(seconds * FPS)
    listen_end = int(total * 0.52)          # hearing the instruction
    work_end = int(total * 0.82)            # applying it
    stage = None
    def on_frame(i, t):
        nonlocal stage
        want = "listening" if i < listen_end else ("working" if i < work_end else "done")
        if want != stage:
            stage = want
            if want == "listening": note("yap.debug.qestage", f"listening|{instruction}")
            elif want == "working": note("yap.debug.qestage", f"working|{instruction}")
            else:                   note("yap.debug.qestage", "done|Done")
            time.sleep(0.35)        # let the card cross-fade into the new stage
    got = capture_frames(w["id"], total, 1.0 / FPS, "1.9", on_frame=on_frame)
    print(f"   captured {got}/{total} frames")
    note("yap.debug.qestage", "off")
    assemble("quick-edit")

def install():
    n = 0
    for name in ("dictation", "quick-edit", "intelligent-insert"):
        for ext in ("mp4", "webm", "jpg"):
            src = os.path.join(OUT, f"{name}.{ext}")
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(SITE_VIDEO, f"{name}.{ext}"))
                print("installed", f"{name}.{ext}", os.path.getsize(src) // 1024, "KB"); n += 1
    print(f"{n} files -> {SITE_VIDEO}")
