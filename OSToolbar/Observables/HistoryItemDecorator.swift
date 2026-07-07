import AppKit.NSWorkspace
import Defaults
import Foundation
import ImageIO
import Observation
import Sauce
import UniformTypeIdentifiers

// Sendable wrapper for handing a CGImage across actor boundaries.
private struct SendableCGImage: @unchecked Sendable { let image: CGImage }

/// View-model wrapper around a persisted HistoryItem. Holds decoded NSImages
/// (thumbnail + preview), search-highlight state, keyboard shortcut bindings,
/// and the cached application icon for the source app.
@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  /// Preview-pane cap — was 1100×900 (~4 MB decoded), now 600×400 (~1 MB).
  static var previewImageSize: NSSize { NSSize(width: 600, height: 400) }
  /// List-row thumbnail cap — width fixed, height follows the user-configurable max.
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  // Not cached: caching image bytes per decorator pinned GB of RAM.
  var hasImage: Bool { item.imageData != nil }

  var previewImageGenerationTask: Task<Void, Never>?
  var thumbnailImageGenerationTask: Task<Void, Never>?
  var previewImage: NSImage?
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { item.previewableText.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  /// Kicks off thumbnail load for the list row (no-op if already loaded).
  /// Fast path uses pre-generated JPEG; backfill path reads + encodes original.
  @MainActor
  func ensureThumbnailImage() {
    guard thumbnailImage == nil, thumbnailImageGenerationTask == nil else { return }
    let target = Self.thumbnailImageSize
    let maxPixel = max(target.width, target.height) * 2

    // Fast path: pre-generated JPEG already attached.
    if let data = item.thumbnailImageData {
      thumbnailImageGenerationTask = Task.detached(priority: .utility) { [weak self] in
        guard let cgImage = Self.downsample(data, maxPixelSize: maxPixel) else { return }
        let boxed = SendableCGImage(image: cgImage)
        await MainActor.run {
          self?.thumbnailImage = NSImage(cgImage: boxed.image, size: Self.fittedSize(boxed.image, within: target))
        }
      }
      return
    }

    // Backfill: legacy items (or pre-attach race) — generate from original.
    // Brief MainActor hop for the blob fault, encode + decode off-main.
    guard item.hasOriginalImageBytes else { return }
    let weakItem = item
    thumbnailImageGenerationTask = Task.detached(priority: .utility) { [weak self] in
      let originalBytes: Data? = await MainActor.run { weakItem.imageData }
      guard let bytes = originalBytes else { return }
      guard let jpeg = Self.downsampleToJPEG(bytes, maxPixel: 680, quality: 0.6) else { return }
      guard let cgImage = Self.downsample(jpeg, maxPixelSize: maxPixel) else { return }
      let boxed = SendableCGImage(image: cgImage)
      await MainActor.run {
        guard let self else { return }
        self.thumbnailImage = NSImage(cgImage: boxed.image, size: Self.fittedSize(boxed.image, within: target))
        // Persist for fast path next time.
        let thumb = HistoryItemContent(
          type: NSPasteboard.PasteboardType.osToolbarThumbnail.rawValue,
          value: jpeg
        )
        thumb.item = weakItem
        weakItem.contents.append(thumb)
      }
    }
  }

  /// Kicks off full-resolution preview decode for the preview pane.
  @MainActor
  func ensurePreviewImage() {
    guard previewImage == nil, previewImageGenerationTask == nil,
          let data = item.imageData else {
      return
    }
    let target = Self.previewImageSize
    let maxPixel = max(target.width, target.height)
    previewImageGenerationTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let cgImage = Self.downsample(data, maxPixelSize: maxPixel) else { return }
      let boxed = SendableCGImage(image: cgImage)
      await MainActor.run {
        self?.previewImage = NSImage(cgImage: boxed.image, size: Self.fittedSize(boxed.image, within: target))
      }
    }
  }

  /// Awaits the preview image — kicks generation if not yet started.
  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.value
    return previewImage
  }

  // Called on .onDisappear — bounds thumbnail RAM to visible rows.
  @MainActor
  func releaseThumbnail() {
    thumbnailImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    thumbnailImage?.recache()
    thumbnailImage = nil
  }

  /// Cancels in-flight image tasks and releases both thumbnail + preview NSImages.
  /// Task refs are nil'd too — otherwise `ensureThumbnailImage`'s guard sees a
  /// non-nil (cancelled) task on the next open and refuses to regenerate,
  /// which was making thumbnails disappear after Esc-then-reopen.
  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    previewImageGenerationTask?.cancel()
    previewImageGenerationTask = nil
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
  }

  // Original bytes → small JPEG thumbnail. Used by the backfill path.
  nonisolated fileprivate static func downsampleToJPEG(_ data: Data, maxPixel: CGFloat, quality: CGFloat) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? (out as Data) : nil
  }

  // ImageIO thumbnail decode at target size — never fully decodes huge originals.
  nonisolated private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  // Aspect-fit within `box`, never upscaled.
  nonisolated private static func fittedSize(_ image: CGImage, within box: NSSize) -> NSSize {
    let pixelWidth = CGFloat(image.width)
    let pixelHeight = CGFloat(image.height)
    let scale = min(box.width / pixelWidth, box.height / pixelHeight, 1)
    return NSSize(width: pixelWidth * scale, height: pixelHeight * scale)
  }

  /// Loads both thumbnail and preview (called when user focuses the item).
  @MainActor
  func sizeImages() {
    ensureThumbnailImage()
    ensurePreviewImage()
  }

  /// Applies search-match highlighting (bold/italic/underline/bg) to the title.
  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  /// Toggles the pinned state — assigns a random unused pin character if pinning.
  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: {
      DispatchQueue.main.async {
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: {
      DispatchQueue.main.async {
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }
}
