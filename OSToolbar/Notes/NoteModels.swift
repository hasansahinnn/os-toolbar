import AppKit
import Foundation
import SwiftUI

// Color flag a note can be tagged with. Stored by `rawValue` in meta.json.
enum NoteColor: String, CaseIterable, Codable, Identifiable {
  case none
  case red
  case orange
  case yellow
  case green
  case blue
  case purple

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: return "No Color"
    case .red: return "Red"
    case .orange: return "Orange"
    case .yellow: return "Yellow"
    case .green: return "Green"
    case .blue: return "Blue"
    case .purple: return "Purple"
    }
  }

  var color: Color {
    switch self {
    case .none: return .secondary
    case .red: return .red
    case .orange: return .orange
    case .yellow: return .yellow
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    }
  }

  // Sort order used when grouping the notes list by color.
  var sortIndex: Int {
    NoteColor.allCases.firstIndex(of: self) ?? 0
  }
}

// A single alarm attached to a note. Persisted in meta.json and scheduled with
// UNUserNotificationCenter. `identifier` doubles as the notification request id.
struct NoteAlarm: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var date: Date
  var title: String = ""
  // Set true once the notification has fired, so we don't reschedule past alarms.
  var fired: Bool = false

  var identifier: String { id.uuidString }
  var isPending: Bool { !fired && date > Date() }
}

// Codable sidecar describing a note. The rich text itself lives next to it in
// `content.rtfd`; this file holds everything else.
struct NoteMeta: Codable {
  var id: UUID
  var title: String
  var color: NoteColor
  var created: Date
  var modified: Date
  var alarms: [NoteAlarm]
  // Cached one-line body preview for the list (so it's consistent and doesn't
  // require loading the full note content). Defaults empty for older files.
  var preview: String

  init(
    id: UUID = UUID(),
    title: String = "New Note",
    color: NoteColor = .none,
    created: Date = Date(),
    modified: Date = Date(),
    alarms: [NoteAlarm] = [],
    preview: String = ""
  ) {
    self.id = id
    self.title = title
    self.color = color
    self.created = created
    self.modified = modified
    self.alarms = alarms
    self.preview = preview
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, color, created, modified, alarms, preview
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    color = try c.decode(NoteColor.self, forKey: .color)
    created = try c.decode(Date.self, forKey: .created)
    modified = try c.decode(Date.self, forKey: .modified)
    alarms = try c.decodeIfPresent([NoteAlarm].self, forKey: .alarms) ?? []
    preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
  }
}

// A note backed by a directory on disk: <folder>/<name>/ containing
// `content.rtfd` (rich text + images) and `meta.json` (this metadata).
@Observable
final class Note: Identifiable {
  let id: UUID
  // The note's own directory on disk.
  var directoryURL: URL
  var title: String
  var color: NoteColor
  var created: Date
  var modified: Date
  var alarms: [NoteAlarm]
  // One-line body preview shown in the list (kept in sync with content on save).
  var preview: String

  // Loaded lazily from content.rtfd when the note is opened in the editor.
  var attributed: NSAttributedString?

  var contentURL: URL { directoryURL.appendingPathComponent("content.rtfd") }
  var metaURL: URL { directoryURL.appendingPathComponent("meta.json") }

  var hasPendingAlarm: Bool { alarms.contains(where: \.isPending) }

  init(directoryURL: URL, meta: NoteMeta) {
    self.id = meta.id
    self.directoryURL = directoryURL
    self.title = meta.title
    self.color = meta.color
    self.created = meta.created
    self.modified = meta.modified
    self.alarms = meta.alarms
    self.preview = meta.preview
  }

  var meta: NoteMeta {
    NoteMeta(
      id: id,
      title: title,
      color: color,
      created: created,
      modified: modified,
      alarms: alarms,
      preview: preview
    )
  }

  // Stable list preview (cached in meta, not recomputed from lazily-loaded content).
  var snippet: String {
    preview.isEmpty ? "No additional text" : preview
  }
}

// A folder shown in the sidebar, backed by a real directory on disk.
@Observable
final class NoteFolder: Identifiable {
  let id: URL
  var name: String
  var url: URL

  init(url: URL) {
    self.id = url
    self.url = url
    self.name = url.lastPathComponent
  }
}
