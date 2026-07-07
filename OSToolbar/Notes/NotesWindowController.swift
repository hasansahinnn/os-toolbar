import AppKit
import SwiftUI

/// Hosts the Notes UI in a regular resizable window. Switches the app
/// activation policy from `.accessory` to `.regular` while open (so the
/// window appears in Cmd-Tab) and back to `.accessory` on close.
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

  /// Brings the Notes window forward. Window is shown FIRST so the user sees
  /// it immediately; the activation-policy switch (slow syscall, especially on
  /// cold-idle wake-up) is deferred so it doesn't block the open by 10+ seconds.
  func show() {
    // Close the clipboard popup — otherwise NSApp.activate would raise it
    // alongside Notes.
    AppState.shared.popup.close()
    window?.orderFrontRegardless()
    window?.makeKey()
    // Defer the slow WindowServer round-trip until after the window paints.
    DispatchQueue.main.async {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func windowWillClose(_ notification: Notification) {
    NotesController.shared.flushPendingSave()
    NotesController.shared.releaseAllLoadedContent()
    NSApp.setActivationPolicy(.accessory)  // back to menu-bar-only
  }
}
