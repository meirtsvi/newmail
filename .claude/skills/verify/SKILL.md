---
name: verify
description: Build, launch, and observe the newmail macOS app to verify changes at the GUI surface.
---

# Verifying newmail changes

Debug builds go straight into /Applications (see project.yml) and this is the
user's daily-driver mail app — quitting/relaunching it is expected during
verification but keep it brief.

## Build & launch

```bash
xcodegen generate                     # after adding/removing source or resource files
xcodebuild -project newmail.xcodeproj -scheme newmail -configuration Debug build
osascript -e 'quit app "newmail"'     # an old instance survives rebuilds — always restart
open /Applications/newmail.app
```

The resources build phase does NOT remove files deleted from Resources/ —
after removing a bundled resource, `rm -rf /Applications/newmail.app` and
rebuild, then confirm with `find /Applications/newmail.app -name <file>`.

## Observe

- Screenshot: `screencapture -x <scratchpad>/shot.png` then Read it
  (permission already granted to the host terminal).
- App state on disk: `~/Library/Application Support/newmail/` (message cache).
- Google OAuth credentials/token: Keychain items, service
  `newmail.google-oauth`, accounts `client` and `token` — check with
  `security find-generic-password -s newmail.google-oauth -a client`.

## Gotchas

- UI automation via System Events: `sheet 1 of window 1` doesn't resolve for
  SwiftUI sheets, and a recursive AXButton walk times out on the message
  table (hundreds of rows). Prefer screenshots + coordinate clicks, and
  re-screenshot before sending keystrokes — the user may be active at the
  machine and frontmost can change under you.
- The app is single-instance (LSMultipleInstancesProhibited): `open` focuses
  the running (possibly stale) instance instead of launching the new build.
