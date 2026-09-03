import AppKit
import Combine
import Foundation

public struct DisplaySettings: Codable {
  public var identityKey: String
  public var values: [String: UInt16] = [:]
}

/// Stores confirmed values. Cache access and complete disk saves have separate
/// locks: save serialization starts BEFORE taking a snapshot, including flush.
public final class SettingsStore: ObservableObject {
  @Published public private(set) var lastError: String?
  private let url: URL
  private let lock = NSLock()
  private let saveLock = NSLock()
  private var cache: [String: DisplaySettings] = [:]
  private var pendingSave: DispatchWorkItem?
  private var dirty = false
  private var loadFailed = false
  private var terminationObserver: NSObjectProtocol?
  private let writeData: (Data, URL) throws -> Void

  public convenience init(directory: URL? = nil) {
    self.init(directory: directory, writeData: { try $0.write(to: $1, options: .atomic) })
  }

  init(directory: URL?, writeData: @escaping (Data, URL) throws -> Void) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = directory ?? base.appendingPathComponent("DisplayControl", isDirectory: true)
    url = dir.appendingPathComponent("displays.json")
    self.writeData = writeData
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path) {
        cache = try JSONDecoder().decode([String: DisplaySettings].self, from: Data(contentsOf: url))
      }
    } catch {
      loadFailed = true
      lastError = "Saved settings could not be loaded. The existing file was left unchanged. \(error.localizedDescription)"
    }
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.flush() }
  }

  deinit {
    pendingSave?.cancel()
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
  }

  public func settings(for identityKey: String) -> DisplaySettings? {
    lock.lock(); defer { lock.unlock() }
    return cache[identityKey]
  }

  public func update(identityKey: String, code: UInt8, value: UInt16) {
    lock.lock()
    var settings = cache[identityKey] ?? DisplaySettings(identityKey: identityKey)
    guard settings.values[String(code)] != value else { lock.unlock(); return }
    settings.values[String(code)] = value
    cache[identityKey] = settings
    dirty = true
    pendingSave?.cancel()
    let work = DispatchWorkItem { [weak self] in _ = self?.performSave() }
    pendingSave = work
    lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
  }

  @discardableResult
  public func flush() -> Bool { performSave() }

  private func performSave() -> Bool {
    saveLock.lock(); defer { saveLock.unlock() }
    lock.lock()
    guard !loadFailed else { lock.unlock(); return false }
    guard dirty else { lock.unlock(); return true }
    pendingSave?.cancel()
    pendingSave = nil
    let snapshot = cache
    dirty = false
    lock.unlock()
    do {
      let data = try JSONEncoder().encode(snapshot)
      try writeData(data, url)
      publishError(nil)
      return true
    } catch {
      lock.lock(); dirty = true; lock.unlock()
      publishError("Settings could not be saved. \(error.localizedDescription)")
      return false
    }
  }

  private func publishError(_ message: String?) {
    DispatchQueue.main.async { [weak self] in self?.lastError = message }
  }
}
