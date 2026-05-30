import AppKit
import SwiftUI

// Marker glyphs used for list continuation / checkbox toggling.
private enum ListMarker {
  static let uncheckedBox = "○ "
  static let checkedBox = "● "
  static let bullet = "•\t"
  static let all = [uncheckedBox, checkedBox, bullet]
}

// Bridge that lets the SwiftUI toolbar drive the underlying NSTextView
// (formatting commands operate on the current selection / typing attributes).
@MainActor
final class NoteEditorBridge {
  weak var textView: NSTextView?

  private var fontManager: NSFontManager { .shared }

  func toggleBold() { applyTrait(.boldFontMask) }
  func toggleItalic() { applyTrait(.italicFontMask) }

  func toggleUnderline() {
    guard let tv = textView else { return }
    tv.underline(nil)
    notifyChange()
  }

  private func applyTrait(_ trait: NSFontTraitMask) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let range = tv.selectedRange()
    if range.length == 0 {
      let current = (tv.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
      let has = fontManager.traits(of: current).contains(trait)
      tv.typingAttributes[.font] = has
        ? fontManager.convert(current, toNotHaveTrait: trait)
        : fontManager.convert(current, toHaveTrait: trait)
      return
    }
    storage.beginEditing()
    storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
      let current = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
      let toggled: NSFont
      if self.fontManager.traits(of: current).contains(trait) {
        toggled = self.fontManager.convert(current, toNotHaveTrait: trait)
      } else {
        toggled = self.fontManager.convert(current, toHaveTrait: trait)
      }
      storage.addAttribute(.font, value: toggled, range: subRange)
    }
    storage.endEditing()
    notifyChange()
  }

  func setFontSize(_ size: CGFloat) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let range = tv.selectedRange()
    if range.length == 0 {
      let current = (tv.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
      tv.typingAttributes[.font] = fontManager.convert(current, toSize: size)
      return
    }
    storage.beginEditing()
    storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
      let current = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
      storage.addAttribute(.font, value: self.fontManager.convert(current, toSize: size), range: subRange)
    }
    storage.endEditing()
    notifyChange()
  }

  func setTextColor(_ color: NSColor) {
    guard let tv = textView else { return }
    let range = tv.selectedRange()
    if range.length == 0 {
      tv.typingAttributes[.foregroundColor] = color
      return
    }
    tv.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
    notifyChange()
  }

  func insertBullet() { insertLinePrefix(ListMarker.bullet) }
  func insertChecklist() { insertLinePrefix(ListMarker.uncheckedBox) }

  private func insertLinePrefix(_ prefix: String) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let text = storage.string as NSString
    let lineRange = text.lineRange(for: tv.selectedRange())
    let insertion = NSAttributedString(string: prefix, attributes: tv.typingAttributes)
    storage.insert(insertion, at: lineRange.location)
    notifyChange()
  }

  func insertLink() {
    guard let tv = textView else { return }
    let range = tv.selectedRange()
    guard range.length > 0 else { return }
    let alert = NSAlert()
    alert.messageText = "Add Link"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.placeholderString = "https://example.com"
    alert.accessoryView = field
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    var urlString = field.stringValue.trimmingCharacters(in: .whitespaces)
    guard !urlString.isEmpty else { return }
    if !urlString.contains("://") { urlString = "https://" + urlString }
    guard let url = URL(string: urlString) else { return }
    tv.textStorage?.addAttribute(.link, value: url, range: range)
    notifyChange()
  }

  func insertImage() {
    guard let tv = textView else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
    guard let attachment = NotesStore.makeImageAttachment(image: image) else { return }
    let attrString = NSAttributedString(attachment: attachment)
    tv.textStorage?.replaceCharacters(in: tv.selectedRange(), with: attrString)
    notifyChange()
  }

  func insertTable(rows: Int, cols: Int) {
    guard let tv = textView, let storage = tv.textStorage, rows > 0, cols > 0 else { return }

    let table = NSTextTable()
    table.numberOfColumns = cols
    table.collapsesBorders = true

    let result = NSMutableAttributedString()
    for row in 0..<rows {
      for col in 0..<cols {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: col, columnSpan: 1)
        block.setBorderColor(.separatorColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        let cell = NSMutableAttributedString(
          string: " \n",
          attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        )
        result.append(cell)
      }
    }
    // A plain paragraph (no text block) after the table so the cursor can leave
    // the table and type below it.
    result.append(NSAttributedString(
      string: "\n",
      attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: NSParagraphStyle.default
      ]
    ))
    storage.replaceCharacters(in: tv.selectedRange(), with: result)
    notifyChange()
  }

  private func notifyChange() {
    guard let tv = textView else { return }
    NotesController.shared.editorContentChanged(tv.attributedString())
  }
}

