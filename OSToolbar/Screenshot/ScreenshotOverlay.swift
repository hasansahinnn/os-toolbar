import AppKit
import Defaults
import SwiftHEXColors

enum ScreenshotTool: Int, CaseIterable {
  case select, pen, line, arrow, rectangle, ellipse, highlighter, text

  var symbolName: String {
    switch self {
    case .select: return "cursorarrow"
    case .pen: return "scribble"
    case .line: return "line.diagonal"
    case .arrow: return "arrow.up.right"
    case .rectangle: return "rectangle"
    case .ellipse: return "circle"
    case .highlighter: return "highlighter"
    case .text: return "textformat"
    }
  }

  var tooltip: String {
    switch self {
    case .select: return "Move / resize selection"
    case .pen: return "Pen"
    case .line: return "Line"
    case .arrow: return "Arrow"
    case .rectangle: return "Rectangle"
    case .ellipse: return "Ellipse"
    case .highlighter: return "Highlighter"
    case .text: return "Text"
    }
  }

  var isDrawing: Bool { self != .select }
}

final class Annotation {
  let tool: ScreenshotTool
  var color: NSColor
  var lineWidth: CGFloat
  var fontSize: CGFloat
  var points: [NSPoint] = []      // pen
  var start: NSPoint = .zero      // line, arrow, rectangle, ellipse, highlighter, text
  var end: NSPoint = .zero
  var text: String = ""

  init(tool: ScreenshotTool, color: NSColor, lineWidth: CGFloat, fontSize: CGFloat) {
    self.tool = tool
    self.color = color
    self.lineWidth = lineWidth
    self.fontSize = fontSize
  }

  var rect: NSRect {
    NSRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
  }
}

extension NSColor {
  var hexString: String {
    guard let rgb = usingColorSpace(.sRGB) else { return "#FF3B30" }
    let r = Int(round(rgb.redComponent * 255))
    let g = Int(round(rgb.greenComponent * 255))
    let b = Int(round(rgb.blueComponent * 255))
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}

// MARK: - Window

@MainActor
final class ScreenshotOverlayWindow: NSWindow {
  private let onFinish: () -> Void
  private let canvas: ScreenshotCanvasView
  private var didFinish = false

  init(cgImage: CGImage, screen: NSScreen, scale: CGFloat, onFinish: @escaping () -> Void) {
    self.onFinish = onFinish
    let frame = screen.frame
    let image = NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height))
    canvas = ScreenshotCanvasView(frame: NSRect(origin: .zero, size: frame.size), image: image, scale: scale)

    super.init(
      contentRect: frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )

    // We manage the window's lifetime via the controller's strong reference.
    // Letting AppKit auto-release on close caused a double-free during the
    // close animation teardown (EXC_BAD_ACCESS in _NSWindowTransformAnimation).
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    animationBehavior = .none
    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    hasShadow = false
    contentView = canvas
    canvas.onClose = { [weak self] in self?.finish() }
  }

  func present() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    makeFirstResponder(canvas)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    orderOut(nil)
    // Release on the next runloop tick so AppKit finishes the current
    // Core Animation transaction before the window deallocates.
    let finishHandler = onFinish
    DispatchQueue.main.async { finishHandler() }
  }
}

// MARK: - Canvas (editor)

@MainActor
final class ScreenshotCanvasView: NSView {
  var onClose: (() -> Void)?

  private let backgroundImage: NSImage
  private let scale: CGFloat

  private var selection: NSRect?
  private var annotations: [Annotation] = []
  private var current: Annotation?

  private var tool: ScreenshotTool = .select
  private var color: NSColor
  private var lineWidth: CGFloat
  private var fontSize: CGFloat

  private enum DragMode { case none, creatingSelection, movingSelection, resizing(Handle), drawing }
  private var dragMode: DragMode = .none
  private var dragOrigin: NSPoint = .zero
  private var selectionAtDragStart: NSRect = .zero

  private var toolbar: ScreenshotToolbarView?
  private var activeTextView: NSTextView?
  private var activeTextOrigin: NSPoint = .zero

