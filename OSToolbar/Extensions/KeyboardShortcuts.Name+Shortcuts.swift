import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let popup = Self("popup", default: Shortcut(.c, modifiers: [.command, .shift]))
  static let pin = Self("pin", default: Shortcut(.p, modifiers: [.option]))
  static let delete = Self("delete", default: Shortcut(.delete, modifiers: [.option]))
  static let togglePreview = Self("togglePreview", default: Shortcut(.space, modifiers: [.control]))
  static let screenshot = Self("screenshot", default: Shortcut(.s, modifiers: [.command, .shift]))
  static let quickScreenshot = Self("quickScreenshot", default: Shortcut(.a, modifiers: [.command, .shift]))
  static let openScreenshotFolder = Self("openScreenshotFolder", default: Shortcut(.f, modifiers: [.command, .shift]))
  static let openNotes = Self("openNotes", default: Shortcut(.n, modifiers: [.command, .shift]))
}
