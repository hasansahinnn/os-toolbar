import AppKit.NSWorkspace
import Defaults
import Foundation
import ImageIO
import Observation
import Sauce

// Lets us hand a CGImage back from a detached (background) task to the main actor.
// CGImage is effectively immutable/thread-safe; the box just satisfies Sendable.
private struct SendableCGImage: @unchecked Sendable { let image: CGImage }

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  // The preview panel is small, so generating a full-screen-resolution image was
  // wasteful and slow (caused hangs when moving between image items). Cap it.
  static var previewImageSize: NSSize { NSSize(width: 1100, height: 900) }
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

  // Cheap check — don't decode the image just to know it's an image.
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

  @MainActor
  func ensureThumbnailImage() {
    guard thumbnailImage == nil, thumbnailImageGenerationTask == nil,
          let data = item.imageData else {
      return
    }
    let target = Self.thumbnailImageSize
    let maxPixel = max(target.width, target.height) * 2
    thumbnailImageGenerationTask = Task.detached(priority: .utility) { [weak self] in
      guard let cgImage = Self.downsample(data, maxPixelSize: maxPixel) else { return }
      let boxed = SendableCGImage(image: cgImage)
      await MainActor.run {
        self?.thumbnailImage = NSImage(cgImage: boxed.image, size: Self.fittedSize(boxed.image, within: target))
      }
    }
  }

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

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.value
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
  }

  // Decode the image data directly at the target size via ImageIO — this never
  // fully decodes huge originals, so it's fast and light, and safe off the main
  // thread. Runs on a background task; the result is handed back via SendableCGImage.
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

  // Point size for an image that aspect-fits within `box` (never upscaled), so a
  // wide image stays short in the list rather than ballooning in height.
  nonisolated private static func fittedSize(_ image: CGImage, within box: NSSize) -> NSSize {
    let pixelWidth = CGFloat(image.width)
    let pixelHeight = CGFloat(image.height)
    let scale = min(box.width / pixelWidth, box.height / pixelHeight, 1)
    return NSSize(width: pixelWidth * scale, height: pixelHeight * scale)
  }

  @MainActor
  func sizeImages() {
    ensureThumbnailImage()
    ensurePreviewImage()
  }

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
