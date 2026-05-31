import AppKit
import Defaults
import Sauce
import SwiftData

/// A single clipboard entry. Owns one or more HistoryItemContent (one per
/// representation that was on the pasteboard at copy time).
@Model
class HistoryItem {
  /// Letter keys that can act as quick-paste pins; reserves OS-wide shortcuts.
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  /// Pin keys not already in use by another pinned item.
  @MainActor
  static var availablePins: [String] {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil }
    )
    let pins = try? Storage.shared.context.fetch(descriptor).compactMap({ $0.pin })
    let assignedPins = Set(pins ?? [])
    return Array(supportedPins.subtracting(assignedPins))
  }

  /// Random unused pin key, or "" if none available.
  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromOSToolbar.rawValue,
    NSPasteboard.PasteboardType.osToolbarThumbnail.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  // Binary types whose values we never byte-compare in supersedes() —
  // faulting external-storage blobs for every existing item would freeze copy.
  private static let binaryBlobTypes: Set<String> = [
    NSPasteboard.PasteboardType.tiff.rawValue,
    NSPasteboard.PasteboardType.png.rawValue,
    NSPasteboard.PasteboardType.jpeg.rawValue,
    NSPasteboard.PasteboardType.heic.rawValue,
    NSPasteboard.PasteboardType.fileURL.rawValue,
    NSPasteboard.PasteboardType.html.rawValue,
    NSPasteboard.PasteboardType.rtf.rawValue
  ]

  /// True iff `self` is a duplicate of `item` and should replace it in history.
  /// Plain-text clips compare byte-exact; binary-blob clips never dedupe (type-only
  /// match would collide distinct screenshots, byte-compare would freeze copy).
  func supersedes(_ item: HistoryItem) -> Bool {
    let incoming = item.contents.filter { !Self.transientTypes.contains($0.type) }
    let mine = contents.filter { !Self.transientTypes.contains($0.type) }
    if incoming.contains(where: { Self.binaryBlobTypes.contains($0.type) }) ||
       mine.contains(where: { Self.binaryBlobTypes.contains($0.type) }) {
      return false
    }
    guard mine.count == incoming.count,
          Set(mine.map(\.type)) == Set(incoming.map(\.type)) else {
      return false
    }
    return incoming.allSatisfy { content in
      mine.contains(where: { $0.type == content.type && $0.value == content.value })
    }
  }

  /// Builds the row title shown in the list. Empty for image-only clips,
  /// up to 200 chars of preview text otherwise.
  func generateTitle() -> String {
    // Image clips have no title — thumbnail speaks for itself; no OCR.
    if image != nil { return "" }

    // List-row snippet only — full text lives in the preview pane.
    var title = previewableText.shortened(to: 200)

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  /// Best human-readable text for previewing/searching. Prefers fileURLs →
  /// plain text → RTF → HTML → title fallback.
  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  /// File URLs on the pasteboard (e.g. Finder file copy). Empty for Universal Clipboard text.
  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  /// Raw HTML bytes from the pasteboard.
  var htmlData: Data? { contentData([.html]) }
  /// Parsed HTML as NSAttributedString (slow — only call when needed).
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  /// Pre-generated small JPEG thumbnail (~10–30 KB) — list reads only this.
  var thumbnailImageData: Data? { contentData([.osToolbarThumbnail]) }

  /// True if the item has direct image bytes; type-only check (no blob fault).
  var hasOriginalImageBytes: Bool {
    let imageTypes: Set<String> = [
      NSPasteboard.PasteboardType.tiff.rawValue,
      NSPasteboard.PasteboardType.png.rawValue,
      NSPasteboard.PasteboardType.jpeg.rawValue,
      NSPasteboard.PasteboardType.heic.rawValue
    ]
    return contents.contains { imageTypes.contains($0.type) }
  }

  /// Full-resolution image bytes. For preview / click only — list uses thumbnailImageData.
  var imageData: Data? {
    var data: Data?
    data = contentData([.tiff, .png, .jpeg, .heic])
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  /// Decoded NSImage of the full original (loads bytes; slow for big clips).
  var image: NSImage? {
    guard let data = imageData else {
      return nil
    }

    return NSImage(data: data)
  }

  /// Raw RTF bytes.
  var rtfData: Data? { contentData([.rtf]) }
  /// Parsed RTF as NSAttributedString.
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  /// Plain UTF-8 string content, if present.
  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  /// Modification counter set by the app on our own copies (paste-stack tracking).
  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  /// True when this clip was written to the pasteboard by OSToolbar itself.
  var fromOSToolbar: Bool { contentData([.fromOSToolbar]) != nil }
  /// True when this clip arrived via macOS Universal Clipboard (Handoff).
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

}
