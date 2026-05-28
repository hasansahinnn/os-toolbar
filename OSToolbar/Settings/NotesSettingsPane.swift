import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings
import SwiftUI

struct NotesSettingsPane: View {
  @State private var saveDirectory = NotesStore.rootDisplayPath

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(label: { Text("Open Notes shortcut") }) {
        KeyboardShortcuts.Recorder(for: .openNotes)
          .help("Open the Notes window.")
      }

      Settings.Section(bottomDivider: true, label: { Text("Startup") }) {
        LaunchAtLogin.Toggle {
          Text("Launch at login")
        }
      }

      Settings.Section(bottomDivider: true, label: { Text("Notes folder") }) {
        VStack(alignment: .leading, spacing: 6) {
          Text(saveDirectory)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
          HStack {
            Button("Choose Folder…") {
              NotesStore.chooseDirectory()
              saveDirectory = NotesStore.rootDisplayPath
              NotesController.shared.loadFolders()
            }
            Button("Open Folder") {
              NotesStore.openInFinder()
            }
          }
        }
        .frame(width: 320, alignment: .leading)
      }

      Settings.Section(label: { Text("Notes are saved as files") }) {
        Text("Each folder is a real directory and each note is stored on disk "
             + "(rich text + metadata). No database is used.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 320, alignment: .leading)
      }
    }
  }
}

#Preview {
  NotesSettingsPane()
}
