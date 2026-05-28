import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  func body(content: Content) -> some View {
    content.onHover { hovering in
      if hovering {
        // While the list is scrolling, rows pass under the (stationary) cursor and
        // fire onHover for each one. Selecting on every such row triggers a full
        // O(n) LazyVStack re-layout per row and freezes fast scrolling. Skip it —
        // moving the mouse (not scrolling) still selects normally.
        if appState.navigator.isScrolling {
          return
        }
        if !appState.navigator.isKeyboardNavigating && !appState.navigator.isMultiSelectInProgress {
          appState.navigator.selectWithoutScrolling(id: id)
        } else {
          appState.navigator.hoverSelectionWhileKeyboardNavigating = id
        }
      }
    }
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    modifier(HoverSelectionModifier(id: id))
  }
}
