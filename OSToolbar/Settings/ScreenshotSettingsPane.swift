import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings
import SwiftHEXColors
import SwiftUI

struct ScreenshotSettingsPane: View {
  @Default(.screenshotColorHex) private var colorHex
  @Default(.screenshotLineWidth) private var lineWidth
  @Default(.screenshotFontSize) private var fontSize
  @Default(.screenshotFormat) private var formatRaw
  @Default(.screenshotQuality) private var quality

  @State private var saveDirectory = ScreenshotPreferences.saveDirectoryDisplayPath

  private var colorBinding: Binding<Color> {
    Binding(
      get: { Color(nsColor: NSColor(hexString: colorHex) ?? .systemRed) },
      set: { colorHex = NSColor($0).hexString }
    )
  }

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(bottomDivider: true, label: { Text("Startup") }) {
        LaunchAtLogin.Toggle {
          Text("Launch at login")
        }
        Defaults.Toggle(key: .screenshotEnabled) {
          Text("Enable screenshot")
        }
        .help("When off, the screenshot shortcuts and menu actions are disabled.")
      }

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

      Settings.Section(label: { Text("Format") }) {
        Picker("", selection: $formatRaw) {
          ForEach(ScreenshotFormat.allCases) { format in
            Text(format.displayName).tag(format.rawValue)
          }
        }
        .labelsHidden()
        .frame(width: 320, alignment: .leading)
      }

      Settings.Section(label: { Text("Quality") }) {
        HStack {
          Slider(value: $quality, in: 0.5...1.0)
            .frame(width: 200)
            .disabled(formatRaw == "png")
          Text("\(Int(quality * 100))%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .help("JPEG only — PNG is always lossless.")
      }

      Settings.Section(bottomDivider: true, label: { Text("Resolution") }) {
        Defaults.Toggle(key: .screenshotRetina) {
          Text("Save at full Retina (2×)")
        }
        .help("Off = 1× output: a quarter of the pixels and roughly a quarter of the file size, still sharp on screen.")
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
