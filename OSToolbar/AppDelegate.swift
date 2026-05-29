import Defaults
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Separate menu-bar icon for the Screenshot feature. Clicking it opens a small
  // menu (Screenshot / Quick Screenshot / Preferences) rather than a popup.
  private lazy var screenshotStatusItem: NSStatusItem = {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot")
    image?.isTemplate = true
    item.button?.image = image
    item.menu = makeScreenshotMenu()
    return item
  }()

  private func makeScreenshotMenu() -> NSMenu {
    let menu = NSMenu()

    let region = NSMenuItem(title: "Screenshot", action: #selector(menuCaptureRegion), keyEquivalent: "")
    region.target = self
    menu.addItem(region)

    let quick = NSMenuItem(title: "Quick Screenshot", action: #selector(menuCaptureFullScreen), keyEquivalent: "")
    quick.target = self
    menu.addItem(quick)

    let openFolder = NSMenuItem(title: "Open Image Folder", action: #selector(menuOpenScreenshotFolder), keyEquivalent: "")
    openFolder.target = self
    menu.addItem(openFolder)

    menu.addItem(.separator())

    let prefs = NSMenuItem(title: "Preferences…", action: #selector(menuOpenScreenshotPreferences), keyEquivalent: "")
    prefs.target = self
    menu.addItem(prefs)

    let about = NSMenuItem(title: "About", action: #selector(menuOpenAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(about)

    let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)

    return menu
  }

  @objc @MainActor private func menuCaptureRegion() {
    guard Defaults[.screenshotEnabled] else { return showFeatureDisabled("Screenshot") }
    ScreenshotController.shared.capture()
  }

  @objc @MainActor private func menuCaptureFullScreen() {
    guard Defaults[.screenshotEnabled] else { return showFeatureDisabled("Screenshot") }
    ScreenshotController.shared.captureFullScreen()
  }

  @objc @MainActor private func menuOpenScreenshotFolder() {
    guard Defaults[.screenshotEnabled] else { return showFeatureDisabled("Screenshot") }
    ScreenshotPreferences.openInFinder()
  }

  // Lets the user know why nothing happened when they trigger a disabled feature
  // from its menu (the shortcut path just stays silent).
  @MainActor private func showFeatureDisabled(_ name: String) {
    let alert = NSAlert()
    alert.messageText = "\(name) is turned off"
    alert.informativeText = "Enable it in \(name) → Preferences."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @objc @MainActor private func menuOpenScreenshotPreferences() {
    AppState.shared.openScreenshotPreferences()
  }

  @objc @MainActor private func menuOpenAbout() {
    AppState.shared.openAbout()
  }

  @objc @MainActor private func menuQuit() {
    AppState.shared.quit()
  }

  // Separate menu-bar icon for the Notes feature.
  private lazy var notesStatusItem: NSStatusItem = {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes")
    image?.isTemplate = true
    item.button?.image = image
    item.menu = makeNotesMenu()
    return item
  }()

  private func makeNotesMenu() -> NSMenu {
    let menu = NSMenu()

    let open = NSMenuItem(title: "Open Notes", action: #selector(menuOpenNotes), keyEquivalent: "")
    open.target = self
    menu.addItem(open)

    let newNote = NSMenuItem(title: "New Note", action: #selector(menuNewNote), keyEquivalent: "")
    newNote.target = self
    menu.addItem(newNote)

    menu.addItem(.separator())

    let prefs = NSMenuItem(title: "Preferences…", action: #selector(menuOpenNotesPreferences), keyEquivalent: "")
    prefs.target = self
    menu.addItem(prefs)

    let about = NSMenuItem(title: "About", action: #selector(menuOpenAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(about)

    let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)

    return menu
  }

  @objc @MainActor private func menuOpenNotes() {
    guard Defaults[.notesEnabled] else { return showFeatureDisabled("Notes") }
    NotesController.shared.openWindow()
  }

  @objc @MainActor private func menuNewNote() {
    guard Defaults[.notesEnabled] else { return showFeatureDisabled("Notes") }
    NotesController.shared.openWindow()
    NotesController.shared.newNote()
  }

  @objc @MainActor private func menuOpenNotesPreferences() {
    AppState.shared.openNotesPreferences()
  }

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { item in
      guard Defaults[.clipboardEnabled] else { return }
      History.shared.add(item)
    }
    Clipboard.shared.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    // Create the separate Screenshot and Notes menu-bar icons (lazy — reference
    // to build them).
    _ = screenshotStatusItem
    _ = notesStatusItem

    // Notes: make sure the on-disk folder exists and (re)schedule any alarms.
    NotesStore.ensureRoot()
    if Defaults[.migrations]["2026-notes-curated-seed"] != true {
      // Replace the earlier generic demo folders with a tidy, curated set.
      NotesStore.removeFolders(named: ["Work", "Personal", "Ideas", "Recipes"])
      NotesStore.seedMockData()
      Defaults[.migrations]["2026-notes-curated-seed"] = true
    }
    NoteAlarmManager.shared.start()

    KeyboardShortcuts.onKeyUp(for: .screenshot) {
      guard Defaults[.screenshotEnabled] else { return }
      ScreenshotController.shared.capture()
    }

    KeyboardShortcuts.onKeyUp(for: .quickScreenshot) {
      guard Defaults[.screenshotEnabled] else { return }
      ScreenshotController.shared.captureFullScreen()
    }

    KeyboardShortcuts.onKeyUp(for: .openScreenshotFolder) {
      guard Defaults[.screenshotEnabled] else { return }
      ScreenshotPreferences.openInFinder()
    }

    KeyboardShortcuts.onKeyUp(for: .openNotes) {
      guard Defaults[.notesEnabled] else { return }
      NotesController.shared.openWindow()
    }

    // Register/unregister each feature's global shortcuts with the enabled flag.
    // A disabled feature must fully release its hotkey so the combo (e.g. ⌘⇧N)
    // passes through to other apps instead of being swallowed.
    Task {
      for await enabled in Defaults.updates(.clipboardEnabled) {
        if enabled { KeyboardShortcuts.enable(.popup) } else { KeyboardShortcuts.disable(.popup) }
      }
    }
    Task {
      let names: [KeyboardShortcuts.Name] = [.screenshot, .quickScreenshot, .openScreenshotFolder]
      for await enabled in Defaults.updates(.screenshotEnabled) {
        if enabled { KeyboardShortcuts.enable(names) } else { KeyboardShortcuts.disable(names) }
      }
    }
    Task {
      for await enabled in Defaults.updates(.notesEnabled) {
        if enabled { KeyboardShortcuts.enable(.openNotes) } else { KeyboardShortcuts.disable(.openNotes) }
      }
    }

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "com.ostoolbar.app",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func migrateUserDefaults() {
    if Defaults[.migrations]["2024-07-01-version-2"] != true {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")

      Defaults[.migrations]["2024-07-01-version-2"] = true
    }

    // Undo the earlier compact-window experiment: restore the taller, adaptive
    // window height (matches the original/Maccy behavior) for anyone who got 480.
    if Defaults[.migrations]["2026-restore-window-height"] != true {
      if Defaults[.windowSize].height < 800 {
        Defaults[.windowSize].height = 800
      }
      Defaults[.migrations]["2026-restore-window-height"] = true
    }

    // New screenshot shortcut scheme (A/S/F). The previous defaults (X/F/G) were
    // already persisted from earlier runs, so just changing the code default does
    // not take effect — force the new shortcuts once.
    if Defaults[.migrations]["2026-screenshot-shortcuts-asf"] != true {
      KeyboardShortcuts.setShortcut(.init(.s, modifiers: [.command, .shift]), for: .screenshot)
      KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .shift]), for: .quickScreenshot)
      KeyboardShortcuts.setShortcut(.init(.f, modifiers: [.command, .shift]), for: .openScreenshotFolder)
      Defaults[.migrations]["2026-screenshot-shortcuts-asf"] = true
    }

    // The following defaults are not used in this app
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    // When the clipboard feature is off, the icon still opens a small menu so the
    // user can turn it back on or reach Preferences.
    guard Defaults[.clipboardEnabled] else {
      showClipboardDisabledMenu()
      return
    }
    if let event = NSApp.currentEvent {
      let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      if modifierFlags.contains(.option) {
        Defaults[.ignoreEvents].toggle()

        if modifierFlags.contains(.shift) {
          Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
        }

        return
      }
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func showClipboardDisabledMenu() {
    let menu = NSMenu()
    let enable = NSMenuItem(title: "Enable Clipboard History", action: #selector(enableClipboard), keyEquivalent: "")
    enable.target = self
    menu.addItem(enable)
    menu.addItem(.separator())
    let prefs = NSMenuItem(title: "Preferences…", action: #selector(openMainPreferences), keyEquivalent: "")
    prefs.target = self
    menu.addItem(prefs)
    let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    if let button = statusItem.button {
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
  }

  @objc private func enableClipboard() {
    Defaults[.clipboardEnabled] = true
  }

  @objc @MainActor private func openMainPreferences() {
    AppState.shared.openPreferences()
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, names.contains(name) {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}