  private let handleSize: CGFloat = 8

  init(frame: NSRect, image: NSImage, scale: CGFloat) {
    self.backgroundImage = image
    self.scale = scale
    self.color = NSColor(hexString: Defaults[.screenshotColorHex]) ?? .systemRed
    self.lineWidth = CGFloat(Defaults[.screenshotLineWidth])
    self.fontSize = CGFloat(Defaults[.screenshotFontSize])
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() {
    let cursor: NSCursor = (selection == nil || tool.isDrawing) ? .crosshair : .arrow
    addCursorRect(bounds, cursor: cursor)
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    backgroundImage.draw(in: bounds)

    let dim = NSColor.black.withAlphaComponent(0.5)
    dim.setFill()
    if let sel = selection {
      // Dim everything outside the selection with four border strips.
      NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: sel.minY - bounds.minY).fill()
      NSRect(x: bounds.minX, y: sel.maxY, width: bounds.width, height: bounds.maxY - sel.maxY).fill()
      NSRect(x: bounds.minX, y: sel.minY, width: sel.minX - bounds.minX, height: sel.height).fill()
      NSRect(x: sel.maxX, y: sel.minY, width: bounds.maxX - sel.maxX, height: sel.height).fill()
    } else {
      bounds.fill()
    }

    drawAnnotations(clipTo: selection)

    if let sel = selection {
      NSColor.white.setStroke()
      let border = NSBezierPath(rect: sel)
      border.lineWidth = 1
      border.stroke()
      if !tool.isDrawing {
        drawHandles(for: sel)
      }
      drawSizeBadge(for: sel)
    }
  }

