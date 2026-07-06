import AppKit
import Foundation

public struct DisplaySettings: Codable {
  public var identityKey: String
  public var values: [String: UInt16] = [:]
}

/// Persists each display's last-known feature values by EDID identity, so they
/// can be re-applied after relaunch, reconnect, or wake. Monitors frequently
/// reset their own internal DDC state (brightness/contrast/gains) on their own
/// power cycle even when macOS never reports the display as offline, so restore
/// is driven by DisplayManager on every refresh — not just on (re)connect.
///
/// Writes are debounced (a slider drag shouldn't hit disk on every tick) and
/// flushed immediately on app termination so the last change isn't lost.
public final class SettingsStore {
  private let url: URL
  private let lock = NSLock()
  private var cache: [String: DisplaySettings] = [:]
  private var saveScheduled = false

  public init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("DisplayControl", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.url = dir.appendingPathComponent("displays.json")
    self.load()

    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      self?.flush()
    }
  }

  public func settings(for identityKey: String) -> DisplaySettings? {
    lock.lock(); defer { lock.unlock() }
    return cache[identityKey]
  }

  public func update(identityKey: String, code: UInt8, value: UInt16) {
    lock.lock()
    var s = cache[identityKey] ?? DisplaySettings(identityKey: identityKey)
    s.values[String(code)] = value
    cache[identityKey] = s
    let schedule = !saveScheduled
    if schedule { saveScheduled = true }
    lock.unlock()
    if schedule {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.performSave() }
    }
  }

  public func flush() { performSave() }

  private func load() {
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: DisplaySettings].self, from: data) else { return }
    lock.lock(); cache = decoded; lock.unlock()
  }

  private func performSave() {
    lock.lock()
    saveScheduled = false
    let snapshot = cache
    lock.unlock()
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
