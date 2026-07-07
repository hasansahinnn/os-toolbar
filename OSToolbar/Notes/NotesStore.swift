import AppKit
import Defaults
import Foundation

/// On-disk persistence for the Notes feature. Each sidebar folder is a real
/// directory; each note is a subdirectory with `content.rtfd` + `meta.json`.
/// No SwiftData — plain filesystem so users can poke at the files directly.
enum NotesStore {
  // Serial background queue for note writes (RTFD serialize is slow on main).
  private static let ioQueue = DispatchQueue(label: "com.ostoolbar.notes.io", qos: .utility)
  // Real user home (NSHomeDirectory returns the sandbox container).
  static var realHome: URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: dir))
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// New default lives in Library/Application Support — NEVER touched by
  /// iCloud Drive Documents sync, so reads are always local and instant.
  static var defaultRoot: URL {
    realHome
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("OSToolbar", isDirectory: true)
      .appendingPathComponent("Notes", isDirectory: true)
  }

  /// The old default (~/Documents/OSToolbarNotes) — retained for one-time migration.
  private static var legacyDefaultRoot: URL {
    realHome
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("OSToolbarNotes", isDirectory: true)
  }

  // User-chosen folder (security-scoped bookmark) or the default root.
  static var root: URL {
    if let data = Defaults[.notesDirectoryBookmark], let url = resolveBookmark(data) {
      return url
    }
    return defaultRoot
  }

  /// One-shot migration: if the legacy `~/Documents/OSToolbarNotes` folder has
  /// content and the new Library path doesn't, move everything over. Runs at
  /// startup; idempotent — subsequent launches see the new path populated and
  /// skip. Users who picked a custom folder via `chooseDirectory()` are untouched.
  static func migrateLegacyRootIfNeeded() {
    // Only migrate the DEFAULT path. If a custom bookmark is set, respect it.
    guard Defaults[.notesDirectoryBookmark] == nil else { return }
    let legacy = legacyDefaultRoot
    let fresh = defaultRoot
    let fm = FileManager.default
    let legacyContents = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
    guard !legacyContents.isEmpty else { return }
    let freshContents = (try? fm.contentsOfDirectory(atPath: fresh.path)) ?? []
    guard freshContents.isEmpty else { return }
    try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
    for name in legacyContents where !name.hasPrefix(".") {
      let src = legacy.appendingPathComponent(name)
      let dst = fresh.appendingPathComponent(name)
      try? fm.moveItem(at: src, to: dst)
    }
  }

  static var rootDisplayPath: String { root.path(percentEncoded: false) }

  // MARK: - Setup

  /// Creates the notes root if missing and seeds a default "Notes" folder.
  @discardableResult
  static func ensureRoot() -> URL {
    let dir = root
    let scoped = startScopedAccess(for: dir)
    defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Seed a default folder so the sidebar is never empty.
    if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true {
      try? FileManager.default.createDirectory(
        at: dir.appendingPathComponent("Notes", isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    return dir
  }

  // MARK: - Folders

  /// All folders in the notes root, ordered per user preference then name.
  static func listFolders() -> [NoteFolder] {
    let dir = ensureRoot()
    let scoped = startScopedAccess(for: dir)
    defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let folders = contents
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .map { NoteFolder(url: $0) }
    let order = Defaults[.notesFolderOrder]
    let index: [String: Int] = order.enumerated().reduce(into: [:]) { $0[$1.element] = $1.offset }
    return folders.sorted { a, b in
      let ai = index[a.name] ?? Int.max
      let bi = index[b.name] ?? Int.max
      if ai != bi { return ai < bi }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }

  /// Persists the user's manual folder ordering.
  static func setFolderOrder(_ names: [String]) {
    Defaults[.notesFolderOrder] = names
  }

  /// Creates a new folder with a sanitized + de-duplicated name.
  @discardableResult
  static func createFolder(named rawName: String) -> NoteFolder? {
    let dir = ensureRoot()
    let scoped = startScopedAccess(for: dir)
    defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
    let name = uniqueName(sanitize(rawName, fallback: "Folder"), in: dir)
    let url = dir.appendingPathComponent(name, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return NoteFolder(url: url)
    } catch {
      NSLog("OSToolbar Notes: createFolder failed: \(error)")
      return nil
    }
  }

  /// Renames the folder directory on disk; updates the folder reference in place.
  static func renameFolder(_ folder: NoteFolder, to rawName: String) {
    let parent = folder.url.deletingLastPathComponent()
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let name = uniqueName(sanitize(rawName, fallback: "Folder"), in: parent)
    let dest = parent.appendingPathComponent(name, isDirectory: true)
    guard dest != folder.url else { return }
    try? FileManager.default.moveItem(at: folder.url, to: dest)
    folder.url = dest
    folder.name = name
  }

  /// Moves the folder to Trash (recoverable).
  static func deleteFolder(_ folder: NoteFolder) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    try? FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
  }

  // MARK: - Notes

  /// All notes in a folder, ordered per `.order.json` then modification date.
  /// `generateMissingPreviews: false` skips the per-note RTFD parse — pass it
  /// when only metadata is needed (alarm scan, search).
  static func listNotes(in folder: NoteFolder, generateMissingPreviews: Bool = true) -> [Note] {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: folder.url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let loaded: [Note] = contents.compactMap { url -> Note? in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
      let metaURL = url.appendingPathComponent("meta.json")
      guard let data = try? Data(contentsOf: metaURL),
            let meta = try? JSONDecoder.notes.decode(NoteMeta.self, from: data) else {
        return nil
      }
      let note = Note(directoryURL: url, meta: meta)
      // Compute & cache the preview for older notes that don't have one yet.
      if generateMissingPreviews, note.preview.isEmpty,
         let attributed = try? NSAttributedString(
           url: note.contentURL,
           options: [.documentType: NSAttributedString.DocumentType.rtfd],
           documentAttributes: nil
         ) {
        note.preview = makePreview(attributed, title: note.title)
        try? writeMeta(note.meta, to: metaURL)
      }
      return note
    }
    // User-defined order from `.order.json`; unknown notes fall back to recency.
    let orderURL = folder.url.appendingPathComponent(".order.json")
    let savedOrder: [UUID] = (try? Data(contentsOf: orderURL))
      .flatMap { try? JSONDecoder.notes.decode([UUID].self, from: $0) } ?? []
    let orderIndex: [UUID: Int] = savedOrder.enumerated().reduce(into: [:]) { $0[$1.element] = $1.offset }
    return loaded.sorted { a, b in
      let ai = orderIndex[a.id] ?? Int.max
      let bi = orderIndex[b.id] ?? Int.max
      if ai != bi { return ai < bi }
      return a.modified > b.modified
    }
  }

  /// Persists the user's manual note ordering inside a folder.
  static func setNoteOrder(in folder: NoteFolder, ids: [UUID]) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let url = folder.url.appendingPathComponent(".order.json")
    if let data = try? JSONEncoder.notes.encode(ids) {
      try? data.write(to: url, options: .atomic)
    }
  }

  /// Creates an empty note (empty RTFD + default meta) inside a folder.
  @discardableResult
  static func createNote(in folder: NoteFolder, title: String = "New Note") -> Note? {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let name = uniqueName(sanitize(title, fallback: "New Note"), in: folder.url)
    let dir = folder.url.appendingPathComponent(name, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let meta = NoteMeta(title: title)
      let note = Note(directoryURL: dir, meta: meta)
      note.attributed = NSAttributedString(string: "")
      try writeMeta(meta, to: dir.appendingPathComponent("meta.json"))
      try writeContent(NSAttributedString(string: ""), to: dir.appendingPathComponent("content.rtfd"))
      return note
    } catch {
      NSLog("OSToolbar Notes: createNote failed: \(error)")
      return nil
    }
  }

  /// Moves the note to Trash (recoverable).
  static func deleteNote(_ note: Note) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    try? FileManager.default.trashItem(at: note.directoryURL, resultingItemURL: nil)
  }

  // Copies the note's directory next to itself with a new UUID + " Copy" suffix.
  static func duplicateNote(_ note: Note) -> Note? {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let parent = note.directoryURL.deletingLastPathComponent()
    let baseName = uniqueName(sanitize(note.title + " Copy", fallback: "Note Copy"), in: parent)
    let destination = parent.appendingPathComponent(baseName, isDirectory: true)
    do {
      try FileManager.default.copyItem(at: note.directoryURL, to: destination)
    } catch {
      NSLog("OSToolbar Notes: duplicate failed: \(error)")
      return nil
    }
    // Give the copy a fresh identity + fresh alarms so original alarms aren't
    // duplicated as scheduled timers.
    var meta = NoteMeta(
      id: UUID(),
      title: note.title + " Copy",
      color: note.color,
      created: Date(),
      modified: Date(),
      alarms: [],
      preview: note.preview,
      isPinned: note.isPinned
    )
    let metaURL = destination.appendingPathComponent("meta.json")
    if let data = try? JSONEncoder.notes.encode(meta) {
      try? data.write(to: metaURL, options: .atomic)
    }
    return Note(directoryURL: destination, meta: meta)
  }

  // Moves a note's directory to a different folder; returns the new note ref.
  @discardableResult
  static func moveNote(_ note: Note, to folder: NoteFolder) -> Note? {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let name = uniqueName(note.directoryURL.lastPathComponent, in: folder.url)
    let destination = folder.url.appendingPathComponent(name, isDirectory: true)
    do {
      try FileManager.default.moveItem(at: note.directoryURL, to: destination)
    } catch {
      NSLog("OSToolbar Notes: moveNote failed: \(error)")
      return nil
    }
    note.directoryURL = destination
    return note
  }

  /// Reads the note's `content.rtfd` into an NSAttributedString. Returns empty
  /// string on missing/corrupt file.
  static func loadContent(_ note: Note) -> NSAttributedString {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    if let attr = try? NSAttributedString(
      url: note.contentURL,
      options: [.documentType: NSAttributedString.DocumentType.rtfd],
      documentAttributes: nil
    ) {
      return attr
    }
    return NSAttributedString(string: "")
  }

  /// Writes the note's attributed content to disk. In-memory model updates
  /// immediately; RTFD serialization happens on a background queue.
  static func saveContent(_ note: Note, attributed: NSAttributedString) {
    // In-memory updates immediate; RTFD write on ioQueue.
    note.modified = Date()
    note.preview = makePreview(attributed, title: note.title)
    let contentURL = note.contentURL
    let metaURL = note.metaURL
    let metaSnapshot = note.meta
    // Defensive copy in case the editor mutates storage mid-write.
    let snapshot = (attributed.copy() as? NSAttributedString) ?? attributed
    ioQueue.async {
      let scoped = startScopedAccess(for: root)
      defer { if scoped { root.stopAccessingSecurityScopedResource() } }
      try? writeContent(snapshot, to: contentURL)
      try? writeMeta(metaSnapshot, to: metaURL)
    }
  }

  // First non-empty body line that isn't just the title, capped for the list.
  private static func makePreview(_ attributed: NSAttributedString, title: String) -> String {
    let titleTrim = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = attributed.string
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let line = lines.first { $0 != titleTrim } ?? lines.first ?? ""
    return String(line.prefix(120))
  }

  /// Persists only `meta.json` (no content rewrite). Use after color/pin/alarm updates.
  static func saveMeta(_ note: Note) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    try? writeMeta(note.meta, to: note.metaURL)
  }

  /// Renames the note's directory to match a new title (preserves content/meta).
  static func renameNote(_ note: Note, to rawTitle: String) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let parent = note.directoryURL.deletingLastPathComponent()
    let title = rawTitle.isEmpty ? "Untitled" : rawTitle
    note.title = title
    let desiredName = sanitize(title, fallback: "Untitled")
    if desiredName != note.directoryURL.lastPathComponent {
      let name = uniqueName(desiredName, in: parent)
      let dest = parent.appendingPathComponent(name, isDirectory: true)
      if (try? FileManager.default.moveItem(at: note.directoryURL, to: dest)) != nil {
        note.directoryURL = dest
      }
    }
    saveMeta(note)
  }

  // MARK: - Alarms

  /// Marks an alarm `fired = true` directly on disk so subsequent launches
  /// don't reschedule it. Called by NoteAlarmManager when an alarm triggers.
  static func markAlarmFired(noteDirectoryPath: String, alarmID: UUID) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    let metaURL = URL(fileURLWithPath: noteDirectoryPath).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: metaURL),
          var meta = try? JSONDecoder.notes.decode(NoteMeta.self, from: data),
          let idx = meta.alarms.firstIndex(where: { $0.id == alarmID }) else {
      return
    }
    meta.alarms[idx].fired = true
    try? writeMeta(meta, to: metaURL)
  }

  // MARK: - Emptiness checks (for delete confirmations)

  static func noteCount(in folder: NoteFolder) -> Int {
    listNotes(in: folder).count
  }

  static func noteHasContent(_ note: Note) -> Bool {
    let text = (note.attributed ?? loadContent(note)).string
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Images

  /// Builds a text attachment for an inserted image. Display size is capped to
  /// `maxWidth` (aspect-preserved); full bytes survive in the fileWrapper for
  /// the click-to-view-full-size feature.
  static func makeImageAttachment(image: NSImage, maxWidth: CGFloat = 320) -> NSTextAttachment? {
    guard let tiff = image.tiffRepresentation else { return nil }
    let wrapper = FileWrapper(regularFileWithContents: tiff)
    wrapper.preferredFilename = "image-\(UUID().uuidString).tiff"
    let attachment = NSTextAttachment(fileWrapper: wrapper)
    let size = image.size
    if size.width > maxWidth, size.width > 0 {
      let scale = maxWidth / size.width
      attachment.bounds = CGRect(x: 0, y: 0, width: maxWidth, height: (size.height * scale).rounded())
    } else {
      attachment.bounds = CGRect(origin: .zero, size: size)
    }
    return attachment
  }

  // MARK: - Mock data (one-time seed for testing)

  // Trashes folders matching the given names (used to clear earlier auto-seeded
  // demo folders before reseeding). Recoverable from the Trash.
  static func removeFolders(named names: [String]) {
    let scoped = startScopedAccess(for: root)
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    for folder in listFolders() where names.contains(folder.name) {
      try? FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
    }
  }

  static func seedMockData() {
    let calendar = Calendar.current
    func future(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
      let base = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
      return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    if let work = createFolder(named: "Work") {
      seedNote(in: work, title: "Q3 Launch Plan", color: .blue, lines: [
        "Q3 Launch Plan",
        "Goals before the OSToolbar 1.0 release:",
        "○ Finalise the Notes module",
        "○ Record demo screenshots",
        "○ Publish the DMG to GitHub Releases"
      ], link: ("Release checklist", "https://github.com/hasansahinnn/os-toolbar"),
         image: ("LAUNCH", .systemBlue),
         alarms: [(future(1, 9, 0), "Send the launch announcement")])

      seedNote(in: work, title: "Weekly standup", color: .blue, lines: [
        "Weekly standup",
        "Discussion points:",
        "○ Notes alarms shipped",
        "○ Clipboard scroll freeze fixed",
        "○ Next up: keyboard shortcuts pass"
      ], link: nil, image: nil, alarms: [])

      seedNote(in: work, title: "Pay hosting invoice", color: .red, lines: [
        "Pay hosting invoice",
        "Monthly server bill — settle before the due date.",
        "Amount: about $42"
      ], link: nil, image: nil, alarms: [(future(2, 10, 30), "Pay the hosting invoice")])
    }

    if let personal = createFolder(named: "Personal") {
      seedNote(in: personal, title: "Groceries", color: .green, lines: [
        "Groceries",
        "○ Milk",
        "○ Eggs",
        "○ Coffee beans",
        "○ Olive oil"
      ], link: nil, image: ("SHOP", .systemGreen), alarms: [])

      seedNote(in: personal, title: "Gym plan", color: .green, lines: [
        "Gym plan",
        "Mon — Push",
        "Wed — Pull",
        "Fri — Legs"
      ], link: nil, image: nil, alarms: [])

      seedNote(in: personal, title: "Weekend in Oxford", color: .orange, lines: [
        "Weekend in Oxford",
        "135 Cornwallis Rd, Oxford OX4 3NH",
        "Check the Saturday morning train times."
      ], link: ("Open in Maps", "https://maps.apple.com"), image: nil, alarms: [])
    }

    if let ideas = createFolder(named: "Project Ideas") {
      seedNote(in: ideas, title: "OSToolbar concept", color: .purple, lines: [
        "OSToolbar concept",
        "A privacy-first menu-bar toolkit:",
        "• Clipboard history",
        "• Screenshots with annotation",
        "• Notes with alarms",
        "No network — everything stays on the Mac."
      ], link: ("Project repo", "https://github.com/hasansahinnn/os-toolbar"),
         image: ("IDEA", .systemPurple), alarms: [])

      seedNote(in: ideas, title: "Reading list", color: .none, lines: [
        "Reading list",
        "• Thinking, Fast and Slow",
        "• The Pragmatic Programmer",
        "• Shape Up"
      ], link: nil, image: nil, alarms: [(future(3, 19, 0), "Start the new book tonight")])
    }
  }

  private static func seedNote(
    in folder: NoteFolder,
    title: String,
    color: NoteColor,
    lines: [String],
    link: (String, String)?,
    image: (String, NSColor)?,
    alarms: [(Date, String)]
  ) {
    guard let note = createNote(in: folder, title: title) else { return }
    note.color = color

    let content = NSMutableAttributedString()
    for (index, line) in lines.enumerated() {
      let font = index == 0 ? NSFont.boldSystemFont(ofSize: 18) : NSFont.systemFont(ofSize: 14)
      content.append(NSAttributedString(
        string: line + "\n",
        attributes: [.font: font, .foregroundColor: NSColor.textColor]
      ))
    }
    if let link, let url = URL(string: link.1) {
      content.append(NSAttributedString(
        string: link.0 + "\n",
        attributes: [.link: url, .font: NSFont.systemFont(ofSize: 14)]
      ))
    }
    if let image, let attachment = makeImageAttachment(image: sampleImage(image.0, color: image.1)) {
      content.append(NSAttributedString(attachment: attachment))
      content.append(NSAttributedString(string: "\n"))
    }
    note.alarms = alarms.map { NoteAlarm(date: $0.0, title: $0.1) }
    note.attributed = content
    saveContent(note, attributed: content)
    saveMeta(note)
  }

  private static func sampleImage(_ text: String, color: NSColor, size: NSSize = NSSize(width: 280, height: 150)) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.white,
      .font: NSFont.boldSystemFont(ofSize: 28),
      .paragraphStyle: style
    ]
    let string = text as NSString
    let textSize = string.size(withAttributes: attrs)
    string.draw(
      at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
      withAttributes: attrs
    )
    image.unlockFocus()
    return image
  }

  // MARK: - Choosing a custom folder

  /// Opens an NSOpenPanel for the user to pick a new notes folder; persists
  /// the result as a security-scoped bookmark.
  static func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = root
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let bookmark = try? url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) {
      Defaults[.notesDirectoryBookmark] = bookmark
    }
  }

  /// Opens the notes root folder in Finder.
  static func openInFinder() {
    let dir = ensureRoot()
    NSWorkspace.shared.open(dir)
  }

  // MARK: - Helpers

  private static func writeContent(_ attributed: NSAttributedString, to url: URL) throws {
    let range = NSRange(location: 0, length: attributed.length)
    let wrapper = try attributed.fileWrapper(
      from: range,
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
    )
    try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
  }

  private static func writeMeta(_ meta: NoteMeta, to url: URL) throws {
    let data = try JSONEncoder.notes.encode(meta)
    try data.write(to: url, options: .atomic)
  }

  private static func sanitize(_ name: String, fallback: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let cleaned = trimmed
      .components(separatedBy: invalid)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let oneLine = cleaned.components(separatedBy: .newlines).first ?? cleaned
    let limited = String(oneLine.prefix(60)).trimmingCharacters(in: .whitespaces)
    return limited.isEmpty ? fallback : limited
  }

  private static func uniqueName(_ base: String, in directory: URL) -> String {
    let fm = FileManager.default
    var candidate = base
    var counter = 2
    while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
      candidate = "\(base) \(counter)"
      counter += 1
    }
    return candidate
  }

  private static func resolveBookmark(_ data: Data) -> URL? {
    var stale = false
    return try? URL(
      resolvingBookmarkData: data,
      options: .withSecurityScope,
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
  }

  private static func startScopedAccess(for dir: URL) -> Bool {
    guard let data = Defaults[.notesDirectoryBookmark],
          let url = resolveBookmark(data),
          url == dir else { return false }
    return url.startAccessingSecurityScopedResource()
  }
}

extension JSONEncoder {
  static var notes: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var notes: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
