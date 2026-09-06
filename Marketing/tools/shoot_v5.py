#!/usr/bin/env python3
"""Stage the Mac and capture every shot posters_v5.py needs, with NO audio: the panel and
the Quick Edit card are driven by the app's debug staging hooks (synthesized speech).
Follows PLAYBOOK.md sections 2-5. Run from Marketing/:  python3 tools/shoot_v5.py
Restores wallpaper, hidden apps, and the real data files when done (or on error)."""
import json, os, shutil, subprocess, sys, time
from PIL import Image, ImageDraw

MK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(MK, "tools")
OUT = os.path.join(MK, "shots-v5"); os.makedirs(OUT, exist_ok=True)
APP = os.path.expanduser("~/Library/Caches/YapToTextDD/Build/Products/Debug/YapToText.app")
DATA = os.path.expanduser("~/Library/Containers/YapToText/Data/Library/Application Support/YapToText")
BACKUP = os.path.join(MK, ".staging-backup"); os.makedirs(BACKUP, exist_ok=True)
SENTENCE = "Accessibility made free and beautiful."

def sh(cmd, check=True, capture=False):
    r = subprocess.run(cmd, shell=True, check=check, capture_output=capture, text=True)
    return r.stdout.strip() if capture else None

def osa(script): return sh(f"osascript -e '{script}'", check=False, capture=True)

def note(name, obj=None):
    o = f' "{obj}"' if obj is not None else ""
    sh(f"swift /tmp/postnote2.swift {name}{o}", check=False)

def swiftrun(tool, *args):
    return sh(f"swift {os.path.join(TOOLS, tool)} " + " ".join(str(a) for a in args), check=False, capture=True)

def quit_app():
    sh("pkill -x YapToText", check=False)
    for _ in range(40):
        if sh("pgrep -x YapToText", check=False, capture=True) == "": return
        time.sleep(0.25)
    raise SystemExit("YapToText did not quit")

def has_sheet():
    """A What's New / onboarding sheet over the main window (480-wide layer-0 window)."""
    out = swiftrun("winids.swift")
    for line in out.splitlines():
        num, size, layer = line.split()
        w, h = map(int, size.split("x"))
        if 440 <= w <= 560 and layer.endswith("=0"): return True
    return False

def launch_app():
    """`open` right after a kill can fail with LaunchServices -600; retry until the process is up."""
    for _ in range(6):
        sh(f'open "{APP}"', check=False)
        for _ in range(12):
            time.sleep(0.5)
            if sh("pgrep -x YapToText", check=False, capture=True): return
    raise SystemExit("YapToText did not launch")

def main_window():
    out = swiftrun("winbounds.swift")
    for line in out.splitlines():
        x, y, w, h = map(int, line.split())
        if w >= 800: return x, y, w, h
    return None

def window_id(w_min, w_max, h_max, layer_min=0, exclude=()):
    out = swiftrun("winids.swift")
    for line in out.splitlines():
        num, size, layer = line.split()
        w, h = map(int, size.split("x")); layer = int(layer.split("=")[1])
        if w_min <= w <= w_max and h <= h_max and layer >= layer_min and num not in exclude:
            return num, w, h
    return None

def rect_of(num):
    out = swiftrun("winrect.swift", num)
    return tuple(map(int, out.split()))

