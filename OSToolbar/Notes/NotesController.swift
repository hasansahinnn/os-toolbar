import AppKit
import Defaults
import Foundation
import Observation
import SwiftUI

/// App-level state for the Notes feature. Owns the folder/note selection, the
/// list view-model (filtering, sorting, grouping), debounced autosave, and
/// alarm scheduling integration. Disk persistence is delegated to NotesStore.
@MainActor
@Observable
final class NotesController {
  static let shared = NotesController()

  var folders: [NoteFolder] = []
  var notes: [Note] = []
  // Pending alarms across every folder, shown in the sidebar.
  var activeAlarms: [ActiveAlarmRow] = []

  var selectedFolderID: NoteFolder.ID?
  var selectedNoteID: Note.ID?

  var searchQuery: String = ""
  var groupByColor: Bool = true
  // Stored observable (not a Defaults-backed computed) so SwiftUI re-renders on change.
  var sortMode: NoteSortMode = NoteSortMode(rawValue: Defaults[.notesSortMode]) ?? .manual {
    didSet { Defaults[.notesSortMode] = sortMode.rawValue }
  }
  var collapsedColors: Set<String> = []

  // Freshly created → list opens inline rename immediately.
  var justCreatedFolderID: NoteFolder.ID?
  var justCreatedNoteID: Note.ID?

  var editorText = NSAttributedString(string: "")

  private var saveTask: Task<Void, Never>?
  private var loadingNoteIntoEditor = false
  // Only flush autosave when there were real edits (so selection doesn't bump `modified`).
  private var dirtyNoteID: Note.ID?

  private var windowController: NotesWindowController?

  var selectedFolder: NoteFolder? {
    folders.first { $0.id == selectedFolderID }
  }
  var selectedNote: Note? {
    notes.first { $0.id == selectedNoteID }
  }

  // MARK: - Window

  /// Shows the Notes window, creating its controller lazily.
  func openWindow() {
    if windowController == nil {
      windowController = NotesWindowController()
    }
    loadFolders()
    windowController?.show()
  }

  /// Opens the Notes window and navigates to the note at the given path
  /// (used when the user clicks a fired alarm).
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

  /// Re-reads folders from disk and refreshes the alarms sidebar.
  func loadFolders() {
    folders = NotesStore.listFolders()
    if selectedFolder == nil {
      selectFolder(folders.first)
    } else {
      loadNotes()
    }
    refreshActiveAlarms()
  }

