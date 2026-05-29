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

  // Set when a folder/note is freshly created so the list can immediately put its
  // name into inline-edit mode (like Finder/Notes).
  var justCreatedFolderID: NoteFolder.ID?
  var justCreatedNoteID: Note.ID?

  // The attributed content currently shown in the editor (bound to the note).
  var editorText = NSAttributedString(string: "")

  private var saveTask: Task<Void, Never>?
  private var loadingNoteIntoEditor = false
  // The note with unsaved edits, if any. Used so we only re-save (and bump the
  // modified date / reorder the list) when there were real changes.
  private var dirtyNoteID: Note.ID?

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
          // Preserve the load-time order (already sorted by modified). We do NOT
          // re-sort live, so selecting/editing a note never reshuffles the list.
          notes: grouped[color] ?? []
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
    justCreatedFolderID = folder.id
  }

  func renameFolder(_ folder: NoteFolder, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != folder.name else { return }
    NotesStore.renameFolder(folder, to: trimmed)
    let newID = folder.url
    loadFolders()
    selectFolder(folders.first { $0.id == newID })
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
    justCreatedNoteID = note.id
  }

  // Explicit rename (from double-clicking the title in the list). Independent of
  // the note body — the title no longer auto-derives from the first line.
  func renameNote(_ note: Note, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != note.title else { return }
    NotesStore.renameNote(note, to: trimmed)
    refreshActiveAlarms()
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

  // Called by the editor whenever its content changes. Saves on a short debounce.
  func editorContentChanged(_ attributed: NSAttributedString) {
    guard !loadingNoteIntoEditor, let note = selectedNote else { return }
    note.attributed = attributed
    editorText = attributed
    dirtyNoteID = note.id
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      persist(note, attributed: attributed)
      dirtyNoteID = nil
    }
  }

  private func persist(_ note: Note, attributed: NSAttributedString) {
    NotesStore.saveContent(note, attributed: attributed)
  }

  // Only saves if there were actual edits — otherwise selecting a note would
  // bump its modified date and reshuffle the list.
  func flushPendingSave() {
    saveTask?.cancel()
    saveTask = nil
    guard let id = dirtyNoteID,
          let note = notes.first(where: { $0.id == id }),
          let attributed = note.attributed else { return }
    persist(note, attributed: attributed)
    dirtyNoteID = nil
  }

  // MARK: - Color flags

  func setColor(_ color: NoteColor, for note: Note) {
    note.color = color
    NotesStore.saveMeta(note)
  }

  // MARK: - Alarms

  func addAlarm(_ date: Date, title: String, to note: Note) {
    // Zero the seconds so an alarm set "for 21:24" fires at 21:24:00, not part-way
    // into the next minute (which felt ~1 minute late).
    var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.second = 0
    let fireDate = Calendar.current.date(from: components) ?? date
    let alarm = NoteAlarm(date: fireDate, title: title)
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

  // MARK: - Global search (across all folders)

  var globalSearchResults: [GlobalSearchSection] = []
  var globalSearchPending = false
  private var globalSearchTask: Task<Void, Never>?

  // Debounced ~3s, then searches every note's title and content across all
  // folders, grouping matches by their folder.
  func setGlobalSearch(_ query: String) {
    globalSearchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      globalSearchPending = false
      globalSearchResults = []
      return
    }
    globalSearchPending = true
    globalSearchTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      performGlobalSearch(trimmed)
    }
  }

  private func performGlobalSearch(_ query: String) {
    let needle = query.lowercased()
    var sections: [GlobalSearchSection] = []
    for folder in NotesStore.listFolders() {
      let matches = NotesStore.listNotes(in: folder).filter { note in
        if note.title.lowercased().contains(needle) { return true }
        return NotesStore.loadContent(note).string.lowercased().contains(needle)
      }
      if !matches.isEmpty {
        sections.append(GlobalSearchSection(id: folder.url.path, folderName: folder.name, notes: matches))
      }
    }
    globalSearchResults = sections
    globalSearchPending = false
  }

  func openGlobalSearchResult(_ note: Note) {
    revealNote(atPath: note.directoryURL.path)
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

struct GlobalSearchSection: Identifiable {
  let id: String
  let folderName: String
  let notes: [Note]
}
