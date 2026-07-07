import AppKit
import Defaults
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotError: Error {
  case displayNotFound
}

// Sendable wrapper for handing a CGImage across actor boundaries.
private struct SendableCGImageBox: @unchecked Sendable { let image: CGImage }

/// Sandbox-aware resolver + writer for the screenshot output folder.
/// Handles the security-scoped bookmark when the user picks a custom folder.
enum ScreenshotPreferences {
  static var defaultDirectory: URL {
    let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    return base.appendingPathComponent("OSToolBar ScreenShot", isDirectory: true)
  }

  // User-chosen folder (security-scoped bookmark) or the default.
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

  /// Opens an NSOpenPanel for the user to pick a new output folder; persists
  /// the result as a security-scoped bookmark.
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

  /// Opens the screenshot folder in Finder.
  static func openInFinder() {
    let dir = saveDirectory
    ensureExists(dir)
    NSWorkspace.shared.open(dir)
  }

  /// Opens Finder with `url` selected in its parent folder.
  static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Writes PNG bytes to the configured screenshot folder. Returns the saved URL.
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

  /// Shows an NSSavePanel ("Save As…") and writes PNG bytes to the chosen URL.
  @discardableResult
  static func saveAs(_ pngData: Data) -> URL? {
    // Menu-bar app must be active so the Save panel comes to the front.
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
    return "Screenshot \(formatter.string(from: Date())).png"
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

/// Drives the screenshot feature. Two entry points: `capture()` for the
/// interactive region-select + annotate flow, `captureFullScreen()` for the
/// one-shot quick screenshot. Uses ScreenCaptureKit for the actual pixel grab.
@MainActor
final class ScreenshotController {
  static let shared = ScreenshotController()

  private var overlayWindow: ScreenshotOverlayWindow?
  private var thumbnailWindow: ScreenshotThumbnailWindow?
  private var isCapturing = false
  /// App that was frontmost before capture — focus is handed back on close.
  private var prevFrontmostApp: NSRunningApplication?

  /// Interactive capture: grabs the cursor's display, then opens the
  /// region-select + annotation overlay. No-op if a capture is already running.
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

    // Remember who was frontmost so we can hand focus back on close.
    prevFrontmostApp = NSWorkspace.shared.frontmostApplication.flatMap {
      $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0
    }

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

  /// Quick capture: grabs the full display under the cursor, saves to the
  /// configured folder, shows a corner thumbnail. No editor, no region select.
  func captureFullScreen() {
    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
      presentPermissionAlert()
      return
    }

    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
      ?? NSScreen.main,
      let displayID = screen.displayID else { return }
    let scale = screen.backingScaleFactor

    Task { @MainActor in
      do {
        let image = try await Self.captureDisplay(displayID: displayID, scale: scale)
        let boxed = SendableCGImageBox(image: image)
        Task.detached(priority: .userInitiated) {
          guard let png = Self.pngData(from: boxed.image) else { return }
          let savedURL = ScreenshotPreferences.saveToDefaultDirectory(png)
          let nsImage = NSImage(
            cgImage: boxed.image,
            size: NSSize(width: boxed.image.width, height: boxed.image.height)
          )
          await MainActor.run {
            self.showThumbnail(nsImage, fileURL: savedURL, screen: screen)
            if Defaults[.screenshotOpenFolderAfterCapture] {
              ScreenshotPreferences.openInFinder()
            }
          }
        }
      } catch {
        NSLog("OSToolbar: quick screenshot failed: \(error)")
      }
    }
  }

  private func showThumbnail(_ image: NSImage, fileURL: URL?, screen: NSScreen) {
    thumbnailWindow?.dismiss()
    let window = ScreenshotThumbnailWindow(image: image, screen: screen) {
      if let fileURL { ScreenshotPreferences.revealInFinder(fileURL) }
    } onFinish: { [weak self] in
      self?.thumbnailWindow = nil
    }
    thumbnailWindow = window
    window.present()
  }

  // nonisolated for the background PNG-encoding task.
  nonisolated private static func pngData(from cgImage: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
  }

  private func presentOverlay(cgImage: CGImage, screen: NSScreen, scale: CGFloat) {
    let window = ScreenshotOverlayWindow(
      cgImage: cgImage,
      screen: screen,
      scale: scale
    ) { [weak self] in
      self?.overlayWindow = nil
      self?.isCapturing = false
      self?.handBackFocus()
    }
    overlayWindow = window
    window.present()
  }

  /// Hands focus back to the app that was frontmost before the screenshot.
  private func handBackFocus() {
    if let prev = prevFrontmostApp {
      prev.activate(options: [])
      prevFrontmostApp = nil
    }
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

// MARK: - Bottom-right capture thumbnail

@MainActor
final class ScreenshotThumbnailWindow: NSWindow {
  private let onClick: () -> Void
  private let onFinish: () -> Void
  private var dismissTask: Task<Void, Never>?

  init(image: NSImage, screen: NSScreen, onClick: @escaping () -> Void, onFinish: @escaping () -> Void) {
    self.onClick = onClick
    self.onFinish = onFinish

    let maxW: CGFloat = 220, maxH: CGFloat = 150
    let aspect = image.size.width / max(image.size.height, 1)
    var w = maxW, h = maxW / aspect
    if h > maxH { h = maxH; w = maxH * aspect }
    let margin: CGFloat = 20
    let frame = NSRect(
      x: screen.visibleFrame.maxX - w - margin,
      y: screen.visibleFrame.minY + margin,
      width: w, height: h
    )

    super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .statusBar
    hasShadow = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    let view = ClickableImageView(image: image) { [weak self] in
      self?.dismiss()
      self?.onClick()
    }
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    view.layer?.cornerRadius = 8
    view.layer?.borderWidth = 2
    view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
    view.layer?.masksToBounds = true
    contentView = view
  }

  func present() {
    orderFrontRegardless()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self.dismiss()
    }
  }

  func dismiss() {
    dismissTask?.cancel()
    dismissTask = nil
    orderOut(nil)
    let finish = onFinish
    DispatchQueue.main.async { finish() }
  }

  override var canBecomeKey: Bool { false }
}

@MainActor
private final class ClickableImageView: NSImageView {
  private let onClick: () -> Void
  init(image: NSImage, onClick: @escaping () -> Void) {
    self.onClick = onClick
    super.init(frame: .zero)
    self.image = image
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func mouseDown(with event: NSEvent) { onClick() }
}
