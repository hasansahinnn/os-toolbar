import AppKit
import SwiftUI

extension DateFormatter {
  static let noteAlarm: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd-MM-yyyy HH:mm"
    return formatter
  }()
}

/// Top-level Notes window UI. Three-column layout: folders sidebar (with
/// alarms section + global search), notes list (filtered/grouped/sorted),
/// editor with toolbar (bold/italic/lists/insert image/table/clear-formatting).
struct NotesRootView: View {
  @Bindable private var controller = NotesController.shared
  @State private var bridge = NoteEditorBridge()
  @State private var fontSize: CGFloat = 14
  @State private var showTableSheet = false
  @State private var tableRows = 2
  @State private var tableCols = 2

  // Inline rename state (one item at a time).
  @State private var editingFolderID: NoteFolder.ID?
  @State private var editingNoteID: Note.ID?
  @State private var editingText = ""
  @FocusState private var renameFocused: Bool
  @State private var alarmsExpanded = false

  // Global search-all-notes state.
  @State private var searchActive = false
  @State private var searchText = ""
  @FocusState private var searchFieldFocused: Bool

  // Explicit drag-to-reorder mode. When on, rows show a ☰ handle on the left;
  // hold and drag the row to reposition. Disables tap-to-select while active.
  @State private var reorderFoldersMode = false
  @State private var reorderNotesMode = false

  // Clear-formatting popover (eraser icon in the editor toolbar).
  @State private var showClearFormatting = false
  @State private var clearBackground = true
  @State private var clearForeground = false
  @State private var clearUnderline = true
  @State private var clearStrikethrough = true
  @State private var clearFontTraits = false
  @State private var clearFontFamilyAndSize = false
  @State private var clearLinks = false

  private var folderSelection: Binding<NoteFolder.ID?> {
    Binding(
      get: { controller.selectedFolderID },
      set: { id in controller.selectFolder(controller.folders.first { $0.id == id }) }
    )
  }

