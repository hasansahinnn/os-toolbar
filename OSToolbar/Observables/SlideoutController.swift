import Defaults
import Logging
import Observation
import SwiftUI

enum SlideoutState {
  case opening
  case closing
  case open
  case closed

  var isAnimating: Bool {
    switch self {
    case .closed, .open:
      return false
    case .opening, .closing:
      return true
    }
  }

  var isOpen: Bool {
    switch self {
    case .open, .opening:
      return true
    case .closed, .closing:
      return false
    }
  }

  fileprivate func toggleWithAnimation() -> SlideoutState {
    switch self {
    case .open, .opening:
      return .closing
    case .closed, .closing:
      return .opening
    }
  }

  func animationDone() -> SlideoutState {
    switch self {
    case .open, .opening:
      return .open
    case .closed, .closing:
      return .closed
    }
  }
}

enum SlideoutPlacement {
  case left
  case right
}

enum SlideoutToggleTrigger {
  case autoOpen
  case manual
}

enum ResizingMode {
  case none
  case content
  case slideout
}

@Observable
class SlideoutController {
  let logger = Logger(label: "com.ostoolbar.app")
  private static let animationDuration = 0.25

  let onContentResize: (CGFloat) -> Void
  let onSlideoutResize: (CGFloat) -> Void

  let minimumContentWidth: CGFloat = 200
  var contentResizeWidth: CGFloat = 0
  var contentAnimationWidth: CGFloat?

  let minimumSlideoutWidth: CGFloat = 200
  var slideoutResizeWidth: CGFloat = 0

  private var _contentWidth: CGFloat = 0
  var contentWidth: CGFloat {
    get { return _contentWidth }
    set {
      _contentWidth = max(minimumContentWidth, newValue).rounded()
      onContentResize(_contentWidth)
    }
  }
  private var _slideoutWidth: CGFloat = 400
  var slideoutWidth: CGFloat {
    get { return _slideoutWidth }
    set {
      _slideoutWidth = max(minimumSlideoutWidth, newValue).rounded()
      onSlideoutResize(_slideoutWidth)
    }
  }

  var placement: SlideoutPlacement = .right
  var state: SlideoutState = .closed
  var resizingMode: ResizingMode = .none

  var nswindow: NSWindow? {
    return AppState.shared.appDelegate?.panel
  }

  private var windowAnimationOrigin: CGPoint?
  private var windowAnimationOriginBaseState: SlideoutState = .closed

  private var autoOpenTask: Task<Void, Never>?
  private var autoOpenSuppressed = false
  private var autoOpenEnabled = true
  private var closeForHoverTask: Task<Void, Never>?

  // The item shown in the preview, updated only after the selection settles.
  // SlideoutContentView observes THESE (not leadHistoryItem), so its body
  // re-renders only when scrolling stops — not on every row passed under the
  // mouse during a fast scroll, which used to saturate the main thread and
  // freeze the UI while the preview was open.
  var previewItem: HistoryItemDecorator?
  var previewPasteStackSelected = false
  private var previewDebounceTask: Task<Void, Never>?

