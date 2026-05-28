import AppKit
import Foundation
import Observation
import SwiftUI

// App-level state for the Notes feature: the folder/note selection, the list
// shown in the middle column, search/grouping, and autosave. Backed entirely by
// NotesStore (files on disk).
@MainActor
@Observable
final class NotesController {
  static let shared = NotesController()

  var folders: [NoteFolder] = []
  var notes: [Note] = []
  // All pending alarms across every folder, shown in the sidebar "Alarms" section.
  var activeAlarms: [ActiveAlarmRow] = []

  var selectedFolderID: NoteFolder.ID?
  var selectedNoteID: Note.ID?

  var searchQuery: String = ""
  // Group the notes list by color flag, with collapsible sections. On by default.
  var groupByColor: Bool = true
  // Color group ids that are currently collapsed in the list.
  var collapsedColors: Set<String> = []

  // The attributed content currently shown in the editor (bound to the note).
  var editorText = NSAttributedString(string: "")

  private var saveTask: Task<Void, Never>?
  private var loadingNoteIntoEditor = false

  private var windowController: NotesWindowController?

  var selectedFolder: NoteFolder? {
    folders.first { $0.id == selectedFolderID }
  }
  var selectedNote: Note? {
    notes.first { $0.id == selectedNoteID }
  }

  // MARK: - Window

  func openWindow() {
    if windowController == nil {
      windowController = NotesWindowController()
    }
    loadFolders()
    windowController?.show()
  }

  func revealNote(atPath path: String) {
    openWindow()
    let noteURL = URL(fileURLWithPath: path)
    let folderURL = noteURL.deletingLastPathComponent()
    if let folder = folders.first(where: { $0.url == folderURL }) {
      selectFolder(folder)
      if let note = notes.first(where: { $0.directoryURL == noteURL }) {
        selectNote(note)
      }
    }
  }

  // MARK: - Loading

  func loadFolders() {
    folders = NotesStore.listFolders()
    if selectedFolder == nil {
      selectFolder(folders.first)
    } else {
      loadNotes()
    }
    refreshActiveAlarms()
  }

  // Scans all folders for pending alarms (for the sidebar Alarms section).
  func refreshActiveAlarms() {
    var rows: [ActiveAlarmRow] = []
    for folder in folders {
      for note in NotesStore.listNotes(in: folder) {
        for alarm in note.alarms where alarm.isPending {
          rows.append(ActiveAlarmRow(
            id: alarm.id,
            noteTitle: note.title.isEmpty ? "Untitled" : note.title,
            notePath: note.directoryURL.path,
            date: alarm.date,
            label: alarm.title
          ))
        }
      }
    }
    activeAlarms = rows.sorted { $0.date < $1.date }
  }

  func loadNotes() {
    guard let folder = selectedFolder else {
      notes = []
      selectedNoteID = nil
      return
    }
    notes = NotesStore.listNotes(in: folder)
    if selectedNote == nil {
      selectNote(notes.first)
    }
  }

  // MARK: - Filtering / grouping