  // Pending-alarm scan across every folder (sidebar Alarms section).
  // Detached so the disk walk never blocks the UI.
  func refreshActiveAlarms() {
    Task.detached(priority: .utility) {
      var rows: [ActiveAlarmRow] = []
      for folder in NotesStore.listFolders() {
        for note in NotesStore.listNotes(in: folder, generateMissingPreviews: false) {
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
      let sorted = rows.sorted { $0.date < $1.date }
      await MainActor.run { self.activeAlarms = sorted }
    }
  }

  /// Re-reads the notes belonging to the currently-selected folder.
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

  private func sortedNotes(_ items: [Note]) -> [Note] {
    switch sortMode {
    case .manual:
      return items
    case .edited:
      return items.sorted { $0.modified > $1.modified }
    case .created:
      return items.sorted { $0.created > $1.created }
    case .title:
      return items.sorted {
        let a = $0.title.isEmpty ? "Untitled" : $0.title
        let b = $1.title.isEmpty ? "Untitled" : $1.title
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
      }
    }
  }

  // Pinned section on top, then by-color sections (or a single section when
  // grouping is off). Items inside each section sorted per `sortMode`.
  var sections: [NoteSection] {
    let items = filteredNotes
    let pinned = sortedNotes(items.filter { $0.isPinned })
    let unpinned = items.filter { !$0.isPinned }

    var result: [NoteSection] = []
    if !pinned.isEmpty {
      result.append(NoteSection(id: "pinned", title: "Pinned", color: nil, notes: pinned))
    }

    if groupByColor {
      let grouped = Dictionary(grouping: unpinned, by: \.color)
      for color in grouped.keys.sorted(by: { $0.sortIndex < $1.sortIndex }) {
        result.append(NoteSection(
          id: color.rawValue,
          title: color.displayName,
          color: color,
          notes: sortedNotes(grouped[color] ?? [])
        ))
      }
    } else {
      result.append(NoteSection(
        id: "all",
        title: pinned.isEmpty ? nil : "Notes",
        color: nil,
        notes: sortedNotes(unpinned)
      ))
    }
    return result
  }

  // MARK: - Selection

  /// Sets the active folder, clears note selection, and reloads its notes.
  func selectFolder(_ folder: NoteFolder?) {
    selectedFolderID = folder?.id
    selectedNoteID = nil
    loadNotes()
  }

  /// Switches the editor to a different note. Flushes pending autosave, drops
  /// the previous note's loaded attributed string, and lazy-loads the new one.
  func selectNote(_ note: Note?) {
    flushPendingSave()
    // Drop the previous note's attributed cache so image-heavy notes don't pile up.
    if let previousID = selectedNoteID, previousID != note?.id {
      notes.first(where: { $0.id == previousID })?.attributed = nil
    }
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

  /// Creates a new folder ("New Folder"), selects it, and primes inline rename.
  func newFolder() {
    guard let folder = NotesStore.createFolder(named: "New Folder") else { return }
    loadFolders()
    selectFolder(folders.first { $0.url == folder.url })
    justCreatedFolderID = folder.id
  }

  /// Renames the folder on disk, reloads the folder list, keeps selection.
  func renameFolder(_ folder: NoteFolder, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != folder.name else { return }
    NotesStore.renameFolder(folder, to: trimmed)
    let newID = folder.url
    loadFolders()
    selectFolder(folders.first { $0.id == newID })
  }

  /// Trashes the folder (and all its notes).
  func deleteFolder(_ folder: NoteFolder) {
    NotesStore.deleteFolder(folder)
    if selectedFolderID == folder.id { selectedFolderID = nil }
    loadFolders()
  }

  // MARK: - Note CRUD

  /// Creates a new note in the active folder; auto-creates a folder if none.
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

  /// Renames a note (independent of body text).
  func renameNote(_ note: Note, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != note.title else { return }
    NotesStore.renameNote(note, to: trimmed)
    refreshActiveAlarms()
  }

  /// Deletes a note (cancels its alarms first), shifts selection to the next.
  func deleteNote(_ note: Note) {
    for alarm in note.alarms { NoteAlarmManager.shared.cancel(alarm) }
    NotesStore.deleteNote(note)
    notes.removeAll { $0.id == note.id }
    if selectedNoteID == note.id {
      selectNote(notes.first)
    }
  }

  // MARK: - Editing

  // Editor → controller. Debounced autosave (500ms). `expectedNoteID` rejects
  // stray textDidChange events during selection switch.
  func editorContentChanged(_ attributed: NSAttributedString, expectedNoteID: Note.ID? = nil) {
    guard !loadingNoteIntoEditor, let note = selectedNote else { return }
    if let expectedNoteID, expectedNoteID != note.id { return }
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

  // Drops every loaded note's attributed cache. Called on window close.
  func releaseAllLoadedContent() {
    for note in notes { note.attributed = nil }
    editorText = NSAttributedString(string: "")
  }

  /// Flushes the debounced autosave immediately. No-op when nothing's dirty —
  /// selection alone must not bump `modified` (would re-sort the list).
  func flushPendingSave() {
    saveTask?.cancel()
    saveTask = nil
    guard let id = dirtyNoteID,
          let note = notes.first(where: { $0.id == id }),
          let attributed = note.attributed else { return }
    persist(note, attributed: attributed)
    dirtyNoteID = nil
  }

  // MARK: - Pin / Duplicate / Move / Share

  /// Flips a note's pinned state and persists.
  func togglePin(_ note: Note) {
    note.isPinned.toggle()
    NotesStore.saveMeta(note)
  }

  /// Duplicates a note (new UUID, " Copy" suffix); selects the copy.
  func duplicate(_ note: Note) {
    guard let copy = NotesStore.duplicateNote(note) else { return }
    notes.insert(copy, at: 0)
    selectNote(copy)
  }

  /// Moves a note to another folder, re-scheduling its alarms under the new path.
  func move(_ note: Note, to folder: NoteFolder) {
    guard folder.id != selectedFolderID else { return }
    for alarm in note.alarms { NoteAlarmManager.shared.cancel(alarm) }
    _ = NotesStore.moveNote(note, to: folder)
    notes.removeAll { $0.id == note.id }
    if selectedNoteID == note.id { selectNote(notes.first) }
    // Re-schedule alarms for the moved note (path changed).
    NoteAlarmManager.shared.reschedule(for: note)
    refreshActiveAlarms()
  }

  /// Opens the native macOS share sheet on the note's attributed content.
  /// Services pick whichever representation they support.
  func shareNoteContent(_ note: Note) {
    let attributed = note.attributed ?? NotesStore.loadContent(note)
    let payload: NSAttributedString = attributed.length > 0
      ? attributed
      : NSAttributedString(string: note.title.isEmpty ? "Untitled" : note.title)
    share(items: [payload])
  }

  // HTML with image attachments inlined as base64 data URIs.
  // NSAttributedString's default HTML export drops them as unresolved refs,
  // which is why Word / Google Docs etc. lose the images.
  private static func buildHTMLWithInlineImages(_ attributed: NSAttributedString) -> Data? {
    let fullRange = NSRange(location: 0, length: attributed.length)
    var html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"/></head><body>"
    let nsText = attributed.string as NSString
    attributed.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
      if let attachment = attrs[.attachment] as? NSTextAttachment {
        let image = attachment.image
          ?? attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
        if let image,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
          let base64 = png.base64EncodedString()
          html.append("<img src=\"data:image/png;base64,\(base64)\" />")
        }
        return
      }
      var escaped = nsText.substring(with: range)
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
      escaped = escaped.replacingOccurrences(of: "\n", with: "<br/>")
      var style: [String] = []
      if let font = attrs[.font] as? NSFont {
        let traits = NSFontManager.shared.traits(of: font)
        if traits.contains(.boldFontMask) { style.append("font-weight:bold") }
        if traits.contains(.italicFontMask) { style.append("font-style:italic") }
        style.append("font-size:\(Int(font.pointSize))px")
        if let family = font.familyName { style.append("font-family:'\(family)'") }
      }
      if let color = attrs[.foregroundColor] as? NSColor,
         let rgb = color.usingColorSpace(.sRGB) {
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        style.append("color:rgb(\(r),\(g),\(b))")
      }
      if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
        style.append("text-decoration:underline")
      }
      if let link = attrs[.link] {
        let href: String
        if let url = link as? URL { href = url.absoluteString }
        else if let str = link as? String { href = str }
        else { href = "" }
        html.append("<a href=\"\(href)\">\(escaped)</a>")
        return
      }
      if !style.isEmpty {
        html.append("<span style=\"\(style.joined(separator: ";"))\">\(escaped)</span>")
      } else {
        html.append(escaped)
      }
    }
    html.append("</body></html>")
    return html.data(using: .utf8)
  }

  // Presents the native macOS share sheet for the given items (note dir or
  // folder URL). Anchored on the key window so it appears in the right place.
  func share(items: [Any]) {
    guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
          let view = window.contentView else { return }
    let picker = NSSharingServicePicker(items: items)
    picker.show(
      relativeTo: NSRect(x: view.bounds.midX - 1, y: 0, width: 2, height: 2),
      of: view,
      preferredEdge: .minY
    )
  }

  // MARK: - Color flags

  func setColor(_ color: NoteColor, for note: Note) {
    note.color = color
    NotesStore.saveMeta(note)
  }

  // MARK: - Alarms

  /// Adds an alarm to the note and schedules it with NoteAlarmManager.
  func addAlarm(_ date: Date, title: String, to note: Note) {
    // Zero seconds so "21:24" fires at 21:24:00, not part-way into the next minute.
    var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.second = 0
    let fireDate = Calendar.current.date(from: components) ?? date
    let alarm = NoteAlarm(date: fireDate, title: title)
    note.alarms.append(alarm)
    NotesStore.saveMeta(note)
    NoteAlarmManager.shared.schedule(alarm, for: note)
    refreshActiveAlarms()
  }

  /// Removes an alarm and cancels its pending fire.
  func removeAlarm(_ alarm: NoteAlarm, from note: Note) {
    note.alarms.removeAll { $0.id == alarm.id }
    NotesStore.saveMeta(note)
    NoteAlarmManager.shared.cancel(alarm)
    refreshActiveAlarms()
  }

  /// Drops fired/past alarms from a note.
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

  /// Triggers a 3s-debounced full-corpus search across every folder/note.
  /// Results land in `globalSearchResults` grouped by folder.
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
    // Detached: title match short-circuits before the per-note RTFD parse.
    Task.detached(priority: .utility) {
      var sections: [GlobalSearchSection] = []
      for folder in NotesStore.listFolders() {
        let notes = NotesStore.listNotes(in: folder, generateMissingPreviews: false)
        let matches = notes.filter { note in
          if note.title.lowercased().contains(needle) { return true }
          return NotesStore.loadContent(note).string.lowercased().contains(needle)
        }
        if !matches.isEmpty {
          sections.append(GlobalSearchSection(
            id: folder.url.path,
            folderName: folder.name,
            notes: matches
          ))
        }
      }
      await MainActor.run {
        self.globalSearchResults = sections
        self.globalSearchPending = false
      }
    }
  }

