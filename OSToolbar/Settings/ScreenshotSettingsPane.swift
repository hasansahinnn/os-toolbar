import Defaults
import KeyboardShortcuts
import Settings
import SwiftHEXColors
import SwiftUI

struct ScreenshotSettingsPane: View {
  @Default(.screenshotColorHex) private var colorHex
  @Default(.screenshotLineWidth) private var lineWidth
  @Default(.screenshotFontSize) private var fontSize

  @State private var saveDirectory = ScreenshotPreferences.saveDirectoryDisplayPath

  private var colorBinding: Binding<Color> {
    Binding(
      get: { Color(nsColor: NSColor(hexString: colorHex) ?? .systemRed) },
      set: { colorHex = NSColor($0).hexString }
    )
  }

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(label: { Text("Region shortcut") }) {
        KeyboardShortcuts.Recorder(for: .screenshot)
          .help("Select a region, annotate, then copy or save.")
      }

      Settings.Section(label: { Text("Quick full screen") }) {
        KeyboardShortcuts.Recorder(for: .quickScreenshot)
          .help("Instantly capture the whole screen and save it to the folder below.")
      }

      Settings.Section(label: { Text("Open folder") }) {
        KeyboardShortcuts.Recorder(for: .openScreenshotFolder)
          .help("Open the screenshot folder in Finder.")
      }

      Settings.Section(bottomDivider: true, label: { Text("") }) {
        Defaults.Toggle(key: .screenshotOpenFolderAfterCapture) {
          Text("Open folder after a quick screenshot")
        }
        Button {
          takeScreenshot()
        } label: {
          Label("Take Screenshot", systemImage: "camera.viewfinder")
        }
      }

      Settings.Section(bottomDivider: true, label: { Text("Save folder") }) {
        VStack(alignment: .leading, spacing: 6) {
          Text(saveDirectory)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
          HStack {
            Button("Choose Folder…") {
              ScreenshotPreferences.chooseDirectory()
              saveDirectory = ScreenshotPreferences.saveDirectoryDisplayPath
            }
            Button("Open Folder") {
              ScreenshotPreferences.openInFinder()
            }
          }
        }
        .frame(width: 320, alignment: .leading)
      }

      Settings.Section(label: { Text("Color") }) {
        ColorPicker("", selection: colorBinding)
          .labelsHidden()
      }

      Settings.Section(label: { Text("Line width") }) {
        HStack {
          Slider(value: $lineWidth, in: 1...24)
            .frame(width: 200)
          Text("\(Int(lineWidth)) px")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }

      Settings.Section(label: { Text("Text size") }) {
        HStack {
          Slider(value: $fontSize, in: 8...72)
            .frame(width: 200)
          Text("\(Int(fontSize)) pt")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func takeScreenshot() {
    let window = NSApp.keyWindow
    window?.orderOut(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      ScreenshotController.shared.capture()
    }
  }
}

#Preview {
  ScreenshotSettingsPane()
}
