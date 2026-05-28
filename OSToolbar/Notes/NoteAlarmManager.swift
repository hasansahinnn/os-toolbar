import AppKit
import Foundation

// Fires note alarms with an in-app scheduler. A menu-bar (accessory) app signed
// with a self-signed cert and launched from a dev path cannot reliably deliver
// UNUserNotificationCenter alerts, so instead we keep lightweight timers while
// the app runs and show our own floating top-right panel when an alarm is due.
@MainActor
final class NoteAlarmManager {
  static let shared = NoteAlarmManager()

  // Pending timers keyed by alarm id, so they can be cancelled/rescheduled.
  private var workItems: [UUID: DispatchWorkItem] = [:]
  private var alertWindows: [AlarmAlertWindow] = []

  func start() {
    rescheduleAll()
  }

  // MARK: - Scheduling

  func schedule(_ alarm: NoteAlarm, for note: Note) {
    schedule(alarm, noteTitle: note.title, notePath: note.directoryURL.path)
  }

  private func schedule(_ alarm: NoteAlarm, noteTitle: String, notePath: String) {
    cancel(alarm)
    guard alarm.isPending else { return }
    let delay = alarm.date.timeIntervalSinceNow
    guard delay >= 0 else { return }

    let id = alarm.id
    let title = noteTitle
    let body = alarm.title
    let item = DispatchWorkItem { [weak self] in
      self?.fire(alarmID: id, noteTitle: title, alarmTitle: body, notePath: notePath)
    }
    workItems[id] = item
    // DispatchTime tops out around 292 years; clamp huge delays just in case.
    DispatchQueue.main.asyncAfter(deadline: .now() + min(delay, 60 * 60 * 24 * 365), execute: item)
  }

  func cancel(_ alarm: NoteAlarm) {
    workItems[alarm.id]?.cancel()
    workItems[alarm.id] = nil
  }

  func reschedule(for note: Note) {
    for alarm in note.alarms {
      cancel(alarm)
      schedule(alarm, for: note)
    }
  }

  func rescheduleAll() {
    workItems.values.forEach { $0.cancel() }
    workItems.removeAll()
    for folder in NotesStore.listFolders() {
      for note in NotesStore.listNotes(in: folder) {
        for alarm in note.alarms where alarm.isPending {
          schedule(alarm, for: note)
        }
      }
    }
  }

  // MARK: - Firing

  private func fire(alarmID: UUID, noteTitle: String, alarmTitle: String, notePath: String) {
    workItems[alarmID] = nil
    NotesStore.markAlarmFired(noteDirectoryPath: notePath, alarmID: alarmID)
    // Keep the in-memory model in sync if this note is loaded.
    if let note = NotesController.shared.notes.first(where: { $0.directoryURL.path == notePath }),
       let idx = note.alarms.firstIndex(where: { $0.id == alarmID }) {
      note.alarms[idx].fired = true
    }

    NSSound(named: "Glass")?.play()
    showAlert(noteTitle: noteTitle, alarmTitle: alarmTitle, notePath: notePath)
  }

  private func showAlert(noteTitle: String, alarmTitle: String, notePath: String) {
    let index = alertWindows.count
    let window = AlarmAlertWindow(
      noteTitle: noteTitle.isEmpty ? "Note Reminder" : noteTitle,
      alarmTitle: alarmTitle,
      stackIndex: index,
      onOpen: { [weak self] in
        NotesController.shared.revealNote(atPath: notePath)
        self?.dismissAll()
      },
      onDismiss: { [weak self] window in
        self?.dismiss(window)
      }
    )
    alertWindows.append(window)
    window.present()
  }

  private func dismiss(_ window: AlarmAlertWindow) {
    window.orderOut(nil)
    alertWindows.removeAll { $0 == window }
  }

  private func dismissAll() {
    alertWindows.forEach { $0.orderOut(nil) }
    alertWindows.removeAll()
  }
}

// Floating top-right reminder panel. Shows above other apps without stealing
// focus; auto-dismisses after a while.
final class AlarmAlertWindow: NSWindow {
  private let onOpen: () -> Void
  private let onDismissHandler: (AlarmAlertWindow) -> Void

  init(
    noteTitle: String,
    alarmTitle: String,
    stackIndex: Int,
    onOpen: @escaping () -> Void,
    onDismiss: @escaping (AlarmAlertWindow) -> Void
  ) {
    self.onOpen = onOpen
    self.onDismissHandler = onDismiss

    let width: CGFloat = 320
    let height: CGFloat = alarmTitle.isEmpty ? 92 : 116
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    level = .statusBar
    hasShadow = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false

    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    root.material = .hudWindow
    root.state = .active
    root.blendingMode = .behindWindow
    root.wantsLayer = true
    root.layer?.cornerRadius = 12
    root.layer?.masksToBounds = true

    let bell = NSImageView(image: NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage())
    bell.contentTintColor = .systemOrange
    bell.translatesAutoresizingMaskIntoConstraints = false

    let titleLabel = NSTextField(labelWithString: "⏰ " + noteTitle)
    titleLabel.font = .boldSystemFont(ofSize: 13)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    let bodyLabel = NSTextField(labelWithString: alarmTitle)
    bodyLabel.font = .systemFont(ofSize: 12)
    bodyLabel.textColor = .secondaryLabelColor
    bodyLabel.lineBreakMode = .byTruncatingTail
    bodyLabel.translatesAutoresizingMaskIntoConstraints = false

    let openButton = NSButton(title: "Open", target: self, action: #selector(openTapped))
    openButton.bezelStyle = .rounded
    openButton.translatesAutoresizingMaskIntoConstraints = false

    let dismissButton = NSButton(title: "Dismiss", target: self, action: #selector(dismissTapped))
    dismissButton.bezelStyle = .rounded
    dismissButton.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(bell)
    root.addSubview(titleLabel)
    if !alarmTitle.isEmpty { root.addSubview(bodyLabel) }
    root.addSubview(openButton)
    root.addSubview(dismissButton)

    NSLayoutConstraint.activate([
      bell.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      bell.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      bell.widthAnchor.constraint(equalToConstant: 18),
      bell.heightAnchor.constraint(equalToConstant: 18),

      titleLabel.leadingAnchor.constraint(equalTo: bell.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),

      dismissButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      dismissButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
      openButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),
      openButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
    ])

    if !alarmTitle.isEmpty {
      NSLayoutConstraint.activate([
        bodyLabel.leadingAnchor.constraint(equalTo: bell.trailingAnchor, constant: 8),
        bodyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
      ])
    }

    contentView = root
    positionTopRight(stackIndex: stackIndex)
  }

  private func positionTopRight(stackIndex: Int) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let margin: CGFloat = 16
    let x = visible.maxX - frame.width - margin
    let y = visible.maxY - frame.height - margin - CGFloat(stackIndex) * (frame.height + 10)
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  func present() {
    orderFrontRegardless()
    // Auto-dismiss after 30s if untouched.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self else { return }
      self.onDismissHandler(self)
    }
  }

  @objc private func openTapped() { onOpen() }
  @objc private func dismissTapped() { onDismissHandler(self) }
}
