import Foundation
import SwiftData

/// SwiftData container for clipboard history. Singleton on the main actor.
/// Falls back to a wiped store on schema migration failure (history is a cache,
/// not user-critical, so we'd rather start fresh than refuse to launch).
@MainActor
class Storage {
  static let shared = Storage()

  /// Live ModelContainer. Created at init; re-created from a wiped store on migration failure.
  var container: ModelContainer
  /// Main-thread context all reads/writes go through.
  var context: ModelContext { container.mainContext }
  /// On-disk size of the SQLite store, formatted (e.g. "12.3 MB"); empty if unavailable.
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "OSToolbar/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch {
      // Migration failed → wipe & retry. Clipboard history is a cache,
      // refusing to launch is worse than losing it.
      let fm = FileManager.default
      let storeDir = url.deletingLastPathComponent()
      try? fm.removeItem(at: url)
      try? fm.removeItem(at: url.appendingPathExtension("shm"))
      try? fm.removeItem(at: url.appendingPathExtension("wal"))
      try? fm.removeItem(at: storeDir.appendingPathComponent(".OSToolbar_SUPPORT", isDirectory: true))
      do {
        container = try ModelContainer(for: HistoryItem.self, configurations: config)
      } catch let retryError {
        fatalError("Cannot load database after reset: \(retryError.localizedDescription).")
      }
    }
  }
}
