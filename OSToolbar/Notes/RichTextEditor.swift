import AppKit
import SwiftUI

// Original (natural-size) image bytes stashed on every image attachment so
// resize always computes from the natural size, not the currently-displayed one.
extension NSAttributedString.Key {
  static let osToolbarNaturalImageData = NSAttributedString.Key("OSToolbarNaturalImageData")
}

/// NSTextAttachmentCell that actually honours `attachment.bounds` for sizing
/// (the default cell ignores bounds and draws at the image's natural size).
final class ScalingAttachmentCell: NSTextAttachmentCell {
  override func cellSize() -> NSSize {
    if let attachment, attachment.bounds.width > 0 {
      return attachment.bounds.size
    }
    return image?.size ?? .zero
  }

  override func cellFrame(
    for textContainer: NSTextContainer,
    proposedLineFragment lineFrag: NSRect,
    glyphPosition position: NSPoint,
    characterIndex charIndex: Int
  ) -> NSRect {
    if let attachment, attachment.bounds.width > 0 {
      return NSRect(origin: .zero, size: attachment.bounds.size)
    }
    return super.cellFrame(
      for: textContainer,
      proposedLineFragment: lineFrag,
      glyphPosition: position,
      characterIndex: charIndex
    )
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    guard let img = image
            ?? attachment?.fileWrapper?.regularFileContents.flatMap({ NSImage(data: $0) }) else { return }
    // Text views render in flipped coordinates. The plain `draw(in:)` overload
    // doesn't honour the flip, so images came out upside-down. The
    // `respectFlipped: true` overload tells NSImage to compensate.
    img.draw(
      in: cellFrame,
      from: .zero,
      operation: .copy,
      fraction: 1,
      respectFlipped: true,
      hints: nil
    )
  }

  override func draw(
    withFrame cellFrame: NSRect,
    in controlView: NSView?,
    characterIndex charIndex: Int,
    layoutManager: NSLayoutManager
  ) {
    draw(withFrame: cellFrame, in: controlView)
  }
}

// Marker glyphs for list continuation / checkbox toggling.
private enum ListMarker {
  static let uncheckedBox = "○ "
  static let checkedBox = "● "
  static let bullet = "•\t"
  static let all = [uncheckedBox, checkedBox, bullet]
}

/// Bridge from the SwiftUI editor toolbar to the underlying NSTextView.
/// Owns all imperative formatting commands (bold, font size, insert link/image,
/// table, clear formatting), called by toolbar button actions.
@MainActor
final class NoteEditorBridge {
  weak var textView: NSTextView?

  private var fontManager: NSFontManager { .shared }

  /// Toggles bold on the selection (or typing attributes if none).
  func toggleBold() { applyTrait(.boldFontMask) }
  /// Toggles italic on the selection (or typing attributes if none).
  func toggleItalic() { applyTrait(.italicFontMask) }

  /// Toggles underline on the selection.
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

  /// Sets the font size (in points) on the selection.
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

  /// Sets foreground colour on the selection.
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

  /// Prepends a bullet marker to the current line.
  func insertBullet() { insertLinePrefix(ListMarker.bullet) }
  /// Prepends an unchecked checkbox marker to the current line.
  func insertChecklist() { insertLinePrefix(ListMarker.uncheckedBox) }