def capture(name, rect, win_id, radius=None, solid=False):
    """Region capture (keeps glass) + the window's own alpha from a -l capture.
    solid=True lifts a material window's partial interior alpha to opaque (edges stay soft),
    so a translucent card is captured exactly as it looks over the studio wallpaper."""
    x, y, w, h = rect
    raw = os.path.join(OUT, f"_raw-{name}.png"); mask = os.path.join(OUT, f"_mask-{name}.png")
    sh(f'screencapture -x -R "{x},{y},{w},{h}" "{raw}"')
    sh(f'screencapture -o -x -l {win_id} "{mask}"', check=False)
    img = Image.open(raw).convert("RGBA")
    if os.path.exists(mask):
        m = Image.open(mask).convert("RGBA")
        if m.size != img.size: m = m.resize(img.size, Image.LANCZOS)
        a = m.split()[3]
        if solid:
            # Opaque interior, but the edge is re-cut 1px inside the window so no shadow pixel
            # from the region capture survives as a dark fringe; then softened.
            from PIL import ImageFilter
            a = a.point(lambda v: 255 if v > 8 else 0).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
        img.putalpha(a)
        os.remove(mask)
    elif radius:
        SS = 4
        big = Image.new("L", (img.width * SS, img.height * SS), 0)
        ImageDraw.Draw(big).rounded_rectangle([2 * SS, 2 * SS, img.width * SS - 2 * SS, img.height * SS - 2 * SS], radius=radius * SS, fill=255)
        img.putalpha(big.resize(img.size, Image.LANCZOS))
    bbox = img.getbbox()
    if bbox: img = img.crop(bbox)
    img.save(os.path.join(OUT, f"{name}.png")); os.remove(raw)
    print("captured", name, img.size)

