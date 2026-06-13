# newmail

Native macOS (SwiftUI) mail client reading Gmail via the Gmail REST API.
This is the **MVP**: Gmail-first, read-complete, with write actions wired and
gated on token scope. See `PLAN.md` for the full design and roadmap.

## What works today

- **Auth** — reuses the existing `token.json` refresh token (no browser login).
  Access tokens are refreshed automatically. Account: `meirt@jfrog.com`.
- **3-pane UI** — Favorites + folder tree | sortable message Table | HTML preview.
- **Reading** — folders with unread counts, inbox/folder message lists, sorting
  by From / Subject / Date, message bodies rendered in WKWebView, attachments listed.
- **Search** — current-folder and all-folder (Gmail `q` / search).
- **Actions** (toolbar + row hover + right-click): reply / reply-all / forward,
  delete (trash), archive, move, mark read/unread, flag, snooze.
- **Snooze** — Later Today / Tomorrow / Next Week / Next Month / custom; moves to a
  `Snoozed` label and a 60s timer returns expired messages to the Inbox.
- **Rich compose** — new/reply/reply-all/forward with a rich-text body
  (bold/italic/underline/link) and file attachments, sent as multipart/mixed HTML.
- **Offline cache** — folders, headers, and opened bodies are cached in SwiftData,
  so the UI paints instantly from cache on launch/selection and keeps working
  offline; the network reconciles into the cache in the background.

## Build & run

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open newmail.xcodeproj          # then ⌘R in Xcode
# or headless:
xcodebuild -project newmail.xcodeproj -scheme newmail -configuration Debug \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

`token.json` is bundled into the app and copied to
`~/Library/Containers/com.meirt.newmail/Data/Library/Application Support/newmail/`
on first launch (the app refreshes/persists tokens there).

## Interactive OAuth sign-in (branch: oauth-interactive-login)

This branch adds a real Google OAuth 2.0 flow (PKCE over a loopback redirect — the
desktop "installed app" pattern) as an alternative to the bundled read-only token.

When the token lacks write scope, the message-list header shows **"Sign in with
Google for write access"**. Clicking it:
1. Opens your default browser to Google's consent screen for this app, requesting
   `gmail.modify` + `gmail.send`.
2. If your organization blocks the app, the returned error is shown (this is how to
   check whether the org permits it).
3. On consent, a local loopback server captures the code, exchanges it for a
   read+write token, and stores it in Application Support — enabling delete, move,
   snooze, and send.

Requires the `com.apple.security.network.server` entitlement (added on this branch)
for the loopback listener. Reuses the bundled client_id/secret so the consent screen
reflects this exact app.

## Read-only token — enabling writes

The current `token.json` has scope **`gmail.readonly`**, so all read features work
but **mark-read, move, archive, delete, snooze, and send return HTTP 403**. The app
shows a "Read-only token" banner when this is the case.

To enable writes, regenerate `token.json` with broader scopes using the existing
Python flow — change `SCOPES` to:

```python
SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",  # read + move/label/read-state/trash
    "https://www.googleapis.com/auth/gmail.send",    # sending
]
```

Delete the old `token.json`, run the script once to re-consent in the browser, then
copy the new `token.json` into this folder (and into `Resources/`) and rebuild.

## Not yet implemented (see PLAN.md)

- Microsoft Graph (Outlook.com) provider — abstraction is in place (`MailProvider`).
- Background unread-count refresh for custom labels; remote-image blocking toggle;
  configurable favorites / quick-move buttons / settings window.

## Security note

`token.json` and `credentials.json` contain a refresh token and client secret.
They are `.gitignore`d. Do not commit them.