// NSTextView subclass that gives lists/checklists macOS-Notes-like behaviour:
// pressing Return continues the list, and clicking a checkbox glyph toggles it.
// Clicking an image opens it at full size.
final class ListTextView: NSTextView {
  // Max on-screen width for inline images so a pasted/large image doesn't overflow
  // the editor. The full-resolution data is kept; click an image to view full size.
  static let maxImageWidth: CGFloat = 340

  override func paste(_ sender: Any?) {
    super.paste(sender)
    capImages()
  }

  override func pasteAsRichText(_ sender: Any?) {
    super.pasteAsRichText(sender)
    capImages()
  }

  // Shrinks any oversized image attachments to maxImageWidth (keeping aspect),
  // then reflows. Safe to call after paste/drag and after loading a note.
  func capImages() {
    guard let storage = textStorage, storage.length > 0 else { return }
    var changed = false
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      let image = attachment.image
        ?? attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
      guard let image, image.size.width > 0 else { return }
      let width = attachment.bounds.width
      if width <= 0 || width > Self.maxImageWidth {
        let scale = min(Self.maxImageWidth / image.size.width, 1)
        attachment.bounds = CGRect(
          x: 0, y: 0,
          width: (image.size.width * scale).rounded(),
          height: (image.size.height * scale).rounded()
        )
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        changed = true
      }
    }
    if changed { needsDisplay = true }
  }

  override func insertNewline(_ sender: Any?) {
    let nsText = string as NSString
    let lineRange = nsText.lineRange(for: selectedRange())
    let lineText = nsText.substring(with: lineRange)

    for marker in ListMarker.all where lineText.hasPrefix(marker) {
      let body = String(lineText.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      if body.isEmpty {
        // Empty list item → remove the marker and break out of the list.
        let removeRange = NSRange(location: lineRange.location, length: min(marker.count, lineRange.length))
        if shouldChangeText(in: removeRange, replacementString: "") {
          textStorage?.replaceCharacters(in: removeRange, with: "")
          didChangeText()
        }
        super.insertNewline(sender)
        return
      }
      super.insertNewline(sender)
      // A new checklist item is always unchecked.
      let nextMarker = (marker == ListMarker.checkedBox) ? ListMarker.uncheckedBox : marker
      insertText(nextMarker, replacementRange: selectedRange())
      return
    }
    super.insertNewline(sender)
  }

  override func mouseDown(with event: NSEvent) {
    guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else {
      super.mouseDown(with: event)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let origin = textContainerOrigin
    let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
    let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

    if charIndex < storage.length {
      let ns = storage.string as NSString
      let ch = ns.substring(with: NSRange(location: charIndex, length: 1))
      if ch == "○" || ch == "●" {
        toggleCheckbox(at: charIndex, current: ch)
        return
      }
    }
    // Images are NOT opened on click (that interfered with placing the cursor) —
    // a preview button appears on hover instead (see updateImageHover).
    super.mouseDown(with: event)
  }

  // MARK: - Image hover preview

  private var imageHoverButton: NSButton?
  private var hoveredAttachment: NSTextAttachment?
  private var imageTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area = imageTrackingArea { removeTrackingArea(area) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    imageTrackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateImageHover(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hideImageHover()
  }

  func hideImageHover() {
    imageHoverButton?.isHidden = true
    hoveredAttachment = nil
  }

  private func updateImageHover(at point: NSPoint) {
    guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else {
      hideImageHover()
      return
    }
    let origin = textContainerOrigin
    let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
    let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    guard charIndex < storage.length,
          let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment else {
      hideImageHover()
      return
    }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    rect.origin.x += origin.x
    rect.origin.y += origin.y

    hoveredAttachment = attachment
    let button = ensureHoverButton()
    let size: CGFloat = 30
    // Top-left of the image (the top-right has the image's own selection handle).
    button.frame = NSRect(x: rect.minX + 8, y: rect.minY + 8, width: size, height: size)
    button.isHidden = false
  }

  private func ensureHoverButton() -> NSButton {
    if let button = imageHoverButton { return button }
    let button = NSButton(frame: .zero)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                           accessibilityDescription: "Preview full size")
    button.imagePosition = .imageOnly
    button.contentTintColor = .white
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    button.layer?.cornerRadius = 8
    button.layer?.borderWidth = 1
    button.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
    button.target = self
    button.action = #selector(openHoveredImage)
    button.toolTip = "Preview full size"
    addSubview(button)
    imageHoverButton = button
    return button
  }

  @objc private func openHoveredImage() {
    guard let attachment = hoveredAttachment else { return }
    ImagePreviewWindow.show(attachment: attachment)
  }

  private func toggleCheckbox(at index: Int, current: String) {
    let toggled = current == "○" ? "●" : "○"
    let range = NSRange(location: index, length: 1)
    guard shouldChangeText(in: range, replacementString: toggled) else { return }
    textStorage?.replaceCharacters(in: range, with: toggled)
    // Strike through the rest of the line when checked, restore when unchecked.
    let ns = string as NSString
    let line = ns.lineRange(for: range)
    let textStart = index + 1
    if textStart < NSMaxRange(line) {
      let textRange = NSRange(location: textStart, length: NSMaxRange(line) - textStart)
      let style: NSNumber = toggled == "●" ? NSNumber(value: NSUnderlineStyle.single.rawValue) : NSNumber(value: 0)
      textStorage?.addAttribute(.strikethroughStyle, value: style, range: textRange)
    }
    didChangeText()
  }
}

// SwiftUI wrapper around a rich-text NSTextView. Loads `text` when `noteID`
// changes (note switch) and reports edits back through the controller.
struct RichTextEditor: NSViewRepresentable {
  var noteID: Note.ID?
  var text: NSAttributedString
  let bridge: NoteEditorBridge

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false

    let contentSize = scrollView.contentSize
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let container = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layoutManager.addTextContainer(container)

    let textView = ListTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.isRichText = true
    textView.importsGraphics = true
    textView.allowsImageEditing = true
    textView.isAutomaticLinkDetectionEnabled = true
    textView.isAutomaticDataDetectionEnabled = true
    textView.usesFindBar = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: 14)
    textView.textContainerInset = NSSize(width: 8, height: 12)
    textView.delegate = context.coordinator
    textView.typingAttributes = [
      .font: NSFont.systemFont(ofSize: 14),
      .foregroundColor: NSColor.textColor
    ]

    scrollView.documentView = textView
    context.coordinator.textView = textView
    bridge.textView = textView

    textView.textStorage?.setAttributedString(text)
    textView.capImages()
    context.coordinator.loadedNoteID = noteID

    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    bridge.textView = textView
    // Only reload content on a real note switch — never on every keystroke.
    if context.coordinator.loadedNoteID != noteID {
      textView.textStorage?.setAttributedString(text)
      (textView as? ListTextView)?.capImages()
      textView.setSelectedRange(NSRange(location: 0, length: 0))
      context.coordinator.loadedNoteID = noteID
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    weak var textView: NSTextView?
    var loadedNoteID: Note.ID?
    // Dedicated undo manager per coordinator (so it dies with the SwiftUI view
    // when `.id(note.id)` recreates it). Otherwise the window's shared undo
    // manager keeps stale targets after the old NSTextView is deallocated and
    // Cmd+Z crashes with EXC_BAD_ACCESS in NSUndoStack popAndInvoke.
    let editorUndoManager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      // Capture the note the text view currently shows so the controller can
      // refuse the change if the selection has moved on (otherwise the old
      // note's text would be written into the newly-selected note).
      let expected = loadedNoteID
      MainActor.assumeIsolated {
        NotesController.shared.editorContentChanged(textView.attributedString(), expectedNoteID: expected)
      }
    }
  }
}

// Simple window that shows an attachment's image at (capped) full size.
@MainActor
enum ImagePreviewWindow {
  private static var window: NSWindow?

  static func show(attachment: NSTextAttachment) {
    guard let image = imageFromAttachment(attachment) else { return }
    let maxSize = (NSScreen.main?.visibleFrame.size).map { NSSize(width: $0.width * 0.8, height: $0.height * 0.8) }
      ?? NSSize(width: 1000, height: 800)
    var size = image.size
    let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
    size = NSSize(width: size.width * scale, height: size.height * scale)

    let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown

    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                       styleMask: [.titled, .closable, .resizable],
                       backing: .buffered, defer: false)
    win.title = "Image"
    win.contentView = imageView
    win.center()
    win.isReleasedWhenClosed = false
    win.level = .floating
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
    win.orderFrontRegardless()
    window = win
  }

  private static func imageFromAttachment(_ attachment: NSTextAttachment) -> NSImage? {
    if let image = attachment.image { return image }
    if let contents = attachment.fileWrapper?.regularFileContents {
      return NSImage(data: contents)
    }
    return nil
  }
}
