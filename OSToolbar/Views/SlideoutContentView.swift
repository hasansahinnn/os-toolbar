import SwiftUI

struct SlideoutContentView: View {
  @Environment(AppState.self) var appState

  // When the preview is closed this view must be completely inert: it is still
  // mounted (zero-width) by SlideoutView, so if it observed the selection it
  // would re-render on every hovered row while scrolling — which froze the list.
  private var isOpen: Bool { appState.preview.state != .closed }

  var body: some View {
    Group {
      if isOpen {
        VStack {
          ToolbarView()

          // We read ONLY the debounced preview state from SlideoutController
          // (previewItem / previewPasteStackSelected). These change only once the
          // selection settles, so fast scrolling does not re-render this subtree.
          if let item = appState.preview.previewItem {
            PreviewItemView(item: item)
              .id(item.id)
          } else if let pasteStack = appState.history.pasteStack,
            appState.preview.previewPasteStackSelected {
            PasteStackPreviewView(pasteStack: pasteStack)
          } else {
            EmptyView()
          }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, Popup.verticalPadding)
      } else {
        Color.clear.frame(width: 0, height: 0)
      }
    }
  }
}