  private func insertLinePrefix(_ prefix: String) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let text = storage.string as NSString
    let lineRange = text.lineRange(for: tv.selectedRange())
    let insertion = NSAttributedString(string: prefix, attributes: tv.typingAttributes)
    storage.insert(insertion, at: lineRange.location)
    notifyChange()
  }

  /// Wraps the current selection in a link (prompts the user for the URL).
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

  /// Opens NSOpenPanel for an image file and inserts it as an attachment.
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

  /// Inserts an NSTextTable with the given dimensions at the caret.
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

  // Drives the Clear-formatting popover's toggle defaults.
  struct StylesPresent {
    var background = false
    var foreground = false
    var underline = false
    var strikethrough = false
    var fontTraits = false       // bold or italic
    var fontFamilyAndSize = false  // non-default family or size
    var links = false
  }

  /// Scans the current selection (or whole note) and returns which formatting
  /// attributes are actually present. Drives the Clear-formatting popover's defaults.
  func detectStylesInSelection() -> StylesPresent {
    var present = StylesPresent()
    guard let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return present }
    var range = tv.selectedRange()
    if range.length == 0 {
      range = NSRange(location: 0, length: storage.length)
    }
    let defaultFamily = NSFont.systemFont(ofSize: 14).familyName
    storage.enumerateAttributes(in: range, options: []) { attrs, _, _ in
      if attrs[.backgroundColor] != nil { present.background = true }
      if let color = attrs[.foregroundColor] as? NSColor,
         color != .textColor, color != .labelColor {
        present.foreground = true
      }
      if let underline = attrs[.underlineStyle] as? Int, underline != 0 { present.underline = true }
      if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { present.strikethrough = true }
      if let font = attrs[.font] as? NSFont {
        let traits = NSFontManager.shared.traits(of: font)
        if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
          present.fontTraits = true
        }
        if font.familyName != defaultFamily || abs(font.pointSize - 14) > 0.1 {
          present.fontFamilyAndSize = true
        }
      }
      if attrs[.link] != nil { present.links = true }
    }
    return present
  }

  /// Resets every attribute on the selection to defaults; images survive.
  func clearAllFormatting() {
    guard let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return }
    var range = tv.selectedRange()
    if range.length == 0 {
      range = NSRange(location: 0, length: storage.length)
    }
    let defaultAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14),
      .foregroundColor: NSColor.textColor
    ]
    storage.beginEditing()
    storage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
      var newAttrs = defaultAttrs
      if let attachment = attrs[.attachment] {
        newAttrs[.attachment] = attachment  // keep images
      }
      storage.setAttributes(newAttrs, range: subRange)
    }
    storage.endEditing()
    notifyChange()
  }

  /// Strips only the flagged attributes from the selection (whole note if none).
  func clearFormatting(
    background: Bool,
    foreground: Bool,
    underline: Bool,
    strikethrough: Bool,
    fontTraits: Bool,
    fontFamilyAndSize: Bool,
    links: Bool
  ) {
    guard let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return }
    var range = tv.selectedRange()
    if range.length == 0 {
      range = NSRange(location: 0, length: storage.length)
    }

    storage.beginEditing()
    if background { storage.removeAttribute(.backgroundColor, range: range) }
    if underline { storage.removeAttribute(.underlineStyle, range: range) }
    if strikethrough { storage.removeAttribute(.strikethroughStyle, range: range) }
    if links { storage.removeAttribute(.link, range: range) }
    if foreground {
      storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
    }
    if fontTraits || fontFamilyAndSize {
      storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
        let current = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
        var result: NSFont = fontFamilyAndSize ? NSFont.systemFont(ofSize: 14) : current
        if fontTraits {
          let traits = NSFontManager.shared.traits(of: result)
          result = NSFontManager.shared.convert(result, toNotHaveTrait: traits)
        }
        storage.addAttribute(.font, value: result, range: subRange)
      }
    }
    storage.endEditing()
    notifyChange()
  }

  private func notifyChange() {
    guard let tv = textView else { return }
    NotesController.shared.editorContentChanged(tv.attributedString())
  }
}

/// NSTextView subclass with macOS-Notes-like list continuation, click-to-toggle
/// checkboxes, click-on-image options popover, hover preview button, and a
/// custom paste path that synchronously decodes RTFD/HTML so images appear
/// on the first paste (no broken-image placeholder dance).
final class ListTextView: NSTextView {
  // Max display width for inline images; capped to the container.
  static let maxImageWidthFallback: CGFloat = 280

