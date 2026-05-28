import AppKit
import Defaults
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotError: Error {
  case displayNotFound
}

// Resolves where screenshots are saved and how to write them, honoring the sandbox.
enum ScreenshotPreferences {
  static var defaultDirectory: URL {
    let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    return base.appendingPathComponent("OSToolBar ScreenShot", isDirectory: true)
  }

  // Resolved save directory. Returns the user-chosen folder (via security-scoped
  // bookmark) when set, otherwise the default ~/Pictures/OSToolBar ScreenShot.
  static var saveDirectory: URL {
    if let data = Defaults[.screenshotDirectoryBookmark],
       let url = resolveBookmark(data) {
      return url
    }
    return defaultDirectory
  }

  static var saveDirectoryDisplayPath: String {
    saveDirectory.path(percentEncoded: false)
  }

  static func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = saveDirectory
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let bookmark = try? url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) {
      Defaults[.screenshotDirectoryBookmark] = bookmark
    }
  }

  static func openInFinder() {
    let dir = saveDirectory
    ensureExists(dir)
    NSWorkspace.shared.activateFileViewerSelecting([dir])
  }

  // Writes PNG data to the default directory. Returns the saved file URL.
  @discardableResult
  static func saveToDefaultDirectory(_ pngData: Data) -> URL? {
    let dir = saveDirectory
    let scoped = startScopedAccess(for: dir)
    defer { if scoped { dir.stopAccessingSecurityScopedResource() } }

    ensureExists(dir)
    let url = dir.appendingPathComponent(fileName())
    do {
      try pngData.write(to: url)
      return url
    } catch {
      NSLog("OSToolbar: failed to save screenshot: \(error)")
      return nil
    }
  }

  // Opens a Save panel for "Save As…". Returns the saved file URL.
  @discardableResult
  static func saveAs(_ pngData: Data) -> URL? {
    // We're an accessory (menu-bar) app; make sure we're active so the
    // panel comes to the front and can receive input.
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSSavePanel()
    panel.level = .modalPanel
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = fileName()
    panel.directoryURL = saveDirectory
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
      try pngData.write(to: url)
      return url
    } catch {
      NSLog("OSToolbar: failed to save screenshot: \(error)")
      return nil
    }
  }

  static func fileName() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "OSToolbar Screenshot \(formatter.string(from: Date())).png"
  }

  private static func ensureExists(_ dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  private static func resolveBookmark(_ data: Data) -> URL? {
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      options: .withSecurityScope,
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ) else { return nil }
    return url
  }

  private static func startScopedAccess(for dir: URL) -> Bool {
    guard let data = Defaults[.screenshotDirectoryBookmark],
          let url = resolveBookmark(data),
          url == dir else { return false }
    return url.startAccessingSecurityScopedResource()
  }
}

@MainActor
final class ScreenshotController {
  static let shared = ScreenshotController()

  private var overlayWindow: ScreenshotOverlayWindow?
  private var isCapturing = false

  func capture() {
    guard !isCapturing, overlayWindow == nil else { return }

    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
      presentPermissionAlert()
      return
    }

    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
      ?? NSScreen.main,
      let displayID = screen.displayID else { return }

    isCapturing = true
    let scale = screen.backingScaleFactor

    Task { @MainActor in
      do {
        let image = try await Self.captureDisplay(displayID: displayID, scale: scale)
        self.presentOverlay(cgImage: image, screen: screen, scale: scale)
      } catch {
        self.isCapturing = false
        NSLog("OSToolbar: screenshot capture failed: \(error)")
      }
    }
  }

  private func presentOverlay(cgImage: CGImage, screen: NSScreen, scale: CGFloat) {
    let window = ScreenshotOverlayWindow(
      cgImage: cgImage,
      screen: screen,
      scale: scale
    ) { [weak self] in
      self?.overlayWindow = nil
      self?.isCapturing = false
    }
    overlayWindow = window
    window.present()
  }

  private func presentPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = "Screen Recording permission needed"
    alert.informativeText = """
    OSToolbar needs Screen Recording permission to take screenshots.
    Grant access in System Settings → Privacy & Security → Screen Recording, \
    then trigger the screenshot again.
    """
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }

  private static func captureDisplay(displayID: CGDirectDisplayID, scale: CGFloat) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw ScreenshotError.displayNotFound
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(CGFloat(display.width) * scale)
    config.height = Int(CGFloat(display.height) * scale)
    config.showsCursor = false
    config.captureResolution = .best

    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
