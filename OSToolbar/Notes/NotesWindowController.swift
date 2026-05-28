import AppKit
import SwiftUI

// Hosts the Notes UI in a normal resizable window (separate from the clipboard
// popup and screenshot overlay).
@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
  convenience init() {
    let hosting = NSHostingController(rootView: NotesRootView())
    let window = NSWindow(contentViewController: hosting)
    window.title = "OSToolbar Notes"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = false
    window.setContentSize(NSSize(width: 1000, height: 620))
    window.center()
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("com.ostoolbar.app.notes")
    self.init(window: window)
    window.delegate = self
  }

  func show() {
    // The app normally runs as a menu-bar accessory (no Dock icon, not in
    // Cmd-Tab). While the Notes window is open we switch to a regular app so the
    // window stays reachable (Dock + Cmd-Tab) and doesn't vanish on focus loss.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    NotesController.shared.flushPendingSave()
    // Back to accessory so the clipboard/screenshot stay menu-bar only.
    NSApp.setActivationPolicy(.accessory)
  }
}
