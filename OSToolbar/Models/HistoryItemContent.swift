import Foundation
import SwiftData

/// One piece of pasteboard content (e.g. plain text, an image's TIFF bytes,
/// an HTML representation). A HistoryItem owns one or more of these.
@Model
class HistoryItemContent {
  /// Raw NSPasteboard.PasteboardType.rawValue (e.g. "public.utf8-plain-text").
  var type: String = ""
  /// Payload bytes. External storage = blobs live in separate files. Inline
  /// bytes get permanently retained by the context once faulted; external can release.
  @Attribute(.externalStorage) var value: Data?

  /// Back-reference to the owning HistoryItem.
  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil) {
    self.type = type
    self.value = value
  }
}