  private var noteSelection: Binding<Note.ID?> {
    Binding(
      get: { controller.selectedNoteID },
      set: { id in controller.selectNote(controller.notes.first { $0.id == id }) }
    )
  }

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
    } content: {
      notesList
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
    } detail: {
      editor
    }
    .frame(minWidth: 900, minHeight: 560)
    .onAppear { controller.loadFolders() }
    .onChange(of: renameFocused) { _, focused in
      if !focused { commitActiveRename() }
    }
    .onChange(of: controller.justCreatedFolderID) { _, id in
      guard let id, let folder = controller.folders.first(where: { $0.id == id }) else { return }
      controller.justCreatedFolderID = nil
      beginFolderRename(folder)
    }
    .onChange(of: controller.justCreatedNoteID) { _, id in
      guard let id, let note = controller.notes.first(where: { $0.id == id }) else { return }
      controller.justCreatedNoteID = nil
      beginNoteRename(note)
    }
  }

  // MARK: - Sidebar (folders, then alarms)

  private var sidebar: some View {
    VStack(spacing: 0) {
      if reorderFoldersMode {
        reorderBar(title: "Reordering Folders", isOn: $reorderFoldersMode)
        Divider()
      }
      if searchActive {
        searchBar
        Divider()
      }
      if searchActive && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
        searchResults
      } else {
        foldersAndAlarms
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button { controller.newFolder() } label: {
          Image(systemName: "folder.badge.plus")
        }
        .help("New Folder")
        Button { toggleSearch() } label: {
          Image(systemName: "magnifyingglass")
        }
        .help("Search all notes")
      }
    }
  }

  private func reorderBar(title: String, isOn: Binding<Bool>) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
      Text(title).font(.subheadline).foregroundStyle(.secondary)
      Spacer()
      Button("Done") { isOn.wrappedValue = false }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .keyboardShortcut(.return)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial)
  }

  private var searchBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search in all notes", text: $searchText)
        .textFieldStyle(.plain)
        .focused($searchFieldFocused)
        .onChange(of: searchText) { _, value in controller.setGlobalSearch(value) }
        .onSubmit { controller.setGlobalSearch(searchText) }
      if !searchText.isEmpty {
        Button {
          searchText = ""
          controller.setGlobalSearch("")
          searchFieldFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(8)
    .onChange(of: searchFieldFocused) { _, focused in
      if !focused && searchText.isEmpty { searchActive = false }
    }
  }

  private var searchResults: some View {
    List {
      ForEach(controller.globalSearchResults) { section in
        Section {
          ForEach(section.notes) { note in
            Button {
              controller.openGlobalSearchResult(note)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                  .font(.callout).lineLimit(1)
                Text(note.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        } header: {
          Label(section.folderName, systemImage: "folder")
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if controller.globalSearchResults.isEmpty {
        if controller.globalSearchPending {
          ProgressView()
        } else {
          ContentUnavailableView("No Results", systemImage: "magnifyingglass")
        }
      }
    }
  }

  private var foldersAndAlarms: some View {
    List(selection: folderSelection) {
      Section("Folders") {
        ForEach(controller.folders) { folder in folderRow(folder) }
          .onMove { source, destination in
            controller.moveFolders(from: source, to: destination)
          }
      }

      if !controller.activeAlarms.isEmpty {
        Section("Alarms") {
          let shown = alarmsExpanded ? controller.activeAlarms : Array(controller.activeAlarms.prefix(3))
          ForEach(shown) { row in
            Button {
              controller.revealNote(atPath: row.notePath)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                  .foregroundStyle(.orange)
                  .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                  Text(row.noteTitle).font(.callout).lineLimit(1)
                  Text(DateFormatter.noteAlarm.string(from: row.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  if !row.label.isEmpty {
                    Text(row.label).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                  }
                }
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          if controller.activeAlarms.count > 3 {
            Button {
              alarmsExpanded.toggle()
            } label: {
              HStack(spacing: 4) {
                Image(systemName: alarmsExpanded ? "chevron.up" : "chevron.down")
                Text(alarmsExpanded ? "Show less" : "Show \(controller.activeAlarms.count - 3) more")
                Spacer()
              }
              .font(.caption)
              .foregroundStyle(.secondary)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func toggleSearch() {
    searchActive.toggle()
    if searchActive {
      DispatchQueue.main.async { searchFieldFocused = true }
    } else {
      searchText = ""
      controller.setGlobalSearch("")
    }
  }

  private func folderRow(_ folder: NoteFolder) -> some View {
    HStack(spacing: 6) {
      if reorderFoldersMode {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .font(.callout)
          .padding(.trailing, 2)
          .draggable(folder.url.path) {
            HStack(spacing: 4) {
              Image(systemName: "folder")
              Text(folder.name)
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
          }
      }
      Image(systemName: "folder")
      if editingFolderID == folder.id {
        TextField("Folder", text: $editingText)
          .textFieldStyle(.plain)
          .focused($renameFocused)
          .onSubmit { commitActiveRename() }
      } else {
        Text(folder.name)
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .tag(folder.id)
    .when(reorderFoldersMode) { view in
      view.dropDestination(for: String.self) { items, _ in
        guard let path = items.first else { return false }
        controller.dropFolder(draggedPath: path, onto: folder)
        return true
      }
    }
    .when(!reorderFoldersMode) { view in
      view.simultaneousGesture(TapGesture().onEnded {
        guard editingFolderID != folder.id else { return }
        controller.selectFolder(folder)
      })
    }
    .contextMenu {
      Button {
        controller.selectFolder(folder)
        controller.newNote()
      } label: { Label("New Note", systemImage: "square.and.pencil") }
      Button { beginFolderRename(folder) } label: { Label("Rename Folder", systemImage: "pencil") }
      Button { reorderFoldersMode.toggle() } label: {
        Label(reorderFoldersMode ? "Done Reordering" : "Reorder Folders",
              systemImage: "arrow.up.arrow.down")
      }
      Divider()
      Button { reveal(folder.url) } label: { Label("Show in Finder", systemImage: "folder") }
      Button { controller.share(items: [folder.url]) } label: { Label("Share Folder", systemImage: "square.and.arrow.up") }
      Divider()
      Button(role: .destructive) { confirmDeleteFolder(folder) } label: { Label("Delete Folder", systemImage: "trash") }
    }
  }

  // MARK: - Notes list

  private var notesList: some View {
    VStack(spacing: 0) {
      if reorderNotesMode {
        reorderBar(title: "Reordering Notes", isOn: $reorderNotesMode)
        Divider()
      }
      notesListBody
    }
  }

  private var notesListBody: some View {
    List(selection: noteSelection) {
      ForEach(controller.sections) { section in
        if let title = section.title {
          let visible = controller.isCollapsed(section.id) ? [] : section.notes
          Section {
            ForEach(visible) { noteRow($0, sectionID: section.id) }
          } header: {
            groupHeader(section, title: title)
          }
        } else {
          ForEach(section.notes) { noteRow($0, sectionID: section.id) }
        }
      }
    }
    .overlay {
      if controller.filteredNotes.isEmpty {
        ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Create a note with +"))
      }
    }
    .searchable(text: $controller.searchQuery, placement: .toolbar, prompt: "Search")
    .toolbar {
      ToolbarItem {
        Menu {
          ForEach(NoteSortMode.allCases) { mode in
            Button {
              controller.sortMode = mode
            } label: {
              Label(mode.displayName,
                    systemImage: controller.sortMode == mode ? "checkmark" : "")
            }
          }
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort by")
      }
      ToolbarItem {
        Button { controller.groupByColor.toggle() } label: {
          Image(systemName: controller.groupByColor ? "circle.grid.2x2.fill" : "circle.grid.2x2")
        }
        .help("Group by color")
      }
      ToolbarItem {
        Button { controller.newNote() } label: {
          Image(systemName: "square.and.pencil")
        }
        .help("New Note")
      }
    }
  }

  private func groupHeader(_ section: NoteSection, title: String) -> some View {
    Button {
      controller.toggleCollapsed(section.id)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: controller.isCollapsed(section.id) ? "chevron.right" : "chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
        if let color = section.color, color != .none {
          Circle().fill(color.color).frame(width: 8, height: 8)
        }
        Text(title)
        Spacer()
        Text("\(section.notes.count)")
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func noteRow(_ note: Note, sectionID: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        if reorderNotesMode {
          Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .font(.callout)
            .padding(.trailing, 2)
            .draggable(note.id.uuidString) {
              Text(note.title.isEmpty ? "Untitled" : note.title)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        if note.color != .none {
          Circle().fill(note.color.color).frame(width: 9, height: 9)
        }
        if editingNoteID == note.id {
          TextField("Title", text: $editingText)
            .textFieldStyle(.plain)
            .font(.headline)
            .focused($renameFocused)
            .onSubmit { commitActiveRename() }
        } else {
          Text(note.title.isEmpty ? "Untitled" : note.title)
            .font(.headline)
            .lineLimit(1)
        }
        Spacer()
        if note.isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(45))
        }
        if note.hasPendingAlarm {
          Image(systemName: "bell.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      Text(note.snippet)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text("Edited " + DateFormatter.noteAlarm.string(from: note.modified))
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .tag(note.id)
    .when(!reorderNotesMode) { view in
      view.simultaneousGesture(TapGesture().onEnded {
        guard editingNoteID != note.id else { return }
        controller.selectNote(note)
      })
    }
    // In Reorder mode the row accepts drops; drag is initiated from the ☰ handle
    // on the left so the user picks the row up only when they grab the handle.
    .when(reorderNotesMode) { view in
      view.dropDestination(for: String.self) { items, _ in
        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
        controller.dropNote(draggedID: id, onto: note, sectionID: sectionID)
        return true
      }
    }
    .contextMenu {
      Button {
        controller.togglePin(note)
      } label: {
        Label(note.isPinned ? "Unpin Note" : "Pin Note",
              systemImage: note.isPinned ? "pin.slash" : "pin")
      }
      Button { beginNoteRename(note) } label: { Label("Rename", systemImage: "pencil") }
      Button { reorderNotesMode.toggle() } label: {
        Label(reorderNotesMode ? "Done Reordering" : "Reorder Notes",
              systemImage: "arrow.up.arrow.down")
      }
      Button { controller.duplicate(note) } label: { Label("Duplicate Note", systemImage: "plus.square.on.square") }
      Menu {
        ForEach(NoteColor.allCases) { color in
          Button {
            controller.setColor(color, for: note)
          } label: {
            Label(color.displayName, systemImage: note.color == color ? "checkmark.circle.fill" : "circle")
          }
        }
      } label: { Label("Flag", systemImage: "flag") }
      Menu {
        let others = controller.folders.filter { $0.id != controller.selectedFolderID }
        if others.isEmpty {
          Text("No other folders")
        } else {
          ForEach(others) { folder in
            Button {
              controller.move(note, to: folder)
            } label: {
              Label(folder.name, systemImage: "folder")
            }
          }
        }
      } label: { Label("Move to", systemImage: "folder") }
      Divider()
      Button { controller.copyNoteToClipboard(note) } label: { Label("Copy Note", systemImage: "doc.on.clipboard") }
      Button { controller.shareNoteContent(note) } label: { Label("Share Note", systemImage: "square.and.arrow.up") }
      Button { reveal(note.directoryURL) } label: { Label("Show in Finder", systemImage: "folder") }
      Divider()
      Button(role: .destructive) { confirmDeleteNote(note) } label: { Label("Delete", systemImage: "trash") }
    }
  }

  // MARK: - Editor

  @ViewBuilder
  private var editor: some View {
    if let note = controller.selectedNote {
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Text("Created " + DateFormatter.noteAlarm.string(from: note.created)
               + "   ·   Edited " + DateFormatter.noteAlarm.string(from: note.modified))
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.top, 6)
        editorToolbar(note)
        Divider()
        RichTextEditor(noteID: note.id, text: controller.editorText, bridge: bridge)
      }
      // Force a full reconstruction of the editor (incl. NSTextView) whenever
      // the selected note changes. Without this, transient races between
      // selectNote and updateNSView could leave the old note's text in the view.
      .id(note.id)
      .sheet(isPresented: $showTableSheet) { tableSheet }
    } else {
      ContentUnavailableView("No Note Selected", systemImage: "note.text")
    }
  }

  private var tableSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Insert Table").font(.headline)
      HStack(spacing: 24) {
        Stepper("Rows: \(tableRows)", value: $tableRows, in: 1...20)
        Stepper("Columns: \(tableCols)", value: $tableCols, in: 1...10)
      }
      HStack {
        Spacer()
        Button("Cancel") { showTableSheet = false }
          .keyboardShortcut(.cancelAction)
        Button("Insert") {
          bridge.insertTable(rows: tableRows, cols: tableCols)
          showTableSheet = false
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 320)
  }

  private func editorToolbar(_ note: Note) -> some View {
    HStack(spacing: 10) {
      Group {
        toolButton("bold") { bridge.toggleBold() }
        toolButton("italic") { bridge.toggleItalic() }
        toolButton("underline") { bridge.toggleUnderline() }
      }
      Divider().frame(height: 16)
      Group {
        toolButton("textformat.size.smaller") {
          fontSize = max(8, fontSize - 1); bridge.setFontSize(fontSize)
        }
        Text("\(Int(fontSize))").font(.caption).monospacedDigit().frame(width: 20)
        toolButton("textformat.size.larger") {
          fontSize = min(72, fontSize + 1); bridge.setFontSize(fontSize)
        }
        InlineColorPicker { bridge.setTextColor($0) }
      }
      Divider().frame(height: 16)
      Group {
        toolButton("list.bullet") { bridge.insertBullet() }
        toolButton("checklist") { bridge.insertChecklist() }
        toolButton("tablecells") { showTableSheet = true }
        toolButton("link") { bridge.insertLink() }
        toolButton("photo") { bridge.insertImage() }
      }
      Divider().frame(height: 16)
      clearFormattingButton
      Spacer()
      flagMenu(note)
      AlarmButton(note: note)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func toolButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 22, height: 20)
    }
    .buttonStyle(.borderless)
  }

  // Eraser → popover with "Clear all" + per-attribute toggles.
  private var clearFormattingButton: some View {
    Button {
      showClearFormatting.toggle()
    } label: {
      Image(systemName: "eraser").frame(width: 22, height: 20)
    }
    .buttonStyle(.borderless)
    .help("Clear formatting")
    .popover(isPresented: $showClearFormatting, arrowEdge: .bottom) {
      clearFormattingPopover
    }
  }

  private var clearFormattingPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Clear formatting")
        .font(.headline)
      Text("Strip styles from the selection — or the whole note if nothing is selected. Useful for cleaning up pastes from blogs / Google Docs.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        bridge.clearAllFormatting()
        showClearFormatting = false
      } label: {
        Label("Clear all formatting", systemImage: "eraser.line.dashed")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.regular)
      .help("Reset everything to plain text (images stay)")

      HStack(spacing: 6) {
        VStack { Divider() }
        Text("or pick specific styles")
          .font(.caption2)
          .foregroundStyle(.secondary)
        VStack { Divider() }
      }

      // Pre-checked = present in selection. User may add/remove freely.
      Toggle("Background color (highlights)", isOn: $clearBackground)
      Toggle("Text color", isOn: $clearForeground)
      Toggle("Underline", isOn: $clearUnderline)
      Toggle("Strikethrough", isOn: $clearStrikethrough)
      Toggle("Bold / italic", isOn: $clearFontTraits)
      Toggle("Font family + size (reset to default)", isOn: $clearFontFamilyAndSize)
      Toggle("Links", isOn: $clearLinks)

      HStack {
        Spacer()
        Button("Cancel") { showClearFormatting = false }
          .keyboardShortcut(.cancelAction)
        Button("Clear selected") {
          bridge.clearFormatting(
            background: clearBackground,
            foreground: clearForeground,
            underline: clearUnderline,
            strikethrough: clearStrikethrough,
            fontTraits: clearFontTraits,
            fontFamilyAndSize: clearFontFamilyAndSize,
            links: clearLinks
          )
          showClearFormatting = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!anyToggleOn)
      }
    }
    .padding(16)
    .frame(width: 340)
    .onAppear {
      // Re-detect each open so toggles track the active selection.
      let present = bridge.detectStylesInSelection()
      clearBackground = present.background
      clearForeground = present.foreground
      clearUnderline = present.underline
      clearStrikethrough = present.strikethrough
      clearFontTraits = present.fontTraits
      clearFontFamilyAndSize = present.fontFamilyAndSize
      clearLinks = present.links
    }
  }

  private var anyToggleOn: Bool {
    clearBackground || clearForeground || clearUnderline || clearStrikethrough
      || clearFontTraits || clearFontFamilyAndSize || clearLinks
  }

  private func flagMenu(_ note: Note) -> some View {
    Menu {
      ForEach(NoteColor.allCases) { color in
        Button {
          controller.setColor(color, for: note)
        } label: {
          Label(color.displayName, systemImage: note.color == color ? "checkmark.circle.fill" : "circle")
        }
      }
    } label: {
      HStack(spacing: 4) {
        Circle().fill(note.color == .none ? Color.secondary.opacity(0.4) : note.color.color)
          .frame(width: 10, height: 10)
        Text("Flag").font(.caption)
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  // MARK: - Rename helpers

  private func beginFolderRename(_ folder: NoteFolder) {
    editingNoteID = nil
    editingText = folder.name
    editingFolderID = folder.id
    focusRenameSoon()
  }

  private func beginNoteRename(_ note: Note) {
    editingFolderID = nil
    editingText = note.title
    editingNoteID = note.id
    focusRenameSoon()
  }

  private func focusRenameSoon() {
    DispatchQueue.main.async { renameFocused = true }
  }

  private func commitActiveRename() {
    if let id = editingFolderID, let folder = controller.folders.first(where: { $0.id == id }) {
      controller.renameFolder(folder, to: editingText)
      editingFolderID = nil
    } else if let id = editingNoteID, let note = controller.notes.first(where: { $0.id == id }) {
      controller.renameNote(note, to: editingText)
      editingNoteID = nil
    }
  }

  // MARK: - Actions

  private func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func confirmDeleteFolder(_ folder: NoteFolder) {
    let count = NotesStore.noteCount(in: folder)
    if count > 0 {
      let alert = NSAlert()
      alert.messageText = "Delete “\(folder.name)”?"
      alert.informativeText = "This folder contains \(count) note\(count == 1 ? "" : "s"). "
        + "It will be moved to the Trash."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Delete")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    controller.deleteFolder(folder)
  }

  private func confirmDeleteNote(_ note: Note) {
    if NotesStore.noteHasContent(note) {
      let alert = NSAlert()
      alert.messageText = "Delete “\(note.title.isEmpty ? "Untitled" : note.title)”?"
      alert.informativeText = "This note has content. It will be moved to the Trash."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Delete")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    controller.deleteNote(note)
  }
}

// Conditional modifier helper.
extension View {
  @ViewBuilder
  func when<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
    if condition { transform(self) } else { self }
  }
}

// Minimal inline text-color picker: a small palette popover anchored right at the
// toolbar button (instead of the large system Colors panel).
struct InlineColorPicker: View {
  let onPick: (NSColor) -> Void
  @State private var show = false

  private let swatches: [NSColor] = [
    .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal,
    .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown, .systemGray,
    .black, .white
  ]

  var body: some View {
    Button { show.toggle() } label: {
      Image(systemName: "paintpalette")
        .frame(width: 22, height: 20)
    }
    .buttonStyle(.borderless)
    .help("Text color")
    .popover(isPresented: $show, arrowEdge: .bottom) {
      VStack(spacing: 10) {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 7), spacing: 8) {
          ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
            Circle()
              .fill(Color(nsColor: color))
              .frame(width: 20, height: 20)
              .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
              .onTapGesture { onPick(color); show = false }
          }
        }
        Divider()
        Button("Default") { onPick(.textColor); show = false }
          .font(.caption)
      }
      .padding(12)
      .frame(width: 232)
    }
  }
}

// Date is chosen from a visual calendar grid (unambiguous — no year-first text)
// and the time from a separate HH:MM field with steppers (easy to set). Both
// bind to the same date.
struct CalendarDatePicker: NSViewRepresentable {
  @Binding var date: Date

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .clockAndCalendar
    picker.datePickerElements = [.yearMonthDay]
    picker.locale = Locale(identifier: "en_GB")
    picker.dateValue = date
    picker.minDate = Date()
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.changed(_:))
    return picker
  }

  func updateNSView(_ nsView: NSDatePicker, context: Context) {
    context.coordinator.parent = self
    if nsView.dateValue != date { nsView.dateValue = date }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject {
    var parent: CalendarDatePicker
    init(_ parent: CalendarDatePicker) { self.parent = parent }
    @objc func changed(_ sender: NSDatePicker) { parent.date = sender.dateValue }
  }
}

struct TimeFieldPicker: NSViewRepresentable {
  @Binding var date: Date

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerElements = [.hourMinute]
    picker.locale = Locale(identifier: "en_GB")
    picker.dateValue = date
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.changed(_:))
    return picker
  }

  func updateNSView(_ nsView: NSDatePicker, context: Context) {
    context.coordinator.parent = self
    if nsView.dateValue != date { nsView.dateValue = date }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject {
    var parent: TimeFieldPicker
    init(_ parent: TimeFieldPicker) { self.parent = parent }
    @objc func changed(_ sender: NSDatePicker) { parent.date = sender.dateValue }
  }
}

// Bell button + popover to manage a note's alarms.
struct AlarmButton: View {
  let note: Note
  @State private var showPopover = false
  @State private var newDate = Date().addingTimeInterval(3600)
  @State private var newTitle = ""

  private var controller: NotesController { .shared }

  private var hasPastAlarms: Bool { note.alarms.contains { !$0.isPending } }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      Image(systemName: note.hasPendingAlarm ? "bell.fill" : "bell")
        .foregroundStyle(note.hasPendingAlarm ? .orange : .primary)
    }
    .buttonStyle(.borderless)
    .help("Alarms")
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      alarmPopover
        .frame(width: 320)
        .padding(14)
    }
  }

  private var alarmPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Alarms").font(.headline)
        Spacer()
        if hasPastAlarms {
          Button("Clear Past") { controller.clearPastAlarms(from: note) }
            .font(.caption)
        }
      }

      if note.alarms.isEmpty {
        Text("No alarms set.").font(.subheadline).foregroundStyle(.secondary)
      } else {
        ForEach(note.alarms.sorted { $0.date < $1.date }) { alarm in
          HStack {
            Image(systemName: alarm.isPending ? "bell.fill" : "bell.slash")
              .foregroundStyle(alarm.isPending ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text(DateFormatter.noteAlarm.string(from: alarm.date))
                .font(.subheadline)
                .foregroundStyle(alarm.isPending ? .primary : .secondary)
              if !alarm.title.isEmpty {
                Text(alarm.title).font(.caption).foregroundStyle(.secondary)
              }
              if !alarm.isPending {
                Text("Past").font(.caption2).foregroundStyle(.tertiary)
              }
            }
            Spacer()
            Button {
              controller.removeAlarm(alarm, from: note)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Remind at").font(.subheadline)
        CalendarDatePicker(date: $newDate)
          .fixedSize()
        HStack(spacing: 8) {
          Text("Time").font(.subheadline)
          TimeFieldPicker(date: $newDate)
            .fixedSize()
        }
        Text(DateFormatter.noteAlarm.string(from: newDate))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      TextField("Label (optional)", text: $newTitle)
        .textFieldStyle(.roundedBorder)
      Button {
        controller.addAlarm(newDate, title: newTitle, to: note)
        newTitle = ""
        newDate = Date().addingTimeInterval(3600)
      } label: {
        Label("Add Alarm", systemImage: "plus")
      }
      .disabled(newDate <= Date())
    }
  }
}