  func openGlobalSearchResult(_ note: Note) {
    revealNote(atPath: note.directoryURL.path)
  }

  // MARK: - Manual ordering (drag & drop)

  func moveFolders(from source: IndexSet, to destination: Int) {
    var arr = folders
    arr.move(fromOffsets: source, toOffset: destination)
    folders = arr
    NotesStore.setFolderOrder(arr.map { $0.name })
  }

  // Folder reorder drop. Direction-aware insertion (before for up, after for down).
  func dropFolder(draggedPath: String, onto target: NoteFolder) {
    let draggedURL = URL(fileURLWithPath: draggedPath)
    guard draggedURL != target.url,
          let dragged = folders.first(where: { $0.url == draggedURL }) else { return }
    let sourceIdx = folders.firstIndex { $0.url == draggedURL } ?? -1
    let targetIdx = folders.firstIndex { $0.url == target.url } ?? -1
    guard sourceIdx >= 0, targetIdx >= 0, sourceIdx != targetIdx else { return }
    var arr = folders
    arr.remove(at: sourceIdx)
    var insertIdx = arr.firstIndex { $0.url == target.url } ?? arr.endIndex
    if sourceIdx < targetIdx { insertIdx += 1 }
    arr.insert(dragged, at: insertIdx)
    folders = arr
    NotesStore.setFolderOrder(arr.map { $0.name })
  }

