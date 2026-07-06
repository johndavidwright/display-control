import Combine
import CoreGraphics
import Foundation
import CDDCPrivate

/// One external display and its DDC-controllable features.
public final class Display: ObservableObject, Identifiable {
  public let id: CGDirectDisplayID
  public let name: String
  /// Stable identity (EDID UUID when available) for persistence across reconnects.
  public let identityKey: String
  public let isBuiltin: Bool

  let service: IOAVService?
  private let session: DDCSession?
  private let settingsStore: SettingsStore?

  @Published public private(set) var features: [UInt8: Feature] = [:]

  public var supportsDDC: Bool { service != nil && !features.isEmpty }
  public var colorFeatures: [Feature] {
    features.values.filter { $0.code.isColor }.sorted { $0.code.code < $1.code.code }
  }
  public var mainFeatures: [Feature] {
    features.values.filter { !$0.code.isColor }.sorted { $0.code.code < $1.code.code }
  }

  init(id: CGDirectDisplayID, name: String, identityKey: String, isBuiltin: Bool, service: IOAVService?, settingsStore: SettingsStore? = nil) {
    self.id = id
    self.name = name
    self.identityKey = identityKey
    self.isBuiltin = isBuiltin
    self.service = service
    self.session = service != nil ? DDCSession(service: service) : nil
    self.settingsStore = settingsStore
  }

  /// Detect supported features by attempting a read of each catalog code, on the
  /// serial session queue. Values with an implausible max (e.g. a monitor
  /// returning 0xFFFF for an unsupported control) are rejected.
  public func probe() {
    guard let session else { return }
    session.perform { [weak self] s in
      guard let self else { return }
      var found: [UInt8: Feature] = [:]
      for vcp in VCPCode.catalog {
        guard let r = s.read(vcp.code) else { continue }
        guard r.max >= 1, r.max <= 255 else { continue }
        found[vcp.code] = Feature(code: vcp, current: min(r.current, r.max), max: r.max)
      }
      DispatchQueue.main.async {
        self.features = found
        // First time we see this display's features (e.g. at launch or after a
        // true reconnect) — bring it to its last-known settings.
        self.applySavedSettings()
      }
    }
  }

  /// Optimistically update local state, enqueue the DDC write, and persist.
  public func set(_ code: UInt8, _ value: UInt16) {
    if var f = features[code] {
      f.current = min(value, f.max)
      features[code] = f
    }
    session?.write(code, value)
    settingsStore?.update(identityKey: identityKey, code: code, value: value)
  }

  /// Re-apply last-known values for every currently supported feature. Safe to
  /// call any time (e.g. on every DisplayManager refresh) — a monitor that has
  /// no saved settings yet, or already matches them, is a no-op per feature.
  public func applySavedSettings() {
    guard let saved = settingsStore?.settings(for: identityKey) else { return }
    apply(saved.values)
  }

  /// Apply a snapshot of values (e.g. a user-defined preset) to every currently
  /// supported feature the snapshot has a value for. Values are clamped to this
  /// display's own reported max, so a snapshot taken on a different-scale
  /// monitor (e.g. 0–255 gain vs. 0–100) degrades gracefully instead of
  /// overshooting. Goes through the normal set() path, so it's persisted as the
  /// new last-known state too.
  public func apply(_ values: [String: UInt16]) {
    for feature in features.values {
      guard let value = values[String(feature.code.code)] else { continue }
      set(feature.code.code, min(value, feature.max))
    }
  }

  public func value(for code: UInt8) -> UInt16 { features[code]?.current ?? 0 }
  public func maxValue(for code: UInt8) -> UInt16 { features[code]?.max ?? 100 }

  /// Reset color. Tries the monitor's own factory-color reset (VCP 0x08); if the
  /// gains actually move, adopt the reported factory values. If the monitor
  /// ignores 0x08 (some do), fall back to a deterministic neutral white balance
  /// (every RGB gain at max = equal channels = no color cast). Either way the
  /// sliders end up reflecting the real state.
  public func resetColor() {
    guard let session else { return }
    let gainCodes = [UInt8(0x16), 0x18, 0x1A].filter { features[$0] != nil }
    let colorCodes = features.values.filter { $0.code.isColor }.map { $0.code.code }
    guard !gainCodes.isEmpty else { return }
    let before = gainCodes.reduce(into: [UInt8: UInt16]()) { $0[$1] = features[$1]?.current ?? 0 }

    // Runs on the serial session queue → never overlaps slider writes/probes.
    session.perform { [weak self] s in
      guard let self else { return }
      s.writeOnce(VCPCode.restoreColorDefaults, 1)
      usleep(1_200_000) // give the monitor time to apply the reset

      var readback: [UInt8: UInt16] = [:]
      for code in colorCodes {
        if let r = s.read(code) { readback[code] = r.current }
      }
      let honored = gainCodes.contains { readback[$0] != nil && readback[$0] != before[$0] }

      DispatchQueue.main.async {
        if honored {
          // Adopt whatever the monitor reports post-reset.
          for code in colorCodes {
            guard let v = readback[code], var f = self.features[code] else { continue }
            f.current = min(v, f.max)
            self.features[code] = f
            self.settingsStore?.update(identityKey: self.identityKey, code: code, value: f.current)
          }
        } else {
          // Monitor ignores 0x08 → neutral white balance via the normal write path.
          for code in gainCodes {
            guard let f = self.features[code] else { continue }
            self.set(code, f.max)
          }
        }
      }
    }
  }
}