  // Called from NavigationManager whenever the lead selection changes. Cheap:
  // just cancels and reschedules a debounce timer. The actual (observable)
  // preview state is only written once the selection has been stable for a beat.
  func schedulePreview() {
    previewDebounceTask?.cancel()
    guard state != .closed else {
      previewItem = nil
      previewPasteStackSelected = false
      return
    }
    previewDebounceTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, state != .closed else { return }
      let navigator = AppState.shared.navigator
      previewItem = navigator.leadHistoryItem
      previewPasteStackSelected = navigator.pasteStackSelected
    }
  }

  // Snapshot the current selection into the observable preview state right away,
  // with no debounce — used when the preview is opened so it shows immediately.
  private func syncPreviewNow() {
    previewDebounceTask?.cancel()
    let navigator = AppState.shared.navigator
    previewItem = navigator.leadHistoryItem
    previewPasteStackSelected = navigator.pasteStackSelected
  }

  private func clearPreview() {
    previewDebounceTask?.cancel()
    previewItem = nil
    previewPasteStackSelected = false
  }

  init(onContentResize: @escaping (CGFloat) -> Void, onSlideoutResize: @escaping (CGFloat) -> Void) {
    self.onContentResize = onContentResize
    self.onSlideoutResize = onSlideoutResize
  }

  private func togglePreviewStateWithAnimation(windowFrame: NSRect) {
    let newValue = state.toggleWithAnimation()
    if !state.isAnimating && newValue.isAnimating {
      contentAnimationWidth = contentWidth
      windowAnimationOrigin = windowFrame.origin
      windowAnimationOriginBaseState = state
    }
    state = newValue
  }

  func computePlacement(window: NSWindow, for size: NSSize) -> SlideoutPlacement {
    guard let screen = window.screen?.frame else { return placement }
    let windowFrame = window.frame
    if windowFrame.minX + size.width > screen.maxX {
      return .left
    } else {
      return .right
    }
  }

  func computeSizeWithPreview(_ size: NSSize, state newState: SlideoutState) -> NSSize {
    var newSize = size
    if newState.isOpen {
      newSize.width += slideoutWidth
    }
    let popup = AppState.shared.popup
    newSize.height = popup.preferredHeight(for: popup.height)
    return newSize
  }

  func togglePreview(trigger: SlideoutToggleTrigger = .manual) {
    if !state.isOpen {
      let navigator = AppState.shared.navigator
      guard navigator.leadHistoryItem != nil || navigator.pasteStackSelected else { return }
    }

    if trigger == .manual {
      if state.isOpen {
        autoOpenSuppressed = true
      } else {
        autoOpenSuppressed = false
      }
    }

    cancelAutoOpen()

    // Update the observable preview state up front: show the current selection
    // immediately when opening, clear it when closing.
    if state.isOpen {
      clearPreview()
    } else {
      syncPreviewNow()
    }

    withAnimation(.easeInOut(duration: Self.animationDuration), completionCriteria: .removed) {
      if let window = nswindow {
        togglePreviewStateWithAnimation(windowFrame: window.frame)
        var newSize = window.frame.size
        newSize.width = contentWidth
        newSize = computeSizeWithPreview(newSize, state: self.state)
        if state.isOpen {
          placement = computePlacement(window: window, for: newSize)
        }

        let expectedAnimationState = state
        NSAnimationContext.runAnimationGroup { (context) in
          var newOrigin = windowAnimationOrigin ?? window.frame.origin
          newOrigin.y += (window.frame.height - newSize.height)

          if placement == .left {
            if windowAnimationOriginBaseState == .closed && state.isOpen {
              newOrigin.x -= slideoutWidth
            } else if windowAnimationOriginBaseState == .open
              && !state.isOpen {
              newOrigin.x += slideoutWidth
            }
            // Otherwise the base is the desired position
          }
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          context.completionHandler = {
            if self.state == expectedAnimationState {
              self.state = expectedAnimationState.animationDone()
            }
          }
          context.duration = Self.animationDuration
          window.animator().setFrame(
            NSRect(origin: newOrigin, size: newSize),
            display: true
          )
        }
      }
    } completion: {
    }
  }

  func startResize(mode: ResizingMode) {
    logger.info("Starting resize with mode \(mode)")
    resizingMode = mode
    contentWidth = contentResizeWidth
    slideoutWidth = slideoutResizeWidth
  }

  func endResize() {
    logger.info("Ended resize. Mode was \(resizingMode)")
    switch resizingMode {
    case .none:
      return
    case .content:
      contentWidth = contentResizeWidth
    case .slideout:
      slideoutWidth = slideoutResizeWidth
    }
    resizingMode = .none
  }

  func startAutoOpen() {
    // Auto-open on hover/selection is disabled: it opened the preview for every
    // hovered row (slow/janky with image items). The preview now opens only on
    // explicit intent — hovering the small zone on the right edge of a row
    // (openForHover) or pressing the preview shortcut (togglePreview).
    cancelAutoOpen()
  }

  // Open the preview for the currently selected item, from the right-edge arrow
  // hover zone. Cancels any pending close so moving between adjacent arrows just
  // updates the content instead of flickering closed.
  func openForHover() {
    closeForHoverTask?.cancel()
    closeForHoverTask = nil
    guard !state.isOpen else { return }
    togglePreview(trigger: .manual)
  }

  // The mouse left an arrow zone — close the preview shortly, unless another
  // arrow is hovered in the meantime (which cancels this). This keeps the heavy
  // image preview open only while the pointer is actually on an arrow.
  func scheduleCloseForHover() {
    closeForHoverTask?.cancel()
    closeForHoverTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      if state.isOpen {
        togglePreview(trigger: .manual)
      }
    }
  }

  func cancelAutoOpen() {
    autoOpenTask?.cancel()
    autoOpenTask = nil
  }

  func enableAutoOpen() {
    autoOpenEnabled = true
  }

  func disableAutoOpen() {
    autoOpenEnabled = false
    cancelAutoOpen()
  }

  func resetAutoOpenSuppression() {
    autoOpenSuppressed = false
  }
}