  // Note reorder drop. Same-section only (drag never changes color flag).
  // Flips sortMode to `.manual` so the new order is actually visible.
  func dropNote(draggedID: UUID, onto targetNote: Note, sectionID: String) {
    guard draggedID != targetNote.id else { return }
    guard let section = sections.first(where: { $0.id == sectionID }) else { return }
    let sectionIDs = Set(section.notes.map { $0.id })
    guard sectionIDs.contains(draggedID), sectionIDs.contains(targetNote.id),
          let dragged = notes.first(where: { $0.id == draggedID }) else { return }

    if sortMode != .manual { sortMode = .manual }

    let sourceIdx = notes.firstIndex { $0.id == draggedID } ?? -1
    let targetIdx = notes.firstIndex { $0.id == targetNote.id } ?? -1
    guard sourceIdx >= 0, targetIdx >= 0, sourceIdx != targetIdx else { return }

    var rebuilt = notes
    rebuilt.remove(at: sourceIdx)
    var insertIdx = rebuilt.firstIndex { $0.id == targetNote.id } ?? rebuilt.endIndex
    // Downward drag → insert AFTER target; upward → BEFORE.
    if sourceIdx < targetIdx { insertIdx += 1 }
    rebuilt.insert(dragged, at: insertIdx)
    notes = rebuilt
    if let folder = selectedFolder {
      NotesStore.setNoteOrder(in: folder, ids: rebuilt.map { $0.id })
    }
  }

  /// Copies the note to the system pasteboard in 4 representations so paste
  /// works everywhere with images intact: RTFD (Apple), HTML with inline
  /// base64 (web/Office), RTF, plain text.
  func copyNoteToClipboard(_ note: Note) {
    let attributed = note.attributed ?? NotesStore.loadContent(note)
    let range = NSRange(location: 0, length: attributed.length)

    var declared: [NSPasteboard.PasteboardType] = []
    var rtfdData: Data?
    if let wrapper = try? attributed.fileWrapper(
        from: range,
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
       let data = try? wrapper.serializedRepresentation {
      rtfdData = data
      declared.append(.rtfd)
    }
    let htmlData: Data? = Self.buildHTMLWithInlineImages(attributed)
    if htmlData != nil { declared.append(.html) }
    var rtfData: Data?
    if let rtf = try? attributed.data(
        from: range,
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
      rtfData = rtf
      declared.append(.rtf)
    }
    declared.append(.string)

    let pb = NSPasteboard.general
    pb.clearContents()
    pb.declareTypes(declared, owner: nil)
    if let rtfdData { pb.setData(rtfdData, forType: .rtfd) }
    if let htmlData { pb.setData(htmlData, forType: .html) }
    if let rtfData { pb.setData(rtfData, forType: .rtf) }
    let text = attributed.string
    pb.setString(text.isEmpty ? (note.title.isEmpty ? "Untitled" : note.title) : text, forType: .string)
  }

  // Single-section reorder. Other sections' notes keep their slots in `notes`.
  func moveNotes(sectionID: String, from source: IndexSet, to destination: Int) {
    guard let section = sections.first(where: { $0.id == sectionID }) else { return }
    var sectionNotes = section.notes
    sectionNotes.move(fromOffsets: source, toOffset: destination)

    let sectionIDs = Set(section.notes.map { $0.id })
    var iter = sectionNotes.makeIterator()
    var rebuilt: [Note] = []
    for note in notes {
      if sectionIDs.contains(note.id) {
        if let next = iter.next() { rebuilt.append(next) }
      } else {
        rebuilt.append(note)
      }
    }
    notes = rebuilt
    if let folder = selectedFolder {
      NotesStore.setNoteOrder(in: folder, ids: rebuilt.map { $0.id })
    }
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
