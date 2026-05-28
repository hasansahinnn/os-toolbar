import AppKit
import SwiftUI

extension DateFormatter {
  static let noteAlarm: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd-MM-yyyy HH:mm"
    return formatter
  }()
}

struct NotesRootView: View {
  @Bindable private var controller = NotesController.shared
  @State private var bridge = NoteEditorBridge()
  @State private var fontSize: CGFloat = 14
  @State private var showTableSheet = false
  @State private var tableRows = 2
  @State private var tableCols = 2

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
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
    } content: {
      notesList
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
    } detail: {
      editor
    }
    .frame(minWidth: 900, minHeight: 560)
    .onAppear { controller.loadFolders() }
  }

  // MARK: - Sidebar (folders)

  private var sidebar: some View {
    List(selection: folderSelection) {
      if !controller.activeAlarms.isEmpty {
        Section("Alarms") {
          ForEach(controller.activeAlarms) { row in
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
                }
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }

      Section("Folders") {
        ForEach(controller.folders) { folder in
          Label(folder.name, systemImage: "folder")
            .tag(folder.id)
            .contextMenu {
              Button("New Note") {
                controller.selectFolder(folder)
                controller.newNote()
              }
              Button("Rename") { promptRenameFolder(folder) }
              Button("Show in Finder") { reveal(folder.url) }
              Divider()
              Button("Delete", role: .destructive) { confirmDeleteFolder(folder) }
            }
        }
      }
    }
    .listStyle(.sidebar)
    .toolbar {
      ToolbarItem {
        Button { controller.newFolder() } label: {
          Image(systemName: "folder.badge.plus")
        }
        .help("New Folder")
      }
    }
  }

  // MARK: - Notes list

  private var notesList: some View {
    List(selection: noteSelection) {
      ForEach(controller.sections) { section in
        if let title = section.title {
          Section {
            if !controller.isCollapsed(section.id) {
              ForEach(section.notes) { noteRow($0) }
            }
          } header: {
            groupHeader(section, title: title)
          }
        } else {
          ForEach(section.notes) { noteRow($0) }
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

  private func noteRow(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        if note.color != .none {
          Circle().fill(note.color.color).frame(width: 9, height: 9)
        }
        Text(note.title.isEmpty ? "Untitled" : note.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
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
      Text(DateFormatter.noteAlarm.string(from: note.modified))
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 2)
    .tag(note.id)
    .contextMenu {
      Menu("Color") {
        ForEach(NoteColor.allCases) { color in
          Button {
            controller.setColor(color, for: note)
          } label: {
            Label(color.displayName, systemImage: note.color == color ? "checkmark" : "circle")
          }
        }
      }
      Button("Show in Finder") { reveal(note.directoryURL) }
      Divider()
      Button("Delete", role: .destructive) { confirmDeleteNote(note) }
    }
  }

  // MARK: - Editor

  @ViewBuilder
  private var editor: some View {
    if let note = controller.selectedNote {
      VStack(spacing: 0) {
        editorToolbar(note)
        Divider()
        RichTextEditor(noteID: note.id, text: controller.editorText, bridge: bridge)
      }
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
        textColorMenu
      }
      Divider().frame(height: 16)
      Group {
        toolButton("list.bullet") { bridge.insertBullet() }
        toolButton("checklist") { bridge.insertChecklist() }
        toolButton("tablecells") { showTableSheet = true }
        toolButton("link") { bridge.insertLink() }
        toolButton("photo") { bridge.insertImage() }
      }
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

  private var textColorMenu: some View {
    Menu {
      ForEach(NoteColor.allCases.filter { $0 != .none }) { color in
        Button(color.displayName) { bridge.setTextColor(NSColor(color.color)) }
      }
      Button("Default") { bridge.setTextColor(.textColor) }
    } label: {
      Image(systemName: "paintpalette")
    }
    .menuStyle(.borderlessButton)
    .frame(width: 40)
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

  // MARK: - Actions

  private func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func promptRenameFolder(_ folder: NoteFolder) {
    let alert = NSAlert()
    alert.messageText = "Rename Folder"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = folder.name
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    controller.renameFolder(folder, to: field.stringValue)
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
        .environment(\.locale, Locale(identifier: "en_GB"))
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