  private var effectiveImageMaxWidth: CGFloat {
    let containerWidth = textContainer?.size.width ?? Self.maxImageWidthFallback
    let padded = max(120, containerWidth - 24)
    return min(Self.maxImageWidthFallback, padded)
  }

  override func paste(_ sender: Any?) {
    if handleRichTextPaste() { return }
    super.paste(sender)
    schedulePostPasteCapImages()
  }

  override func pasteAsRichText(_ sender: Any?) {
    if handleRichTextPaste() { return }
    super.pasteAsRichText(sender)
    schedulePostPasteCapImages()
  }

  // Synchronous rich-text paste. Bypasses super.paste's deferred image decode
  // (caused broken-image placeholders on the first web paste). Returns true if
  // it handled the pasteboard; false to let super.paste deal with non-rich data.
  private func handleRichTextPaste() -> Bool {
    guard let storage = textStorage else { return false }
    let pb = NSPasteboard.general

    var attributed: NSAttributedString?
    if let data = pb.data(forType: .rtfd) {
      attributed = NSAttributedString(rtfd: data, documentAttributes: nil)
    }
    if attributed == nil, let data = pb.data(forType: .html) {
      attributed = NSAttributedString(html: data, documentAttributes: nil)
    }
    if attributed == nil, let data = pb.data(forType: .rtf) {
      attributed = NSAttributedString(rtf: data, documentAttributes: nil)
    }
    guard let toInsert = attributed, toInsert.length > 0 else { return false }

    let range = selectedRange()
    guard shouldChangeText(in: range, replacementString: toInsert.string) else { return false }
    storage.replaceCharacters(in: range, with: toInsert)
    didChangeText()
    schedulePostPasteCapImages()
    return true
  }

