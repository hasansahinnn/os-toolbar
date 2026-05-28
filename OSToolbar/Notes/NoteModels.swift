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

  init(
    id: UUID = UUID(),
    title: String = "New Note",
    color: NoteColor = .none,
    created: Date = Date(),
    modified: Date = Date(),
    alarms: [NoteAlarm] = []
  ) {
    self.id = id
    self.title = title
    self.color = color
    self.created = created
    self.modified = modified
    self.alarms = alarms
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
  }

  var meta: NoteMeta {
    NoteMeta(
      id: id,
      title: title,
      color: color,
      created: created,
      modified: modified,
      alarms: alarms
    )
  }

  // First non-empty line after the title, for the list preview.
  var snippet: String {
    let text = attributed?.string ?? ""
    let lines = text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.dropFirst(0).first ?? "No additional text"
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
