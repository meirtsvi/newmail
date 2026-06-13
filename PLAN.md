# newmail — Native macOS Mail Client

A native macOS SwiftUI mail app that reads **Gmail** (Gmail API) and **Outlook.com** (Microsoft Graph) over OAuth 2.0, with a 3-pane Outlook-style UI, sortable message list, move/snooze/quick-actions, and search.

> Status: **Finalized plan, pre-implementation.** Open decisions are listed at the bottom.

---

## 1. Locked decisions

| Decision | Choice |
|---|---|
| Mail access | Native REST APIs — Gmail API + Microsoft Graph (no IMAP, no MAPI) |
| Auth | **Reuse existing `token.json` refresh token** (from the user's Python flow). No interactive browser login; the app refreshes access tokens directly. Account in use: `meirt@jfrog.com` (Google Workspace). |
| Local store | SwiftData |
| Snooze background | App-running only (60s timer while app is open) |
| Min OS | macOS 15 Sequoia |
| UI | SwiftUI `NavigationSplitView`, 3 panes, Outlook-style |

---

## 2. Architecture

```
SwiftUI App (macOS 15+)
  NavigationSplitView:  Sidebar | Message Table | Preview
        │
  ViewModels  ·  MessageActions (shared command layer: toolbar = hover = context menu)
        │
  SyncEngine            SnoozeService (60s timer)
        │
  Local store (SwiftData): Account, Folder, MessageHeader, MessageBody?, SnoozeRecord, SyncCursor
        │
  MailProvider protocol
    ├── GmailProvider   (Gmail API — labels as folders)
    └── GraphProvider   (Microsoft Graph — real mail folders)
        │
  AuthManager: OAuth2 PKCE + Keychain
```

**Principle:** UI and ViewModels talk only to the local store + the `MailProvider` protocol. Provider-specific quirks (Gmail labels vs Graph folders, custom-property support) never leak upward.

### Shared domain models
- `MailAccount { id, provider, email, displayName }`
- `MailFolder { id, accountID, name, parentID?, kind (inbox/sent/drafts/trash/junk/snoozed/custom), unreadCount, isFavorite }`
- `MessageHeader { id, accountID, folderIDs, from, to, subject, snippet, date, isRead, isFlagged, hasAttachments, threadID }`
- `MessageBody { headerID, html, plainText, attachments[] }`
- `Address { name, email }`
- `Attachment { id, filename, mimeType, sizeBytes }`

### `MailProvider` protocol (surface)
```
listFolders() -> [MailFolder]
listMessages(folderID, sort, pageToken?) -> (headers, nextToken?)
fetchMessage(id) -> MessageBody
move(messageIDs, toFolderID)
delete(messageIDs)                 // move to Trash
setRead(messageIDs, isRead)
setFlagged(messageIDs, isFlagged)
send(draft)                        // new / reply / replyAll / forward
search(query, scope, pageToken?) -> (headers, nextToken?)
setSnoozeProperty(messageID, wakeTime)
clearSnoozeProperty(messageID)
incrementalChanges(cursor) -> (changes, newCursor)
```

### Provider mapping notes
- **Gmail:** labels == folders; "move" = add target label + remove source label; `INBOX`, `SENT`, `TRASH`, `SPAM`, `DRAFT` are system labels. Read = remove `UNREAD`. Flag = `STARRED`. Search = `q=`. Incremental = `history.list` with `historyId`. **No arbitrary per-message custom property** → snooze wake-time stored in SwiftData + a `newmail/Snoozed` label.
- **Graph:** real `mailFolders` tree; move = `POST /messages/{id}/move`. Read/flag = PATCH. Search = `$search`. Incremental = `delta`. Snooze wake-time = real `singleValueExtendedProperties` on the message.

---

## 3. UI specification

### Layout (matches reference screenshot)
- **Sidebar:** `Favorites` section first, then one section per account (`mailbox1`, `mailbox2`, …), each an expandable folder tree with unread badges.
- **Message list:** SwiftUI `Table` — columns From, Subject, Date (+ flag/attachment/unread-dot indicators). Sortable by clicking any column header (`sortOrder` binding). Multi-row selection. Unread rows bold; flagged rows tinted.
- **Preview pane:** sender avatar (colored initials), From/To/Date header, then HTML body in a sanitized `WKWebView` (remote images blocked by default with a "load images" affordance). Per-message reply/replyAll/forward icons top-right.

### Toolbar (left→right, per screenshot)
`New Mail` · Flag▾ · Reply · Reply All · Forward · Delete · Move▾ · **[quick-move folder buttons]** · Snooze▾ · Mark Read/Unread · Sync · Block · ⋯ overflow

### Quick actions in three places, one implementation
A single `MessageActions` command set is rendered by: (a) toolbar, (b) row hover overlay (`.onHover`), (c) right-click `.contextMenu`. Actions: reply, reply-all, forward, delete, move, mark read/unread, flag, snooze.

### Search
`.searchable` field with scope picker: **Current folder** (local SwiftData query) vs **All folders** (server-side: Gmail `q`, Graph `$search`, merged across accounts).

---

## 4. Snooze design

- **Menu options:** End of today · Tomorrow · Next week · Next month · Custom (DatePicker sheet). (Exact wake times → see Open Decisions.)
- **On snooze:** move selected messages to the `Snoozed` folder (auto-created per account if missing) + record wake-time (Graph extended property; Gmail label + SwiftData `SnoozeRecord`).
- **SnoozeService:** `Timer` every 60s → finds `wakeTime <= now` → moves message back to Inbox, clears snooze property/label/record. Runs only while app is open; on launch it immediately processes any already-expired snoozes.

---

## 5. Sync engine

- Initial: fetch folder tree + first page of headers per folder on demand.
- Incremental: Gmail `historyId`, Graph `delta`; triggered by manual **Sync** button + a poll interval (push webhooks need a server, so out of scope — polling only).
- Bodies fetched lazily on selection and cached.

---

## 6. Build phases

0. **Setup** — Xcode SwiftUI project, macOS 15 target, entitlements, Info.plist URL scheme, config for OAuth client IDs.
1. **Auth** — PKCE via `ASWebAuthenticationSession`, Keychain store, refresh, multi-account add flow.
2. **Providers** — `MailProvider` + shared models; `GmailProvider`; `GraphProvider`.
3. **Store + sync** — SwiftData schema; initial + incremental sync.
4. **UI shell** — split view, sidebar sections, sortable Table, preview with HTML rendering.
5. **Actions** — toolbar/hover/context command layer; reply/replyAll/forward compose; move + quick-move.
6. **Search** — current vs all-folder, server-side.
7. **Snooze** — menu, move + property, 60s service.
8. **Polish** — styling to match reference, New Mail compose, notifications, status/error/empty states, shortcuts, tests.

---

## 7. Resolved decisions (from Q&A)

- **Dependencies:** vetted SPM packages allowed (MSAL for Microsoft auth, AppAuth/Google libs as useful).
- **Distribution:** sandboxed + hardened-runtime + notarized `.app` (App Sandbox entitlements, OAuth redirect + Keychain under sandbox).
- **Compose:** full rich-HTML compose with attachments (new / reply / reply-all / forward, inline quoting, add + view/download attachments).
- **Sequencing:** MVP first — Gmail end-to-end + 3-pane UI, then add Graph, then actions/snooze/search.
- **MVP account:** Gmail first (`meir.tsvi@gmail.com`), Graph second.
- **Delete:** moves to Trash; **separate Archive** action (Gmail: remove `INBOX`; Graph: move to Archive).
- **Notifications:** native UserNotifications banner on new unread during sync; toggle in settings.
- **Snooze wake-times (morning/evening):** End of today = 6:00 PM · Tomorrow = 8:00 AM · Next week = next Mon 8:00 AM · Next month = 1st 8:00 AM. Custom always available; editable in settings.

### Proposed defaults for remaining items (confirm or override)
1. **Favorites:** user-pinned folders, seeded with each account's Inbox; pin/unpin via right-click, drag to reorder.
2. **Quick-move toolbar buttons:** configurable in Settings, up to 4 target folders, single-click moves selection. Empty until you choose them.
3. **Block button:** blocks sender of selected message(s) — moves their existing mail to Junk + adds a provider block rule (Gmail filter; Graph blockedSenders/inbox rule), best-effort.
4. **Threading:** flat list, no conversation grouping in v1 (matches reference).
5. **Avatars:** colored initials only, no network/Gravatar.
6. **Remote images:** blocked by default, per-message "Load images".
7. **Signatures:** optional plain-text signature per account, off by default.
8. **Sync poll:** every 2 min while foreground + manual Sync; configurable.
9. **Appearance:** follow system light/dark; subtle per-account accent in sidebar.
10. **Date column:** Today→time, Yesterday→"Yesterday", older→date (matches reference).
11. **Keyboard shortcuts:** Apple Mail-like (⌘N new, ⌘R reply, ⇧⌘R reply-all, ⌘⇧F forward, ⌫ delete, ⌘⇧U unread…).
12. **List paging:** lazy/infinite scroll, 50 headers/page.
13. **Drafts:** saved server-side via provider Drafts API, auto-save while composing.
14. **Settings window:** add/remove accounts; configure favorites, quick-move targets, signatures, snooze times, poll interval.
