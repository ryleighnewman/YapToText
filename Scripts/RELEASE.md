# Release procedure

Every shipped version goes to THREE places. Missing one is how a release ends up
inconsistent: the App Store on a new build, GitHub still on the old tag, Homebrew serving
a version nobody is running.

    1. Mac App Store    Scripts/archive-upload.sh
    2. GitHub           commit + tag + release
    3. Homebrew         Scripts/release-homebrew.sh   <- the one that gets forgotten

## Before building

- [ ] Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in project.pbxproj.
- [ ] Update the top entry in `Support/Changelog.swift` to the SAME version and build.
      The heading users see comes from this string, not from the bundle, so a mismatch
      is visible in What's New.
- [ ] A rejected build number is burned. Apple will not accept it again even after the
      binary is fixed, so bump the build rather than re-uploading.

## 1. Mac App Store

    ./Scripts/archive-upload.sh

The script refuses to upload unless all of these hold, because each one has caused a real
rejection or a shipped bug:

- The Q5 speech model is bundled and the full FP16 model is NOT (1.3 shipped the wrong one
  and the size and speed claims in its release notes were false for every user).
- No extended attributes anywhere in the bundle. `com.apple.quarantine` rides along on any
  downloaded model via `cp -c` and gets the package rejected as ITMS-91109.

Verify the archive, not the project file:

    plutil -p <archive>/Products/Applications/YapToText.app/Contents/Info.plist | grep Version

Then in App Store Connect: create the version, select the build, paste the release notes,
submit.

## 2. GitHub

    git add -A && git commit -m "<version> (<build>)"
    git tag v<version>-<build>
    git push origin main && git push origin v<version>-<build>
    gh release create v<version>-<build> --title "<version> (<build>)" --notes-file <notes>

Commit messages are just the version.

## 3. Homebrew

    ./Scripts/release-homebrew.sh

Run this AFTER the GitHub release exists, since it attaches the zip to that release. It
builds without the models, signs with Developer ID, notarizes, staples, checks that
Gatekeeper would accept the result, uploads the zip, and rewrites the cask's version and
sha256.

Then push the tap:

    cd ~/Desktop/Apps/homebrew-yaptotext
    git add -A && git commit -m "yaptotext <version>" && git push

Verify without installing (installing would replace the App Store copy in /Applications):

    brew update && brew fetch --cask ryleighnewman/yaptotext/yaptotext

### Why the Homebrew build differs

It ships WITHOUT the speech and cleanup models. With them the app is 2.8 GB, past GitHub's
2 GB per-asset limit; without them it is about 18 MB. The app downloads models on demand
and falls back to Apple's speech engine until one is installed, and the cask's caveats say
so at install time.

### Requirements

- A `Developer ID Application` certificate in the login keychain (NOT the App Store cert).
- A notarytool profile named `YapToTextNotary`.

Only delete an old GitHub release once the new one carries the Homebrew zip. The cask
downloads from a specific tag, so deleting the tag it points at breaks every install.
