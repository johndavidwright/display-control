import Combine
import Foundation

/// A named, user-owned snapshot of ONE display's values — e.g. "sRGB
/// calibration 2026-07" after roughing in hardware color with a calibration
/// tool. Independent of any monitor's own hardware color temp (VCP 0x14):
/// that's a single vendor-defined slot; this is an arbitrary number of
/// user-named, user-controlled snapshots, scoped per display.
public struct DisplayPreset: Codable, Identifiable {
  public var id: UUID
  public var name: String
  public var values: [String: UInt16]

  public init(id: UUID = UUID(), name: String, values: [String: UInt16]) {
    self.id = id
    self.name = name
    self.values = values
  }
}

/// Persists per-display presets to `presets.json`, separate from
/// SettingsStore's last-known-state cache. Presets are never auto-applied —
/// only Save/Apply/Delete, all explicit user actions — so writes are
/// synchronous rather than debounced.
public final class PresetStore: ObservableObject {
  /// identityKey -> that display's presets, in save order.
  @Published private var byDisplay: [String: [DisplayPreset]] = [:]
  @Published public private(set) var lastError: String?
  private var loadFailed = false
  private let url: URL

  /// `directory` overrides where `presets.json` lives — used by tests/diagnostics
  /// so they never touch the real app's saved presets. Defaults to the standard
  /// Application Support location.
  public init(directory: URL? = nil) {
    let dir = directory ?? {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      return base.appendingPathComponent("DisplayControl", isDirectory: true)
    }()
    self.url = dir.appendingPathComponent("presets.json")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path) {
        byDisplay = try JSONDecoder().decode([String: [DisplayPreset]].self, from: Data(contentsOf: url))
      }
    } catch {
      loadFailed = true
      lastError = "Presets could not be loaded. The existing file was left unchanged. \(error.localizedDescription)"
    }
  }

  public func presets(for identityKey: String) -> [DisplayPreset] {
    byDisplay[identityKey] ?? []
  }

  /// Save only settled, confirmed values, and publish only after disk succeeds.
  @discardableResult
  public func save(name: String, for display: Display) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, display.supportsDDC, !display.isBusy else {
      lastError = "Wait for the monitor to finish updating, then save a named preset."
      return false
    }
    var next = byDisplay
    next[display.identityKey, default: []].append(DisplayPreset(name: trimmed, values: display.confirmedSnapshot))
    return persist(next)
  }

  @discardableResult
  public func delete(_ preset: DisplayPreset, for identityKey: String) -> Bool {
    var next = byDisplay
    next[identityKey]?.removeAll { $0.id == preset.id }
    return persist(next)
  }

  public func apply(_ preset: DisplayPreset, to display: Display) {
    display.apply(preset.values)
  }

  private func persist(_ next: [String: [DisplayPreset]]) -> Bool {
    guard !loadFailed else { return false }
    do {
      let data = try JSONEncoder().encode(next)
      try data.write(to: url, options: .atomic)
      byDisplay = next
      lastError = nil
      return true
    } catch {
      lastError = "Presets could not be saved. \(error.localizedDescription)"
      return false
    }
  }
}
