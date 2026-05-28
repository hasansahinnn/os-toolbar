import Defaults
import SwiftUI

@Observable
class Footer: ItemsContainer {
  var items: [FooterItem] = []

  var selectedItem: FooterItem? {
    willSet {
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  var suppressClearAlert = Binding<Bool>(
    get: { Defaults[.suppressClearAlert] },
    set: { Defaults[.suppressClearAlert] = $0 }
  )

  private var showFooter: Bool {
    return Defaults[.showFooter]
  }
  var containerVisible: Bool {
    return showFooter
  }

  init() { // swiftlint:disable:this function_body_length
    items = [
      FooterItem(
        title: "clear",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option])],
        help: "clear_tooltip",
        confirmation: .init(
          message: "clear_alert_message",
          comment: "clear_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel"
        ),
        suppressConfirmation: suppressClearAlert
      ) {
        Task { @MainActor in
          AppState.shared.history.clear()
        }
      },
      FooterItem(
        title: "clear_all",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option, .shift])],
        help: "clear_all_tooltip",
        confirmation: .init(
          message: "clear_alert_message",
          comment: "clear_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel"
        ),
        suppressConfirmation: suppressClearAlert
      ) {
        Task { @MainActor in
          AppState.shared.history.clearAll()
        }
      },
      FooterItem(
        title: "Take a Screenshot",
        help: "Capture a screenshot (⌘⇧X)"
      ) {
        Task { @MainActor in
          // Hide the popup so it isn't part of the screenshot, then capture.
          AppState.shared.appDelegate?.panel.orderOut(nil)
          AppState.shared.popup.reset()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ScreenshotController.shared.capture()
          }
        }
      },
      FooterItem(
        title: "preferences",
        shortcuts: [KeyShortcut(key: .comma)]
      ) {
        Task { @MainActor in
          AppState.shared.openPreferences()
        }
      },
      FooterItem(
        title: "about",
        help: "about_tooltip"
      ) {
        AppState.shared.openAbout()
      },
      FooterItem(
        title: "quit",
        shortcuts: [KeyShortcut(key: .q)],
        help: "quit_tooltip"
      ) {
        AppState.shared.quit()
      }
    ]
  }
}