state = {}
def capture_on_backdrop(name, win_id):
    """Translucent card: its own alpha capture over a synthetic dark glass gradient, so
    nothing behind it (wallpaper brightness, icons) decides how it looks."""
    tmp = os.path.join(OUT, f"_alpha-{name}.png")
    sh(f'screencapture -o -x -l {win_id} "{tmp}"')
    card = Image.open(tmp).convert("RGBA"); os.remove(tmp)
    bbox = card.getbbox()
    if bbox: card = card.crop(bbox)
    grad = Image.new("RGBA", card.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for yy in range(card.height):
        t = yy / max(1, card.height - 1)
        r = int(58 + (26 - 58) * t); g = int(30 + (22 - 30) * t); b = int(96 + (70 - 96) * t)
        gd.line([(0, yy), (card.width, yy)], fill=(r, g, b, 255))
    grad = grad.filter(__import__("PIL.ImageFilter", fromlist=["GaussianBlur"]).GaussianBlur(40))
    grad.putalpha(card.split()[3])          # backdrop only where the card is
    out = Image.alpha_composite(grad, card)
    out.save(os.path.join(OUT, f"{name}.png"))
    print("captured", name, out.size, "(alpha on backdrop)")

PLIST = os.path.expanduser("~/Library/Containers/YapToText/Data/Library/Preferences/YapToText.plist")
KEY = "com.ryleighnewman.YapToText.settings"

def settings_blob(path=PLIST):
    import plistlib
    return json.loads(plistlib.load(open(path, "rb"))[KEY])

def stage_settings():
    """The look every shot shares (blue accent, accent tint + wave, purple Quick Edit card, no name)
    is applied IN MEMORY by the app's yap.debug.marketing hook with preference writes suspended,
    so the user's values never leave disk. Editing the plist file while quit does not work:
    cfprefsd hands the app its cached copy and the edit is lost."""
    shutil.copy2(PLIST, os.path.join(BACKUP, "YapToText.plist"))   # safety copy only, never restored blindly
    note("yap.debug.marketing", "on"); time.sleep(2)

def restore_settings():
    """Hook off (user values back in memory and saved), then prove the file matches the safety copy."""
    note("yap.debug.marketing", "off"); time.sleep(2)

def check_settings_restored():
    """Every preference key, the settings blob (as JSON) and the window frames alike."""
    import plistlib
    src = os.path.join(BACKUP, "YapToText.plist")
    if not os.path.exists(src): return
    before, after = plistlib.load(open(src, "rb")), plistlib.load(open(PLIST, "rb"))
    changed = set()
    for k in set(before) | set(after):
        a, b = before.get(k), after.get(k)
        if k == KEY and a is not None and b is not None: a, b = json.loads(a), json.loads(b)
        if a != b: changed.add(k)
    if changed: print("WARNING: preference keys differ from the pre-shoot copy:", sorted(changed))
    else: print("preferences verified identical to the pre-shoot copy (settings + window frames)")

def stage_begin():
    state["desktop_icons"] = sh("defaults read com.apple.finder CreateDesktop", check=False, capture=True) or "1"
    sh("defaults write com.apple.finder CreateDesktop -bool false && killall Finder", check=False)
    state["wallpaper"] = osa('tell application "System Events" to get picture of desktop 1')
    state["visible"] = osa('tell application "System Events" to get name of every process whose visible is true and name is not "Finder" and name is not "YapToText"')
    for f in ("history.json", "vocabulary.json", "smart-dictionary.json"):
        p = os.path.join(DATA, f)
        if os.path.exists(p): shutil.copy2(p, os.path.join(BACKUP, f))
    print("state saved:", state)

def stage_end():
    note("yap.debug.stagepanel", "off"); note("yap.debug.qestage", "off"); note("yap.debug.waveboost", "1")
    restore_settings()
    quit_app()
    check_settings_restored()
    for f in ("history.json", "vocabulary.json", "smart-dictionary.json"):
        src = os.path.join(BACKUP, f); dst = os.path.join(DATA, f)
        if os.path.exists(src): shutil.copy2(src, dst)
        elif os.path.exists(dst): os.remove(dst)
    launch_app()
    if state.get("wallpaper"):
        osa(f'tell application "System Events" to tell every desktop to set picture to "{state["wallpaper"]}"')
    for name in (state.get("visible") or "").split(", "):
        if name: osa(f'tell application "System Events" to set visible of process "{name}" to true')
    icons = state.get("desktop_icons", "1").strip().lower() in ("1", "true", "yes")
    sh(f"defaults write com.apple.finder CreateDesktop -bool {'true' if icons else 'false'} && killall Finder", check=False)
    print("restored")

def ensure_main(pg, tries=6):
    """Main window bounds, or None. Stage Manager parks a non-active app's window as a thumbnail
    in the left strip (CG reports it ~96x121 at a negative x); activating brings it back on stage."""
    for _ in range(tries):
        mw = main_window()
        if mw: return mw
        osa('tell application "YapToText" to activate'); time.sleep(0.8)
        note("yap.debug.goto", pg); time.sleep(1.5)
    print("window list:", swiftrun("winlist.swift"))
    return None

def main():
    stage_begin()
    try:
        settings = settings_blob()
        state["style"] = settings.get("panelStyle", "expanded")
        # 1. demo data in, app relaunched on it - and PROVEN to be on it before any capture
        quit_app()
        sh(f'python3 "{os.path.join(TOOLS, "seed_demo_data.py")}" "{DATA}"')
        for attempt in range(3):
            launch_app(); time.sleep(9)
            note("yap.debug.whatsnew", "close"); note("yap.debug.welcome", "close"); time.sleep(1.5)
            live = json.load(open(os.path.join(DATA, "history.json")))
            if len(live) == 48 and "mockups" in json.dumps(live): break
            print(f"seed not live (records={len(live)}), re-seeding (attempt {attempt + 1})")
            quit_app(); time.sleep(2)
            sh(f'python3 "{os.path.join(TOOLS, "seed_demo_data.py")}" "{DATA}"')
        else:
            raise SystemExit("seed did not take (real data still live) - aborting before any capture")
        stage_settings()
        # 2. the studio: colorful wallpaper, nothing else on screen
        osa('tell application "System Events" to tell every desktop to set picture to "/System/Library/Desktop Pictures/Mac Purple.heic"')
        osa('tell application "System Events" to set visible of (every process whose visible is true and name is not "Finder" and name is not "YapToText") to false')
        time.sleep(8)
        osa('tell application "YapToText" to activate'); time.sleep(1)
        note("yap.debug.goto", "home"); time.sleep(2)
        mw = ensure_main("home")
        if not mw: raise SystemExit("no main window")
        # activate + one sidebar click so the selection renders in color (PLAYBOOK 3)
        x, y, w, h = mw
        sh(f"swift {os.path.join(TOOLS, 'click.swift')} {x + 113} {y + 179}", check=False); time.sleep(1.2)
        # 3. pages
        pages = ["home", "dictation", "quickEdit", "modes", "models", "dictionaries", "commands", "history", "stats", "settings"]
        for pg in pages:
            note("yap.debug.goto", pg); time.sleep(2.6)
            if has_sheet():
                note("yap.debug.whatsnew", "close"); note("yap.debug.welcome", "close"); time.sleep(1.5)
                if has_sheet(): raise SystemExit("a sheet is covering the window - aborting")
            mw = ensure_main(pg)
            if not mw: raise SystemExit(f"no main window for {pg}")
            wid = window_id(800, 4000, 4000)
            capture(f"page-{pg}", mw, wid[0] if wid else 0, radius=26)
        note("yap.debug.goto", "history"); time.sleep(2); ensure_main("history")
        note("yap.debug.historyexpand"); time.sleep(1.8)
        mw = main_window(); wid = window_id(800, 4000, 4000)
        if mw: capture("pipeline-details", mw, wid[0] if wid else 0, radius=26)
        # 4. panels: main window out of the way, real glass panel with synthesized speech
        note("yap.debug.closeWindow"); time.sleep(1.5)
        # One look per layout, as in the shipped sets: blue accent, hot pink, and RGB rainbow.
        # The wave is fed saturated synthetic speech and drawn with the amplitude boost.
        PANEL_LOOKS = {"expanded": "accent||0.35|accent|",
                       "compact": "custom|#FF375F|0.38|custom|#FF375F",
                       "mini": "rainbow||0.35|rgb|"}
        # The expanded band is only 26pt tall, so it needs more boost to fill; 2.8 clips it.
        BOOST = {"expanded": "2.3", "compact": "1.6", "mini": "1.6"}
        for style in ("expanded", "compact", "mini"):
            note("yap.debug.waveboost", BOOST[style])
            note("yap.debug.panellook", PANEL_LOOKS[style]); time.sleep(0.5)
            note("yap.debug.stagepanel", f"{style}|{SENTENCE}|1.7"); time.sleep(3.4)
            pw = window_id(280, 620, 420, layer_min=1)
            if not pw: print("no panel window for", style); continue
            capture(f"panel-{style}", rect_of(pw[0]), pw[0])
            note("yap.debug.stagepanel", "off"); time.sleep(1.4)
        note("yap.debug.waveboost", "1")
        # 5. Quick Edit card in each stage, over a flat deep-violet desktop so the material
        #    shows the card's own tint instead of the wallpaper's shapes
        flat = os.path.join(BACKUP, "flat-violet.png")
        Image.new("RGB", (640, 400), (52, 28, 92)).save(flat)
        osa(f'tell application "System Events" to tell every desktop to set picture to "{flat}"'); time.sleep(2.5)
        for stage_name, text, out in (("listening", "make it sound more formal", "qe-listening"),
                                      ("working", "make it sound more formal", "qe-working"),
                                      ("done", "Done", "qe-done")):
            note("yap.debug.qestage", f"{stage_name}|{text}"); time.sleep(2.2)
            qw = window_id(300, 420, 220, layer_min=1)
            if not qw: print("no quick edit window for", stage_name); continue
            capture(out, rect_of(qw[0]), qw[0], solid=True)   # over the wallpaper, like in use
        note("yap.debug.qestage", "off"); time.sleep(1)
        osa('tell application "System Events" to tell every desktop to set picture to "/System/Library/Desktop Pictures/Mac Purple.heic"'); time.sleep(2.5)
        # 6. menu bar popover
        note("yap.debug.menupopover"); time.sleep(2.2)
        pop = window_id(300, 800, 1200, layer_min=1)
        if pop: capture("popover", rect_of(pop[0]), pop[0])
        note("yap.debug.menupopover"); time.sleep(1)
    finally:
        stage_end()

if __name__ == "__main__":
    main()
