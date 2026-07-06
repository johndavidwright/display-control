import AppKit
import Combine
import CoreGraphics
import Foundation
import CDDCPrivate

/// Enumerates displays, matches each to its IOAVService, and refreshes on
/// display reconfiguration and system wake.
public final class DisplayManager: ObservableObject {
  @Published public private(set) var displays: [Display] = []

  private let settingsStore: SettingsStore?
  private var reconfigRegistered = false

  /// `autoRestore: false` disables persistence entirely (no restore-on-launch,
  /// no writes are saved) — used by diagnostic/test tools so they stay
  /// side-effect-free against the real app's saved settings and hardware.
  public init(autoRestore: Bool = true) {
    self.settingsStore = autoRestore ? SettingsStore() : nil
    self.refresh()
    self.registerCallbacks()
  }

  /// Displays that actually expose DDC controls.
  public var controllable: [Display] { displays.filter { $0.supportsDDC } }

  public func refresh() {
    // CoreGraphics display info + service matching must run on the main thread:
    // called cold on a background thread, CGDisplay*Number can return 0 (a race
    // that makes every match score 0). The slow part — per-display DDC reads — is
    // offloaded per Display below.
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.refresh() }
      return
    }

    let ids = Self.onlineDisplays()
    let matches = Arm64DDC.getServiceMatches(displayIDs: ids)
    let existing = self.displays

    var result: [Display] = []
    var toProbe: [Display] = []
    for id in ids {
      let builtin = CGDisplayIsBuiltin(id) != 0
      let match = matches.first { $0.displayID == id }
      let key = Self.identityKey(for: id, match: match)
      // Reuse an existing Display (and its writer/state) when identity matches.
      if let reused = existing.first(where: { $0.identityKey == key && $0.id == id }) {
        result.append(reused)
      } else {
        let display = Display(id: id,
                              name: Self.displayName(id),
                              identityKey: key,
                              isBuiltin: builtin,
                              service: builtin ? nil : match?.service,
                              settingsStore: settingsStore)
        result.append(display)
        toProbe.append(display)
      }
    }
    self.displays = result

    // Detect features; probe() runs on each display's serial session queue,
    // publishes its own features when done, and applies saved settings once
    // features are known. For displays we're reusing, features are already
    // known — re-apply saved settings now. This is what restores a monitor's
    // brightness/color after IT power-cycles (e.g. on wake) even though macOS
    // never dropped it from the online display list, so no new Display was
    // created above.
    for display in result where !toProbe.contains(where: { $0 === display }) {
      display.applySavedSettings()
    }
    for display in toProbe where display.service != nil {
      display.probe()
    }
  }

  // MARK: - System callbacks

  private func registerCallbacks() {
    guard !reconfigRegistered else { return }
    reconfigRegistered = true
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRegisterReconfigurationCallback({ _, _, userInfo in
      guard let userInfo else { return }
      let mgr = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
      // Coalesce the burst of callbacks a reconfiguration produces.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { mgr.refresh() }
    }, ctx)

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // Monitors often reset DDC state on power cycle; re-probe after wake.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refresh() }
    }
  }

  // MARK: - Helpers

  static func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
  }

  static func displayName(_ id: CGDirectDisplayID) -> String {
    if let dict = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?,
       let names = dict["DisplayProductName"] as? [String: String] {
      return names["en_US"] ?? names.first?.value ?? "Display \(id)"
    }
    return "Display \(id)"
  }

  static func identityKey(for id: CGDirectDisplayID, match: Arm64DDC.Match?) -> String {
    if let uuid = match?.details.edidUUID, !uuid.isEmpty { return uuid }
    return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
  }

  /// Debug helper: run enumeration + matching synchronously and describe it.
  public static func debugDump() -> String {
    let ids = onlineDisplays()
    var out = "displayIDs: \(ids)\n"
    let services = Arm64DDC.getIoregServicesForMatching()
    out += "ioreg services: \(services.count)\n"
    for s in services {
      out += "  loc=\(s.serviceLocation) location='\(s.location)' edid=\(s.edidUUID.prefix(12)) serial=\(s.serialNumber) name='\(s.productName)' service=\(s.service != nil)\n"
    }
    let matches = Arm64DDC.getServiceMatches(displayIDs: ids)
    out += "matches: \(matches.count)\n"
    for m in matches {
      out += "  id=\(m.displayID) score=\(m.matchScore) service=\(m.service != nil) edid=\(m.details.edidUUID.prefix(12))\n"
    }
    return out
  }
}
