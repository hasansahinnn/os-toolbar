# OSToolbar

A lightweight macOS **menu-bar toolkit** that bundles two everyday tools in one app:

- **📋 Clipboard history** — automatically keeps your recent copies (last 100), so
you can search and paste anything you copied earlier.
- **📸 Screenshot** — a region capture with a built-in annotation
editor (pen, line, arrow, rectangle, ellipse, highlighter, text), color and size
controls, then copy, save, or save-as.

It lives quietly in the menu bar — no Dock icon, no window clutter.

> Requires **macOS Sonoma 14 or later**, Apple Silicon.

## Screenshots

**Clipboard history**

![Clipboard history](images/ClipBoard.png)

**Screenshot capture & annotation**

![Screenshot tool](images/ScreenShot.png)

---

## 🔒 Privacy & safety

OSToolbar is designed to be safe and self-contained:

- **No network access at all.** The app contains **zero HTTP/network requests** —
no telemetry, no analytics, no auto-update calls, nothing leaves your machine.
This is enforced at the OS level: the app is **sandboxed** and ships **without**
the network entitlement, so macOS itself blocks any outbound connection.
- **Everything stays in its own container.** Clipboard history is stored locally in
the app's sandbox container; screenshots are saved only where you choose.
- **Passwords are never stored.** Clipboard history ignores password-manager and
`concealed`/`transient` pasteboard entries, so copied passwords aren't captured.

You can verify this yourself — search the source: there are no `URLSession`,
`URLRequest`, or networking calls anywhere in the app.

---

## ⬇️ Install (pre-built)

1. Download the latest DMG from `[releases/](releases/)` (or the GitHub Releases page).
2. Open the DMG and drag **OSToolbar** onto **Applications**.
3. First launch: **right-click the app → Open** (the build is signed with a
  self-signed certificate, not Apple-notarized, so Gatekeeper asks once).
4. When you first take a screenshot, macOS asks for **Screen Recording**
  permission — grant it (System Settings → Privacy & Security → Screen Recording),
   then **quit and reopen** the app once.hasansahinnn

---

## 🚀 Usage

### Clipboard history

- Click the menu-bar icon to open the history.
- Type to search; press **Return** to paste the selected item.
- Configure the open shortcut in **Settings → General**.

### Screenshot

- Press **⌘⇧X** (configurable in **Settings → Screenshot**), or choose
**Take a Screenshot** from the popup's bottom menu.
- Drag to select a region. A toolbar appears with:
  - **Tools:** pen, line, arrow, rectangle, ellipse, highlighter, text
  - **Color** and **size** controls, **Undo (⌘Z)**
  - **Copy (⌘C)** — copy to the clipboard (also lands in clipboard history)
  - **Save** — write straight to the default folder
  - **Save As…** — choose where to save
  - **Esc** — cancel
- **Settings → Screenshot** lets you set the default save folder, the shortcut, and
the default color/sizes. By default screenshots are saved to
`~/Pictures/OSToolBar ScreenShot`.

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