import AppKit
import Combine
import CoreGraphics
import Foundation
import CDDCPrivate

struct DisplayDescriptor {
  let id: CGDirectDisplayID
  let name: String
  let identityKey: String
  let isBuiltin: Bool
  let transport: DDCTransport?
  let connectionKey: String

  init(id: CGDirectDisplayID, name: String, identityKey: String, isBuiltin: Bool,
       transport: DDCTransport?, connectionKey: String? = nil) {
    self.id = id
    self.name = name
    self.identityKey = identityKey
    self.isBuiltin = isBuiltin
    self.transport = transport
    self.connectionKey = connectionKey ?? identityKey
  }
}

/// Main-thread enumeration and observable state; per-display I/O stays off main.
public final class DisplayManager: ObservableObject {
  @Published public private(set) var displays: [Display] = []
  public let settingsStore: SettingsStore?
  private let discover: () -> [DisplayDescriptor]
  // Retain sessions across disconnects, including any syscall still in progress.
  private var knownDisplays: [String: Display] = [:]
  private var subscriptions: [AnyCancellable] = []
  private var wakeObserver: NSObjectProtocol?
  private var refreshWork: DispatchWorkItem?
  private var reconfigRegistered = false

  public convenience init(autoRestore: Bool = true) {
    self.init(settingsStore: autoRestore ? SettingsStore() : nil,
              discover: Self.discoverDisplays, observeSystem: true)
  }

  init(settingsStore: SettingsStore?, discover: @escaping () -> [DisplayDescriptor], observeSystem: Bool = false) {
    self.settingsStore = settingsStore
    self.discover = discover
    refresh()
    if observeSystem { registerCallbacks() }
  }

  deinit {
    refreshWork?.cancel()
    if reconfigRegistered {
      CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
  }

  public var controllable: [Display] { displays.filter { $0.supportsDDC } }
  public var isBusy: Bool { displays.contains { $0.isBusy } }

  public func refresh() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.refresh() }
      return
    }
    refreshWork?.cancel()
    refreshWork = nil
    let descriptors = discover()
    let present = Set(descriptors.map(\.connectionKey))
    for (key, display) in knownDisplays where !present.contains(key) { display.disconnect() }
    var result: [Display] = []
    for descriptor in descriptors {
      let display: Display
      if let existing = knownDisplays[descriptor.connectionKey] {
        display = existing
        display.reconnect(id: descriptor.id, name: descriptor.name, transport: descriptor.transport)
      } else {
        display = Display(id: descriptor.id, name: descriptor.name, identityKey: descriptor.identityKey,
                          isBuiltin: descriptor.isBuiltin, transport: descriptor.transport, settingsStore: settingsStore)
        knownDisplays[descriptor.connectionKey] = display
        display.probe()
      }
      result.append(display)
    }
    subscriptions = result.map { display in
      // Published sends before mutation; deliver on the next main-queue turn so
      // computed lists see the updated child state, including initial probing.
      display.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }
    }
    if let settingsStore {
      subscriptions.append(settingsStore.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
        self?.objectWillChange.send()
      })
    }
    displays = result
  }

  func scheduleRefresh(after delay: TimeInterval) {
    refreshWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    refreshWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { [weak manager] in manager?.scheduleRefresh(after: 0.5) }
  }

  private func registerCallbacks() {
    reconfigRegistered = CGDisplayRegisterReconfigurationCallback(
      Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque()) == .success
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.scheduleRefresh(after: 1.5) }
  }

  private static func discoverDisplays() -> [DisplayDescriptor] {
    let ids = onlineDisplays()
    let matches = Arm64DDC.getServiceMatches(displayIDs: ids)
    return ids.map { id in
      let match = matches.first { $0.displayID == id }
      let builtin = CGDisplayIsBuiltin(id) != 0
      let key = identityKey(for: id, match: match)
      let location = match?.details.ioDisplayLocation ?? ""
      // Keep connection/session identity separate from the existing on-disk
      // identity format. Duplicate EDIDs must not share one live Display.
      let connection = key + "@" + (location.isEmpty ? String(id) : location)
      let transport = builtin ? nil : match?.service.map {
        DisplayDDCTransport(base: PacketDDCTransport(io: IOAVI2C(service: $0)), identityKey: key)
      }
      return DisplayDescriptor(id: id, name: displayName(id), identityKey: key,
                               isBuiltin: builtin, transport: transport, connectionKey: connection)
    }
  }

  static func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
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

  /// Read-only matching details. Call from the main thread, like refresh().
  public static func debugDump() -> String {
    let ids = onlineDisplays()
    let matches = Arm64DDC.getServiceMatches(displayIDs: ids)
    var output = "displayIDs: \(ids)\nmatches: \(matches.count)\n"
    for match in matches {
      output += "  id=\(match.displayID) score=\(match.matchScore) service=\(match.service != nil) edid=\(match.details.edidUUID.prefix(12))\n"
    }
    return output
  }

}
