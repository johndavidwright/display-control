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
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.url = dir.appendingPathComponent("presets.json")
    self.load()
  }

  public func presets(for identityKey: String) -> [DisplayPreset] {
    byDisplay[identityKey] ?? []
  }

  /// Snapshot a display's live current values into a new named preset.
  public func save(name: String, for display: Display) {
    var values: [String: UInt16] = [:]
    for f in display.features.values { values[String(f.code.code)] = f.current }
    byDisplay[display.identityKey, default: []].append(DisplayPreset(name: name, values: values))
    persist()
  }

  public func delete(_ preset: DisplayPreset, for identityKey: String) {
    byDisplay[identityKey]?.removeAll { $0.id == preset.id }
    persist()
  }

  /// Apply a preset to the display it was scoped to. Values are clamped to the
  /// display's own reported max per feature (see Display.apply).
  public func apply(_ preset: DisplayPreset, to display: Display) {
    display.apply(preset.values)
  }

  private func load() {
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: [DisplayPreset]].self, from: data) else { return }
    byDisplay = decoded
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(byDisplay) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