  private func drawAnnotations(clipTo clip: NSRect?) {
    NSGraphicsContext.current?.saveGraphicsState()
    if let clip = clip {
      NSBezierPath(rect: clip).addClip()
    }
    for annotation in annotations {
      draw(annotation)
    }
    if let current = current {
      draw(current)
    }
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private func draw(_ a: Annotation) {
    a.color.setStroke()
    a.color.setFill()

    switch a.tool {
    case .pen:
      guard a.points.count > 1 else { return }
      let path = NSBezierPath()
      path.lineWidth = a.lineWidth
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.move(to: a.points[0])
      for point in a.points.dropFirst() { path.line(to: point) }
      path.stroke()

    case .line:
      let path = NSBezierPath()
      path.lineWidth = a.lineWidth
      path.lineCapStyle = .round
      path.move(to: a.start)
      path.line(to: a.end)
      path.stroke()

    case .arrow:
      drawArrow(from: a.start, to: a.end, lineWidth: a.lineWidth)

    case .rectangle:
      let path = NSBezierPath(rect: a.rect)
      path.lineWidth = a.lineWidth
      path.stroke()

    case .ellipse:
      let path = NSBezierPath(ovalIn: a.rect)
      path.lineWidth = a.lineWidth
      path.stroke()

    case .highlighter:
      let path = NSBezierPath()
      path.lineWidth = max(a.lineWidth * 4, 12)
      path.lineCapStyle = .round
      path.move(to: a.start)
      path.line(to: a.end)
      a.color.withAlphaComponent(0.35).setStroke()
      path.stroke()

    case .text:
      guard !a.text.isEmpty else { return }
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: a.fontSize),
        .foregroundColor: a.color
      ]
      a.text.draw(at: a.start, withAttributes: attrs)

    case .select:
      break
    }
  }

  private func drawArrow(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: start)
    path.line(to: end)

    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength = max(lineWidth * 3, 12)
    let headAngle = CGFloat.pi / 6
    let left = NSPoint(
      x: end.x - headLength * cos(angle - headAngle),
      y: end.y - headLength * sin(angle - headAngle)
    )
    let right = NSPoint(
      x: end.x - headLength * cos(angle + headAngle),
      y: end.y - headLength * sin(angle + headAngle)
    )
    path.move(to: end)
    path.line(to: left)
    path.move(to: end)
    path.line(to: right)
    path.stroke()
  }

  private func drawHandles(for sel: NSRect) {
    NSColor.white.setFill()
    NSColor.systemBlue.setStroke()
    for point in handlePoints(for: sel) {
      let rect = NSRect(
        x: point.x - handleSize / 2,
        y: point.y - handleSize / 2,
        width: handleSize,
        height: handleSize
      )
      let path = NSBezierPath(ovalIn: rect)
      path.fill()
      path.lineWidth = 1
      path.stroke()
    }
  }

  private func drawSizeBadge(for sel: NSRect) {
    let text = "\(Int(sel.width * scale)) × \(Int(sel.height * scale))"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.white
    ]
    let size = text.size(withAttributes: attrs)
    var origin = NSPoint(x: sel.minX, y: sel.minY - size.height - 6)
    if origin.y < bounds.minY + 2 { origin.y = sel.minY + 4 }
    let padding: CGFloat = 4
    let bgRect = NSRect(
      x: origin.x - padding, y: origin.y - padding,
      width: size.width + padding * 2, height: size.height + padding * 2
    )
    NSColor.black.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3).fill()
    text.draw(at: origin, withAttributes: attrs)
  }

  // MARK: Handles

  private enum Handle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
  }

  private func handlePoints(for sel: NSRect) -> [NSPoint] {
    [
      NSPoint(x: sel.minX, y: sel.minY),
      NSPoint(x: sel.midX, y: sel.minY),
      NSPoint(x: sel.maxX, y: sel.minY),
      NSPoint(x: sel.maxX, y: sel.midY),
      NSPoint(x: sel.maxX, y: sel.maxY),
      NSPoint(x: sel.midX, y: sel.maxY),
      NSPoint(x: sel.minX, y: sel.maxY),
      NSPoint(x: sel.minX, y: sel.midY)
    ]
  }

  private func handle(at point: NSPoint, in sel: NSRect) -> Handle? {
    let points = handlePoints(for: sel)
    for (index, handlePoint) in points.enumerated() {
      let rect = NSRect(
        x: handlePoint.x - handleSize, y: handlePoint.y - handleSize,
        width: handleSize * 2, height: handleSize * 2
      )
      if rect.contains(point) { return Handle(rawValue: index) }
    }
    return nil
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    commitActiveText()

    if tool == .text, selection?.contains(point) == true {
      beginTextEditing(at: point)
      return
    }

    if let sel = selection {
      if tool.isDrawing {
        if sel.contains(point) {
          dragMode = .drawing
          let annotation = Annotation(tool: tool, color: color, lineWidth: lineWidth, fontSize: fontSize)
          annotation.start = point
          annotation.end = point
          annotation.points = [point]
          current = annotation
        }
        return
      }
      // select tool: resize / move / new selection
      if let handle = handle(at: point, in: sel) {
        dragMode = .resizing(handle)
        dragOrigin = point
        selectionAtDragStart = sel
      } else if sel.contains(point) {
        dragMode = .movingSelection
        dragOrigin = point
        selectionAtDragStart = sel
      } else {
        startNewSelection(at: point)
      }
    } else {
      startNewSelection(at: point)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    let point = clampToBounds(convert(event.locationInWindow, from: nil))

    switch dragMode {
    case .creatingSelection:
      selection = rect(from: dragOrigin, to: point)
    case .movingSelection:
      let dx = point.x - dragOrigin.x
      let dy = point.y - dragOrigin.y
      var moved = selectionAtDragStart.offsetBy(dx: dx, dy: dy)
      moved = clampRect(moved)
      selection = moved
    case .resizing(let handle):
      selection = resize(selectionAtDragStart, handle: handle, to: point)
    case .drawing:
      if let current = current {
        current.end = point
        current.points.append(point)
      }
    case .none:
      break
    }
    needsDisplay = true
    repositionToolbar()
  }

  override func mouseUp(with event: NSEvent) {
    switch dragMode {
    case .creatingSelection:
      if let sel = selection, sel.width < 5 || sel.height < 5 {
        selection = nil
      }
      showToolbarIfNeeded()
    case .drawing:
      if let current = current {
        annotations.append(current)
        persistStyle()
      }
      current = nil
    default:
      break
    }
    dragMode = .none
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
    repositionToolbar()
  }

  private func startNewSelection(at point: NSPoint) {
    removeToolbar()
    selection = NSRect(origin: point, size: .zero)
    dragOrigin = point
    dragMode = .creatingSelection
  }

  // MARK: Selection geometry

  private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
    NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
  }

  private func clampToBounds(_ point: NSPoint) -> NSPoint {
    NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
  }

  private func clampRect(_ rect: NSRect) -> NSRect {
    var r = rect
    if r.minX < bounds.minX { r.origin.x = bounds.minX }
    if r.minY < bounds.minY { r.origin.y = bounds.minY }
    if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
    if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
    return r
  }

  private func resize(_ rect: NSRect, handle: Handle, to point: NSPoint) -> NSRect {
    var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
    switch handle {
    case .topLeft: minX = point.x; minY = point.y
    case .top: minY = point.y
    case .topRight: maxX = point.x; minY = point.y
    case .right: maxX = point.x
    case .bottomRight: maxX = point.x; maxY = point.y
    case .bottom: maxY = point.y
    case .bottomLeft: minX = point.x; maxY = point.y
    case .left: minX = point.x
    }
    return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
  }

  // MARK: Text editing

  private func beginTextEditing(at point: NSPoint) {
    let textView = NSTextView(frame: NSRect(x: point.x, y: point.y, width: 260, height: fontSize + 12))
    textView.font = NSFont.systemFont(ofSize: fontSize)
    textView.textColor = color
    textView.backgroundColor = NSColor.white.withAlphaComponent(0.15)
    textView.drawsBackground = true
    textView.isRichText = false
    textView.allowsUndo = true
    textView.textContainerInset = NSSize(width: 2, height: 2)
    addSubview(textView)
    window?.makeFirstResponder(textView)
    activeTextView = textView
    activeTextOrigin = point
  }

  private func commitActiveText() {
    guard let textView = activeTextView else { return }
    let string = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    if !string.isEmpty {
      let annotation = Annotation(tool: .text, color: color, lineWidth: lineWidth, fontSize: fontSize)
      annotation.start = NSPoint(x: activeTextOrigin.x + 2, y: activeTextOrigin.y + 2)
      annotation.text = string
      annotations.append(annotation)
      persistStyle()
    }
    textView.removeFromSuperview()
    activeTextView = nil
    needsDisplay = true
  }

  // MARK: Toolbar

  private func showToolbarIfNeeded() {
    guard selection != nil else { return }
    if toolbar == nil {
      let toolbar = ScreenshotToolbarView(
        initialTool: tool,
        color: color,
        lineWidth: lineWidth,
        delegate: self
      )
      addSubview(toolbar)
      self.toolbar = toolbar
    }
    repositionToolbar()
  }

  private func removeToolbar() {
    toolbar?.removeFromSuperview()
    toolbar = nil
  }

  private func repositionToolbar() {
    guard let sel = selection, let toolbar = toolbar else { return }
    let size = toolbar.fittingSize
    var origin = NSPoint(x: sel.minX, y: sel.maxY + 8)
    if origin.y + size.height > bounds.maxY { origin.y = sel.minY - size.height - 8 }
    if origin.y < bounds.minY { origin.y = bounds.minY + 8 }
    origin.x = min(max(bounds.minX + 8, origin.x), bounds.maxX - size.width - 8)
    toolbar.frame = NSRect(origin: origin, size: size)
  }

  // MARK: Persistence

  private func persistStyle() {
    Defaults[.screenshotColorHex] = color.hexString
    Defaults[.screenshotLineWidth] = Double(lineWidth)
    Defaults[.screenshotFontSize] = Double(fontSize)
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    let command = event.modifierFlags.contains(.command)
    switch event.keyCode {
    case 53: // esc
      if activeTextView != nil { commitActiveText() } else { cancel() }
    case 6 where command: // cmd+z
      undo()
    case 8 where command: // cmd+c
      commitActiveText()
      copyToClipboard()
    default:
      super.keyDown(with: event)
    }
  }

  // MARK: Actions

  func cancel() {
    onClose?()
  }

  func undo() {
    if !annotations.isEmpty {
      annotations.removeLast()
      needsDisplay = true
    }
  }

  func copyToClipboard() {
    commitActiveText()
    guard let png = exportPNG() else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let image = NSImage(data: png) {
      pasteboard.writeObjects([image])
    }
    pasteboard.setData(png, forType: .png)
    onClose?()
  }

  func saveToDefault() {
    commitActiveText()
    guard let png = exportPNG() else { return }
    ScreenshotPreferences.saveToDefaultDirectory(png)
    onClose?()
  }

  func saveAs() {
    commitActiveText()
    guard let png = exportPNG() else { return }
    // Tear down the shield-level overlay FIRST, otherwise the save panel
    // opens behind it and can't be seen or interacted with.
    onClose?()
    DispatchQueue.main.async {
      _ = ScreenshotPreferences.saveAs(png)
    }
  }

  // MARK: Export

  private func exportPNG() -> Data? {
    guard let sel = selection, sel.width > 0, sel.height > 0 else { return nil }

    let pixelSize = NSSize(width: round(sel.width * scale), height: round(sel.height * scale))
    let image = NSImage(size: pixelSize)
    image.lockFocusFlipped(true)
    if let context = NSGraphicsContext.current {
      context.cgContext.scaleBy(x: scale, y: scale)
      context.cgContext.translateBy(x: -sel.minX, y: -sel.minY)
      backgroundImage.draw(in: bounds)
      drawAnnotations(clipTo: sel)
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}

// MARK: - Toolbar delegate

@MainActor
protocol ScreenshotToolbarDelegate: AnyObject {
  func toolbarDidSelectTool(_ tool: ScreenshotTool)
  func toolbarDidChangeColor(_ color: NSColor)
  func toolbarDidChangeSize(_ value: CGFloat)
  func toolbarSizeRange(for tool: ScreenshotTool) -> (min: CGFloat, max: CGFloat, value: CGFloat)
  func toolbarDidTapUndo()
  func toolbarDidTapCopy()
  func toolbarDidTapSave()
  func toolbarDidTapSaveAs()
  func toolbarDidTapCancel()
}

extension ScreenshotCanvasView: ScreenshotToolbarDelegate {
  func toolbarDidSelectTool(_ tool: ScreenshotTool) {
    commitActiveText()
    self.tool = tool
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
  }

  func toolbarDidChangeColor(_ color: NSColor) {
    self.color = color
    activeTextView?.textColor = color
    persistStyle()
  }

  func toolbarDidChangeSize(_ value: CGFloat) {
    if tool == .text {
      fontSize = value
      activeTextView?.font = NSFont.systemFont(ofSize: value)
    } else {
      lineWidth = value
    }
    persistStyle()
  }

  func toolbarSizeRange(for tool: ScreenshotTool) -> (min: CGFloat, max: CGFloat, value: CGFloat) {
    if tool == .text {
      return (8, 72, fontSize)
    }
    return (1, 24, lineWidth)
  }

  func toolbarDidTapUndo() { undo() }
  func toolbarDidTapCopy() { copyToClipboard() }
  func toolbarDidTapSave() { saveToDefault() }
  func toolbarDidTapSaveAs() { saveAs() }
  func toolbarDidTapCancel() { cancel() }
}

// MARK: - Toolbar view

@MainActor
final class ScreenshotToolbarView: NSView {
  private weak var delegate: ScreenshotToolbarDelegate?
  private var toolButtons: [ScreenshotTool: NSButton] = [:]
  private let colorWell = NSColorWell()
  private let sizeSlider = NSSlider()
  private var currentTool: ScreenshotTool

  init(initialTool: ScreenshotTool, color: NSColor, lineWidth: CGFloat, delegate: ScreenshotToolbarDelegate) {
    self.delegate = delegate
    self.currentTool = initialTool
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
    layer?.cornerRadius = 8

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])

    for tool in ScreenshotTool.allCases {
      let button = makeIconButton(symbol: tool.symbolName, tooltip: tool.tooltip, action: #selector(toolTapped(_:)))
      button.tag = tool.rawValue
      toolButtons[tool] = button
      stack.addArrangedSubview(button)
    }

    stack.addArrangedSubview(makeSeparator())

    colorWell.color = color
    colorWell.target = self
    colorWell.action = #selector(colorChanged(_:))
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
    colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
    stack.addArrangedSubview(colorWell)

    sizeSlider.minValue = 1
    sizeSlider.maxValue = 24
    sizeSlider.doubleValue = Double(lineWidth)
    sizeSlider.target = self
    sizeSlider.action = #selector(sizeChanged(_:))
    sizeSlider.translatesAutoresizingMaskIntoConstraints = false
    sizeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
    stack.addArrangedSubview(sizeSlider)

    stack.addArrangedSubview(makeSeparator())

    stack.addArrangedSubview(makeIconButton(symbol: "arrow.uturn.backward", tooltip: "Undo", action: #selector(undoTapped)))
    stack.addArrangedSubview(makeIconButton(symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: #selector(copyTapped)))
    stack.addArrangedSubview(makeIconButton(symbol: "square.and.arrow.down", tooltip: "Save to default folder", action: #selector(saveTapped)))
    stack.addArrangedSubview(makeIconButton(symbol: "square.and.arrow.down.on.square", tooltip: "Save As…", action: #selector(saveAsTapped)))
    stack.addArrangedSubview(makeIconButton(symbol: "xmark", tooltip: "Cancel (Esc)", action: #selector(cancelTapped)))

    highlightSelectedTool()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
    let button = NSButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
    button.bezelStyle = .rounded
    button.isBordered = false
    button.contentTintColor = .white
    button.imageScaling = .scaleProportionallyDown
    button.target = self
    button.action = action
    button.toolTip = tooltip
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 26).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return button
  }

  private func makeSeparator() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 1).isActive = true
    view.heightAnchor.constraint(equalToConstant: 20).isActive = true
    return view
  }

  private func highlightSelectedTool() {
    for (tool, button) in toolButtons {
      let selected = tool == currentTool
      button.contentTintColor = selected ? .systemBlue : .white
      button.wantsLayer = true
      button.layer?.backgroundColor = selected
        ? NSColor.white.withAlphaComponent(0.18).cgColor
        : NSColor.clear.cgColor
      button.layer?.cornerRadius = 5
    }
  }

  @objc private func toolTapped(_ sender: NSButton) {
    guard let tool = ScreenshotTool(rawValue: sender.tag) else { return }
    currentTool = tool
    highlightSelectedTool()
    delegate?.toolbarDidSelectTool(tool)
    if let range = delegate?.toolbarSizeRange(for: tool) {
      sizeSlider.minValue = Double(range.min)
      sizeSlider.maxValue = Double(range.max)
      sizeSlider.doubleValue = Double(range.value)
    }
  }

  @objc private func colorChanged(_ sender: NSColorWell) {
    delegate?.toolbarDidChangeColor(sender.color)
  }

  @objc private func sizeChanged(_ sender: NSSlider) {
    delegate?.toolbarDidChangeSize(CGFloat(sender.doubleValue))
  }

  @objc private func undoTapped() { delegate?.toolbarDidTapUndo() }
  @objc private func copyTapped() { delegate?.toolbarDidTapCopy() }
  @objc private func saveTapped() { delegate?.toolbarDidTapSave() }
  @objc private func saveAsTapped() { delegate?.toolbarDidTapSaveAs() }
  @objc private func cancelTapped() { delegate?.toolbarDidTapCancel() }
}
