# OSToolbar

[![Release](https://img.shields.io/github/v/release/hasansahinnn/os-toolbar?sort=semver)](https://github.com/hasansahinnn/os-toolbar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/hasansahinnn/os-toolbar/total)](https://github.com/hasansahinnn/os-toolbar/releases)
[![License](https://img.shields.io/github/license/hasansahinnn/os-toolbar)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/built%20with-Swift-orange?logo=swift&logoColor=white)

A lightweight macOS **menu-bar toolkit** that bundles three everyday tools in one
app — each with its own menu-bar icon:

- **📋 Clipboard history** — automatically keeps your recent copies (last 100), so
you can search and paste anything you copied earlier.
- **📸 Screenshot** — a region capture with a built-in annotation
editor (pen, line, arrow, rectangle, ellipse, highlighter, text), color and size
controls, then copy, save, or save-as — plus a one-key full-screen grab.
- **📝 Notes** — a Notes-style editor with real folders on disk, rich text
(checklists, tables, links, images), color flags with grouping, search, and
**reminders/alarms** that pop up at a time you set.

It lives quietly in the menu bar — no Dock icon, no window clutter.

> Requires **macOS Sonoma 14 or later**, Apple Silicon.

## Screenshots

**Clipboard history**

![Clipboard history](images/ClipBoard.png)

**Screenshot capture & annotation**

![Screenshot tool](images/ScreenShot.png)

**Notes with folders, color groups & alarms**

![Notes](images/Notes.png)

---

## 🔒 Privacy & safety

OSToolbar is designed to be safe and self-contained:

- **No network access at all.** The app contains **zero HTTP/network requests** —
no telemetry, no analytics, no auto-update calls, nothing leaves your machine.
This is enforced at the OS level: the app is **sandboxed** and ships **without**
the network entitlement, so macOS itself blocks any outbound connection.
- **Everything stays on your Mac, as plain files.** Clipboard history lives in the
app's sandbox container; screenshots are saved where you choose; notes are stored as
ordinary files/folders in `~/Documents/OSToolbarNotes` (rich text + a small JSON of
metadata) — no database, so you can read, back up, or sync them yourself.
- **Passwords are never stored.** Clipboard history ignores password-manager and
`concealed`/`transient` pasteboard entries, so copied passwords aren't captured.
- **Reminders are local.** Note alarms are fired by the app itself while it runs —
no push service, no account, nothing leaves the machine.

You can verify this yourself — search the source: there are no `URLSession`,
`URLRequest`, or networking calls anywhere in the app.

---

## ✅ Verify it's safe (free public tools)

Don't take our word for it — verify it yourself with free tools:

### Scan with VirusTotal (free, 70+ antivirus engines)

The release DMG has been scanned by 70+ antivirus engines:

**▶ [VirusTotal report for OSToolbar-v1.0.0.dmg](https://www.virustotal.com/gui/file/0fd40cce8d506978bc5a24f824da10117d458d17b0c77c7484185ea90c573f00)**

`SHA-256 (DMG): 0fd40cce8d506978bc5a24f824da10117d458d17b0c77c7484185ea90c573f00`
`SHA-256 (ZIP): f21878ff01f847a828020a1031c7ffeeea6a4322ba675de87c9a6aed23911a33`

Verify the file you downloaded:

```bash
shasum -a 256 OSToolbar-v1.0.0.dmg
# expected: 0fd40cce8d506978bc5a24f824da10117d458d17b0c77c7484185ea90c573f00
```

If the hash matches, you have exactly the file we built. You can also
re-upload it at [virustotal.com](https://www.virustotal.com/gui/home/upload)
to scan it fresh against the latest engine definitions.

---

## ⬇️ Install (pre-built)

1. Download the latest DMG (or ZIP) from the [**Releases page**](https://github.com/hasansahinnn/os-toolbar/releases/latest).
2. Open the DMG and drag **OSToolbar** onto **Applications**.
3. **First launch — handle the Gatekeeper warning.** The build is signed with a
   self-signed certificate, not Apple-notarized, so macOS will show
   *"OSToolbar can't be opened because it is from an unidentified developer"*
   or *"Apple could not verify OSToolbar is free of malware"*. To bypass it once:

   **Option A — right-click → Open** *(works on macOS 14 and earlier)*
   - In Finder, **right-click (or Control-click)** OSToolbar.app → **Open**
   - Click **Open** in the dialog. macOS remembers your choice; future launches just work.

   **Option B — System Settings → Open Anyway** *(macOS 15 Sequoia and later)*
   - Double-click OSToolbar normally. macOS blocks it.
   - Open **System Settings → Privacy & Security**, scroll to the **Security** section.
   - You'll see *"OSToolbar was blocked from use…"* → click **Open Anyway**.
   - Confirm with your password / Touch ID. Done.

   Want to verify the binary first? See the [Verify it's safe](#-verify-its-safe-free-public-tools)
   section above — the DMG's SHA-256 and a clean VirusTotal report are published with every release.

4. When you first take a screenshot, macOS asks for **Screen Recording**
   permission — grant it (System Settings → Privacy & Security → Screen Recording),
   then **quit and reopen** the app once.

---

## 🚀 Usage

OSToolbar adds **three separate menu-bar icons** — one each for Clipboard,
Screenshot, and Notes — so every tool is one click away.

### ⌨️ Default shortcuts

| Action | Shortcut |
| --- | --- |
| Open clipboard history | **⌘⇧C** |
| Region screenshot (annotate) | **⌘⇧S** |
| Quick full-screen screenshot | **⌘⇧A** |
| Open screenshot folder | **⌘⇧F** |
| Open Notes | **⌘⇧N** |

All shortcuts are configurable in each tool's **Preferences**.

### 📋 Clipboard history

- Click the clipboard icon to open the history (last 100 copies).
- Type to search; press **Return** to paste the selected item.
- Pins and the footer scroll together with the list; fast scrolling stays smooth.
- Configure the open shortcut in **Settings → General**.

### 📸 Screenshot

- Click the camera icon for a menu: **Screenshot**, **Quick Screenshot**,
  **Open Image Folder**, **Preferences**.
- **⌘⇧S** starts a region capture; drag to select. A toolbar appears with:
  - **Tools:** pen, line, arrow, rectangle, ellipse, highlighter, text
  - **Color** and **size** controls, **Undo (⌘Z)**
  - **Copy (⌘C)** — copy to the clipboard (also lands in clipboard history)
  - **Save** — write straight to the default folder
  - **Save As…** — choose where to save
  - **Esc** — cancel
- **⌘⇧A** instantly captures the whole screen and saves it (with a preview thumbnail).
- Screenshots are saved to `~/Pictures/OSToolBar ScreenShot` by default; change the
  folder, shortcuts, and default color/sizes in **Screenshot → Preferences**.

### 📝 Notes

- Click the notes icon (or press **⌘⇧N**) to open the Notes window.
- **Folders (left):** real directories on disk. Create with the **＋** button, then
  type the name right away. **Single-click** a folder to open it; **click the
  selected name again** to rename (or right-click → Rename / Show in Finder / Delete).
- **Search all notes:** the **🔍** button next to ＋ opens a search box that looks
  through **every note's title and content** across all folders. Results are grouped
  **by folder**, so you can see which folder each match lives in; click a result to
  jump straight to it.
- **Notes list (middle):** title, a one-line preview, and the edited date. Create a
  note with the **✎** button (the name is editable immediately). Single-click to open,
  click the selected title again to rename. Assign a **color flag** (right-click →
  Color); notes group into **collapsible color sections**. A per-folder search box is
  also in the toolbar.
- **Editor (right):** rich text with **bold/italic/underline**, font size, an inline
  **color picker**, **bullet & checklist** (press Return to continue the list, click a
  circle to tick it), **tables**, **links**, and **images** (hover an image for a
  preview button — it's capped in size so it never floods the page). The title bar
  shows the **Created** and **Edited** times.
- **Alarms ⏰:** open the bell menu in the editor to add a reminder for any note —
  pick a date (calendar) and time, optionally a label. When it's due, a panel slides
  in at the top-right; click **Open** to jump to the note. Notes with a pending alarm
  show a bell in the list, and all upcoming alarms are listed under **Alarms** in the
  sidebar (with a *Show more* toggle).
- Notes are saved as plain files in `~/Documents/OSToolbarNotes` (rich text +
  metadata) — no database. Change the folder or the shortcut in **Notes → Preferences**.

---

## 🛠 Build from source

```sh
git clone https://github.com/hasansahinnn/os-toolbar.git
cd os-toolbar
open OSToolbar.xcodeproj   # build & run in Xcode (scheme: OSToolbar)
```

Or produce a signed, distributable DMG from the command line:

```sh
tools/build-dmg.sh
```

This builds the Release app, signs it with a local self-signed certificate, and
writes `dist/OSToolbar.dmg`. (The script expects a code-signing identity named
`OSToolbar Code Signing` in your login keychain; for a quick local run you can also
just build the `OSToolbar` scheme in Xcode.)

**Dependencies** (resolved automatically via Swift Package Manager):
Defaults, KeyboardShortcuts, Sauce, Settings, SwiftHEXColors, swift-log,
LaunchAtLogin, fuse-swift.

---

## 🙏 Credits

The clipboard-history engine is derived from the excellent open-source
**[Maccy](https://github.com/p0deje/Maccy)** by Alexey Rodionov, used under the MIT
License. The screenshot module and the menu-bar toolkit packaging are original to
this project. See [LICENSE](LICENSE) for full attribution.

## 📄 License

[MIT](LICENSE).