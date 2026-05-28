import Defaults
import SwiftUI

struct HistoryListView: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.scenePhase) private var scenePhase

  @Default(.pinTo) private var pinTo
  @Default(.previewDelay) private var previewDelay
  @Default(.showFooter) private var showFooter

  private var pinnedItems: [HistoryItemDecorator] {
    appState.history.pinnedItems.filter(\.isVisible)
  }
  private var unpinnedItems: [HistoryItemDecorator] {
    appState.history.unpinnedItems.filter(\.isVisible)
  }
  private var showPinsSeparator: Bool {
    pinsVisible && !unpinnedItems.isEmpty
  }

  private var pinsVisible: Bool {
    return !pinnedItems.isEmpty
  }

  private var pasteStackVisible: Bool {
    if let stack = appState.history.pasteStack,
       !stack.items.isEmpty {
      return true
    }
    return false
  }

  private var topPadding: CGFloat {
    return Popup.verticalSeparatorPadding
  }

  private var bottomPadding: CGFloat {
    return showFooter
      ? Popup.verticalSeparatorPadding
      : (Popup.verticalSeparatorPadding - 1)
  }

  @ViewBuilder
  private func separator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.vertical, Popup.verticalSeparatorPadding)
  }

  var body: some View {
    let topPinsVisible = pinTo == .top && pinsVisible
    let bottomPinsVisible = pinTo == .bottom && pinsVisible

    // Everything except the search field lives in ONE scroll view: paste stack,
    // pinned items, history, and the footer (Preferences/Quit/…). They all scroll
    // together — pins are NOT fixed at the top; scrolling the list moves them out
    // of view with it, and the footer is reached by scrolling to the bottom.
    //
    // This is safe (no freeze) because the scroll-time hover-selection storm is
    // suppressed in HoverSelectionModifier via NavigationManager.isScrolling, not
    // by keeping the list as the sole lazy scroll content.
    ScrollView {
      ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
          if let stack = appState.history.pasteStack,
             !stack.items.isEmpty {
            PasteStackView(stack: stack)
            separator()
          }

          if topPinsVisible {
            PinsView(items: pinnedItems)
            separator()
          }

          MultipleSelectionListView(items: unpinnedItems) { previous, item, next, index in
            HistoryItemView(item: item, previous: previous, next: next, index: index)
          }

          if bottomPinsVisible {
            separator()
            PinsView(items: pinnedItems)
          }

          if showFooter {
            FooterView(footer: appState.footer)
          }
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .task(id: appState.navigator.scrollTarget) {
          guard appState.navigator.scrollTarget != nil else { return }

          try? await Task.sleep(for: .milliseconds(10))
          guard !Task.isCancelled else { return }

          if let selection = appState.navigator.scrollTarget {
            proxy.scrollTo(selection)
            appState.navigator.scrollTarget = nil
          }
        }
        .onChange(of: scenePhase) {
          if scenePhase == .active {
            searchFocused = true
            appState.navigator.isKeyboardNavigating = true
            appState.navigator.select(item: appState.history.unpinnedItems.first ?? appState.history.pinnedItems.first)
          } else {
            modifierFlags.flags = []
            appState.navigator.isKeyboardNavigating = true
            appState.preview.cancelAutoOpen()
          }
        }
        // Measure the full scrollable content (pins + history + footer) so the
        // window can grow to fit it, up to the screen height.
        .background {
          GeometryReader { geo in
            Color.clear
              .task(id: appState.popup.needsResize) {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled else { return }

                if appState.popup.needsResize {
                  appState.popup.resize(height: geo.size.height)
                }
              }
          }
        }
      }
      .contentMargins(.leading, 10, for: .scrollIndicators)
    }
  }
}