  // Retry schedule for HTML-paste image attachments that resolve asynchronously
  // (sometimes 500ms+ after super.paste returns).
  private func schedulePostPasteCapImages() {
    capImages()
    for delay in [0.05, 0.2, 0.5, 1.0, 2.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.capImages()
      }
    }
  }

  // Natural-size image bytes for the attachment at `charIndex`. Tries every
  // place NSTextAttachment can stash an image: custom attribute → fileWrapper
  // → attachment.image → attachmentCell.image (HTML paste often lands here).
  private func resolveNaturalImageData(at charIndex: Int) -> (image: NSImage, data: Data)? {
    guard let storage = textStorage, charIndex < storage.length else { return nil }
    let attributes = storage.attributes(at: charIndex, effectiveRange: nil)
    if let data = attributes[.osToolbarNaturalImageData] as? Data,
       let image = NSImage(data: data) {
      return (image, data)
    }
    guard let attachment = attributes[.attachment] as? NSTextAttachment else { return nil }
    if let wrapper = attachment.fileWrapper,
       let data = wrapper.regularFileContents,
       let image = NSImage(data: data) {
      return (image, data)
    }
    if let image = attachment.image, let data = image.tiffRepresentation {
      return (image, data)
    }
    if let cell = attachment.attachmentCell as? NSTextAttachmentCell,
       let image = cell.image,
       let data = image.tiffRepresentation {
      return (image, data)
    }
    return nil
  }

  private static func makeResized(_ source: NSImage, to size: NSSize) -> NSImage {
    let out = NSImage(size: size)
    out.lockFocus()
    source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    out.unlockFocus()
    return out
  }

  /// Walks attachments and (re)wraps each in a ScalingAttachmentCell. New ones
  /// start at 50% of natural size capped to editor width; user-sized ones are kept.
  func capImages() {
    guard let storage = textStorage, storage.length > 0 else { return }
    // Plain-text fast bail.
    let fullRange = NSRange(location: 0, length: storage.length)
    var hasAnyAttachment = false
    storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, stop in
      if value != nil { hasAnyAttachment = true; stop.pointee = true }
    }
    guard hasAnyAttachment else { return }

    let maxWidth = effectiveImageMaxWidth
    // Single begin/endEditing → relayout runs once even for multiple images.
    storage.beginEditing()
    var changed = false
    var index = 0
    while index < storage.length {
      let attrs = storage.attributes(at: index, effectiveRange: nil)
      guard let attachment = attrs[.attachment] as? NSTextAttachment,
            let (naturalImage, naturalData) = resolveNaturalImageData(at: index) else {
        index += 1; continue
      }
      let natural = naturalImage.size
      let boundsWidth = attachment.bounds.width
      let hasScalingCell = attachment.attachmentCell is ScalingAttachmentCell
      let isUserSized = boundsWidth > 0 && boundsWidth < natural.width - 0.5

      if hasScalingCell && isUserSized {
        index += 1; continue  // already wrapped + sized
      }

      // Reloaded user-sized → keep saved bounds. Fresh → 50% of natural.
      let targetSize: NSSize
      if isUserSized {
        targetSize = attachment.bounds.size
      } else {
        let targetWidth = min(natural.width * 0.5, maxWidth)
        let scale = targetWidth / natural.width
        targetSize = NSSize(
          width: targetWidth.rounded(),
          height: (natural.height * scale).rounded()
        )
      }
      let replacement = buildAttachment(naturalBytes: naturalData, displaySize: targetSize)
      let attrString = NSMutableAttributedString(attachment: replacement)
      attrString.addAttribute(.osToolbarNaturalImageData, value: naturalData,
                              range: NSRange(location: 0, length: 1))

      let range = NSRange(location: index, length: 1)
      storage.replaceCharacters(in: range, with: attrString)
      changed = true
      index += 1
    }
    storage.endEditing()
    if changed { needsDisplay = true }
  }

  // Display at `displaySize`, natural bytes preserved in fileWrapper for RTFD reload.
  private func buildAttachment(naturalBytes: Data, displaySize: NSSize) -> NSTextAttachment {
    let wrapper = FileWrapper(regularFileWithContents: naturalBytes)
    wrapper.preferredFilename = "image-\(UUID().uuidString).tiff"
    let attachment = NSTextAttachment()
    attachment.fileWrapper = wrapper
    attachment.bounds = NSRect(origin: .zero, size: displaySize)
    attachment.attachmentCell = ScalingAttachmentCell(imageCell: NSImage(data: naturalBytes))
    return attachment
  }

  // MARK: - Image click options (delete + resize)

  private var imageOptionsPopover: NSPopover?

  private func showImageOptions(for attachment: NSTextAttachment, at charIndex: Int) {
    guard let layoutManager, let textContainer else { return }
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: NSRange(location: charIndex, length: 1),
      actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    let origin = textContainerOrigin
    rect.origin.x += origin.x
    rect.origin.y += origin.y

    let view = ImageOptionsView(
      onDelete: { [weak self] in
        self?.deleteAttachment(at: charIndex)
        self?.imageOptionsPopover?.close()
      },
      onResize: { [weak self] percent in
        self?.resizeAttachment(at: charIndex, percent: percent)
        self?.imageOptionsPopover?.close()
      }
    )

    let hosting = NSHostingController(rootView: view)
    let popover = NSPopover()
    popover.contentViewController = hosting
    popover.behavior = .transient
    popover.show(relativeTo: rect, of: self, preferredEdge: .minY)
    imageOptionsPopover = popover
  }

  private func deleteAttachment(at charIndex: Int) {
    guard let storage = textStorage, charIndex < storage.length else { return }
    let range = NSRange(location: charIndex, length: 1)
    guard shouldChangeText(in: range, replacementString: "") else { return }
    storage.replaceCharacters(in: range, with: "")
    didChangeText()
  }

  private func resizeAttachment(at charIndex: Int, percent: Int) {
    guard let storage = textStorage, charIndex < storage.length,
          let (naturalImage, naturalData) = resolveNaturalImageData(at: charIndex) else { return }

    let factor = CGFloat(percent) / 100
    let newSize = NSSize(
      width: (naturalImage.size.width * factor).rounded(),
      height: (naturalImage.size.height * factor).rounded()
    )

    let replacement = buildAttachment(naturalBytes: naturalData, displaySize: newSize)
    let attrString = NSMutableAttributedString(attachment: replacement)
    attrString.addAttribute(.osToolbarNaturalImageData, value: naturalData,
                            range: NSRange(location: 0, length: 1))

    let range = NSRange(location: charIndex, length: 1)
    guard shouldChangeText(in: range, replacementString: attrString.string) else { return }
    storage.replaceCharacters(in: range, with: attrString)
    didChangeText()
  }

  override func insertNewline(_ sender: Any?) {
    let nsText = string as NSString
    let lineRange = nsText.lineRange(for: selectedRange())
    let lineText = nsText.substring(with: lineRange)

    for marker in ListMarker.all where lineText.hasPrefix(marker) {
      let body = String(lineText.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      if body.isEmpty {
        // Empty list item: strip the marker, break out of the list.
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
      // Click on an image → show the inline options popover (delete + resize).
      if let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment,
         attachment.image != nil || attachment.fileWrapper?.regularFileContents != nil {
        showImageOptions(for: attachment, at: charIndex)
        return
      }
    }
    super.mouseDown(with: event)
  }

  // MARK: - Image hover preview

  private var imageHoverButton: NSButton?
  private var hoveredAttachment: NSTextAttachment?
  private var hoveredCharIndex = -1
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
    hoveredCharIndex = charIndex
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
    // Always open at 100% natural, regardless of in-editor display size.
    if hoveredCharIndex >= 0,
       let (naturalImage, _) = resolveNaturalImageData(at: hoveredCharIndex) {
      ImagePreviewWindow.showImage(naturalImage)
      return
    }
    if let attachment = hoveredAttachment {
      ImagePreviewWindow.show(attachment: attachment)
    }
  }

  private func toggleCheckbox(at index: Int, current: String) {
    let toggled = current == "○" ? "●" : "○"
    let range = NSRange(location: index, length: 1)
    guard shouldChangeText(in: range, replacementString: toggled) else { return }
    textStorage?.replaceCharacters(in: range, with: toggled)
    // Strikethrough body when checked, clear when unchecked.
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

/// SwiftUI wrapper for the ListTextView. Reloads content only on note switch
/// (driven by `noteID`), never on keystrokes.
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
    // Reload content on note switch only — never on every keystroke.
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
    // Per-coordinator undo manager so it dies with the SwiftUI view when
    // `.id(note.id)` recreates it. The shared window undo manager would
    // otherwise hold stale NSTextView targets → EXC_BAD_ACCESS on Cmd+Z.
    let editorUndoManager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      // `expected` lets the controller reject a stray change after selection switch.
      let expected = loadedNoteID
      MainActor.assumeIsolated {
        NotesController.shared.editorContentChanged(textView.attributedString(), expectedNoteID: expected)
      }
    }
  }
}

/// Inline popover shown on image click: delete + percentage size buttons.
fileprivate struct ImageOptionsView: View {
  let onDelete: () -> Void
  let onResize: (Int) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onDelete) {
        Image(systemName: "trash")
          .foregroundStyle(.red)
          .frame(width: 30, height: 22)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Delete image")

      Divider().frame(height: 18)

      ForEach([10, 25, 50, 75, 100], id: \.self) { percent in
        Button { onResize(percent) } label: {
          Text("\(percent)%")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 36, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Resize to \(percent)% of original")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }
}

/// Floating window that shows an image attachment at full natural size
/// (capped to 80% of the visible screen).
@MainActor
enum ImagePreviewWindow {
  private static var window: NSWindow?

  static func show(attachment: NSTextAttachment) {
    guard let image = imageFromAttachment(attachment) else { return }
    showImage(image)
  }

  static func showImage(_ image: NSImage) {
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
