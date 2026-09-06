#!/usr/bin/env python3
"""Believable demo data for marketing captures: history.json and vocabulary.json.
Writes to the given directory (the app's container Application Support folder).
Never run against real data without the byte-for-byte backup shoot_v5.py makes first."""
import json, os, random, sys, uuid
from datetime import datetime, timedelta

out_dir = sys.argv[1]
random.seed(15)
MODES = {"Auto": None, "Clean Up": "11111111-0000-0000-0000-000000000002", "Note": "11111111-0000-0000-0000-000000000003",
         "Email": "11111111-0000-0000-0000-000000000004", "Message": "11111111-0000-0000-0000-000000000005",
         "Raw Transcription": "11111111-0000-0000-0000-000000000001"}
APPS = [("Mail", "com.apple.mail"), ("Notes", "com.apple.Notes"), ("Messages", "com.apple.MobileSMS"),
        ("Safari", "com.apple.Safari"), ("Pages", "com.apple.iWork.Pages"), ("Slack", "com.tinyspeck.slackmacgap")]
LINES = [
    ("um so the meeting moved to thursday at ten can you send the deck before then", "The meeting moved to Thursday at 10. Can you send the deck before then?", "Message"),
    ("dear sam thanks for the quick turnaround on the mockups i'll review them tonight and send notes in the morning", "Dear Sam,\n\nThanks for the quick turnaround on the mockups. I'll review them tonight and send notes in the morning.\n\nBest,\nRyleigh", "Email"),
    ("groceries for the week eggs oat milk spinach coffee and the good bread", "Groceries for the week: eggs, oat milk, spinach, coffee, and the good bread.", "Note"),
    ("accessibility made free and beautiful", "Accessibility made free and beautiful.", "Clean Up"),
    ("remind me to call the pharmacy about the refill before five", "Remind me to call the pharmacy about the refill before five.", "Note"),
    ("hey are we still on for lunch friday i'm thinking the thai place", "Hey, are we still on for lunch Friday? I'm thinking the Thai place.", "Message"),
    ("the wheelchair ramp at the side entrance needs a new threshold plate the current one lifts at the edge", "The wheelchair ramp at the side entrance needs a new threshold plate. The current one lifts at the edge.", "Clean Up"),
    ("chapter three notes the narrator is unreliable from the first page and the house is a character", "Chapter three notes: the narrator is unreliable from the first page, and the house is a character.", "Note"),
    ("hi jordan the invoice for august is attached let me know if the po number looks right", "Hi Jordan,\n\nThe invoice for August is attached. Let me know if the PO number looks right.\n\nThanks,\nRyleigh", "Email"),
    ("can you grab the mail on your way in", "Can you grab the mail on your way in?", "Message"),
    ("ideas for the talk start with the story then the demo then the numbers keep it under twenty minutes", "Ideas for the talk: start with the story, then the demo, then the numbers. Keep it under twenty minutes.", "Note"),
    ("my hands don't work so i built this", "My hands don't work, so I built this.", "Clean Up"),
    ("running about ten minutes late go ahead and order for me", "Running about ten minutes late. Go ahead and order for me.", "Message"),
    ("physical therapy tuesday and thursday at nine bring the resistance bands", "Physical therapy Tuesday and Thursday at nine. Bring the resistance bands.", "Note"),
    ("dear dr patel following up on the referral could your office send the records to the new clinic", "Dear Dr. Patel,\n\nFollowing up on the referral: could your office send the records to the new clinic?\n\nThank you,\nRyleigh", "Email"),
    ("the new build fixes the pop up position and the quick edit key", "The new build fixes the pop-up position and the Quick Edit key.", "Clean Up"),
]
records = []
now = datetime.now()
for i in range(48):
    raw, final, mode = LINES[i % len(LINES)]
    app, bid = random.choice(APPS)
    when = now - timedelta(days=random.randint(0, 27), hours=random.randint(7, 22), minutes=random.randint(0, 59))
    dur = round(len(raw.split()) / 2.6 + random.uniform(0.4, 1.6), 1)
    whisper = round(random.uniform(0.28, 0.7), 2); cleanup = round(random.uniform(0.5, 1.4), 2) if mode != "Raw Transcription" else None
    rec = {
        "id": str(uuid.uuid4()).upper(),
        "date": (when - datetime(2001, 1, 1)).total_seconds(),
        "rawText": raw.capitalize() + ("." if not raw.endswith("?") else ""),
        "finalText": final,
        "deliveredText": final + " ",
        "modeName": mode,
        "modeID": MODES.get(mode),
        "durationSeconds": dur,
        "appName": app, "appBundleID": bid,
        "localeIdentifier": "en-US",
        "usedAI": mode != "Raw Transcription",
        "outcome": "pasted",
        "processSeconds": round(whisper + (cleanup or 0) + 0.02, 2),
        "cleanupModel": ("Phi-3.5 Mini Instruct" if mode != "Raw Transcription" else None),
        "whisperSeconds": whisper, "cleanupSeconds": cleanup, "deliverySeconds": 0.01,
        "autoVerdict": {"Email": "email", "Message": "message", "Note": "note", "Clean Up": "cleanup"}.get(mode),
    }
    records.append(rec)
records.sort(key=lambda r: r["date"], reverse=True)
with open(os.path.join(out_dir, "history.json"), "w") as f:
    json.dump(records, f, indent=2)

vocab = {
    "migratedMacOSFix": True, "migratedYapFix": True, "learned": [],
    "dictionaries": [{
        "id": str(uuid.uuid4()).upper(), "name": "General", "enabled": True,
        "replacements": [
            {"id": str(uuid.uuid4()).upper(), "from": f, "to": t, "caseSensitive": False, "wholeWord": True}
            for f, t in [("riley", "Ryleigh"), ("rylee", "Ryleigh"), ("reilly", "Ryleigh"),
                         ("iphone", "iPhone"), ("ipad", "iPad"), ("airpods", "AirPods"), ("macos", "macOS"),
                         ("mac os", "macOS"), ("youtube", "YouTube"), ("you tube", "YouTube"), ("wifi", "Wi-Fi"),
                         ("yap to text", "YapToText"), ("yep to text", "YapToText"), ("yep, to text", "YapToText"),
                         ("yup to text", "YapToText"), ("yap two text", "YapToText"), ("yep two texts", "YapToText"),
                         ("bit to text", "YapToText"), ("yaptotext", "YapToText"),
                         ("permobil", "Permobil"), ("perm mobile", "Permobil"), ("tik tok", "TikTok")]
        ]}, {
        "id": str(uuid.uuid4()).upper(), "name": "Medical", "enabled": True,
        "replacements": [
            {"id": str(uuid.uuid4()).upper(), "from": f, "to": t, "caseSensitive": False, "wholeWord": True}
            for f, t in [("new romuscular", "neuromuscular"), ("physio", "physical therapy"), ("o t", "OT")]
        ]}]
}
with open(os.path.join(out_dir, "vocabulary.json"), "w") as f:
    json.dump(vocab, f, indent=2)
print(f"seeded {len(records)} records + 2 dictionaries into {out_dir}")