  var filteredNotes: [Note] {
    let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return notes }
    return notes.filter {
      $0.title.lowercased().contains(query) ||
      ($0.attributed?.string.lowercased().contains(query) ?? false)
    }
  }

  // Notes grouped into sections. When grouping by color, one section per color
  // flag present; otherwise a single unnamed section.
  var sections: [NoteSection] {
    let items = filteredNotes
    guard groupByColor else {
      return [NoteSection(id: "all", title: nil, color: nil, notes: items)]
    }
    let grouped = Dictionary(grouping: items, by: \.color)
    return grouped.keys
      .sorted { $0.sortIndex < $1.sortIndex }
      .map { color in
        NoteSection(
          id: color.rawValue,
          title: color.displayName,
          color: color,
          notes: grouped[color]?.sorted { $0.modified > $1.modified } ?? []
        )
      }
  }

  // MARK: - Selection

  func selectFolder(_ folder: NoteFolder?) {
    selectedFolderID = folder?.id
    selectedNoteID = nil
    loadNotes()
  }

  func selectNote(_ note: Note?) {
    flushPendingSave()
    selectedNoteID = note?.id
    guard let note else {
      editorText = NSAttributedString(string: "")
      return
    }
    if note.attributed == nil {
      note.attributed = NotesStore.loadContent(note)
    }
    loadingNoteIntoEditor = true
    editorText = note.attributed ?? NSAttributedString(string: "")
    loadingNoteIntoEditor = false
  }

  // MARK: - Folder CRUD

  func newFolder() {
    guard let folder = NotesStore.createFolder(named: "New Folder") else { return }
    loadFolders()
    selectFolder(folders.first { $0.url == folder.url })
  }

  func renameFolder(_ folder: NoteFolder, to name: String) {
    NotesStore.renameFolder(folder, to: name)
    loadFolders()
  }

  func deleteFolder(_ folder: NoteFolder) {
    NotesStore.deleteFolder(folder)
    if selectedFolderID == folder.id { selectedFolderID = nil }
    loadFolders()
  }

  // MARK: - Note CRUD

  func newNote() {
    guard let folder = selectedFolder ?? folders.first else {
      // No folder yet — make one, then the note.
      newFolder()
      guard selectedFolder != nil else { return }
      newNote()
      return
    }
    guard let note = NotesStore.createNote(in: folder) else { return }
    notes.insert(note, at: 0)
    selectNote(note)
  }

  func deleteNote(_ note: Note) {
    for alarm in note.alarms { NoteAlarmManager.shared.cancel(alarm) }
    NotesStore.deleteNote(note)
    notes.removeAll { $0.id == note.id }
    if selectedNoteID == note.id {
      selectNote(notes.first)
    }
  }

  // MARK: - Editing

  // Called by the editor whenever its content changes. Derives the title from
  // the first line (macOS Notes style), saves on a short debounce.
  func editorContentChanged(_ attributed: NSAttributedString) {
    guard !loadingNoteIntoEditor, let note = selectedNote else { return }
    note.attributed = attributed
    editorText = attributed
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      persist(note, attributed: attributed)
    }
  }

  private func persist(_ note: Note, attributed: NSAttributedString) {
    let firstLine = attributed.string
      .components(separatedBy: .newlines)
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
      .trimmingCharacters(in: .whitespaces) ?? "Untitled"
    if firstLine != note.title {
      NotesStore.renameNote(note, to: firstLine)
    }
    NotesStore.saveContent(note, attributed: attributed)
  }

  func flushPendingSave() {
    saveTask?.cancel()
    saveTask = nil
    if let note = selectedNote, let attributed = note.attributed {
      persist(note, attributed: attributed)
    }
  }

  // MARK: - Color flags

  func setColor(_ color: NoteColor, for note: Note) {
    note.color = color
    NotesStore.saveMeta(note)
  }

  // MARK: - Alarms

  func addAlarm(_ date: Date, title: String, to note: Note) {
    let alarm = NoteAlarm(date: date, title: title)
    note.alarms.append(alarm)
    NotesStore.saveMeta(note)
    NoteAlarmManager.shared.schedule(alarm, for: note)
    refreshActiveAlarms()
  }

  func removeAlarm(_ alarm: NoteAlarm, from note: Note) {
    note.alarms.removeAll { $0.id == alarm.id }
    NotesStore.saveMeta(note)
    NoteAlarmManager.shared.cancel(alarm)
    refreshActiveAlarms()
  }

  func clearPastAlarms(from note: Note) {
    let past = note.alarms.filter { !$0.isPending }
    for alarm in past { NoteAlarmManager.shared.cancel(alarm) }
    note.alarms.removeAll { !$0.isPending }
    NotesStore.saveMeta(note)
    refreshActiveAlarms()
  }

  // MARK: - Grouping

  func toggleCollapsed(_ id: String) {
    if collapsedColors.contains(id) {
      collapsedColors.remove(id)
    } else {
      collapsedColors.insert(id)
    }
  }

  func isCollapsed(_ id: String) -> Bool { collapsedColors.contains(id) }
}

struct NoteSection: Identifiable {
  let id: String
  let title: String?
  let color: NoteColor?
  let notes: [Note]
}

struct ActiveAlarmRow: Identifiable {
  let id: UUID
  let noteTitle: String
  let notePath: String
  let date: Date
  let label: String
}
