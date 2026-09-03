import Combine
import CoreGraphics
import Foundation

/// UI state is confined to the main thread; hardware work belongs to DDCSession.
public final class Display: ObservableObject, Identifiable {
  public private(set) var id: CGDirectDisplayID
  public private(set) var name: String
  public let identityKey: String
  public let isBuiltin: Bool
  private let session: DDCSession
  private let settingsStore: SettingsStore?
  private let resetDelay: UInt32
  private var epoch = UUID()
  private var requests: [UInt8: UUID] = [:]
  private var confirmed: [UInt8: UInt16] = [:]
  private var refreshRequested = false
  private var colorReadbackNeeded = false
  private var persistColorReadback = false

  @Published public private(set) var features: [UInt8: Feature] = [:]
  @Published public private(set) var isAvailable: Bool
  @Published public private(set) var isProbing = false
  @Published public private(set) var isResetting = false
  @Published public private(set) var pendingCodes: Set<UInt8> = []
  @Published public private(set) var lastError: String?
  @Published public private(set) var statusMessage: String?

  public var isBusy: Bool { isProbing || isResetting || !pendingCodes.isEmpty }
  public var supportsDDC: Bool { isAvailable && !features.isEmpty }
  public var colorFeatures: [Feature] {
    features.values.filter { $0.code.isColor }.sorted { $0.id < $1.id }
  }
  public var mainFeatures: [Feature] {
    features.values.filter { !$0.code.isColor }.sorted { $0.id < $1.id }
  }
  public var confirmedSnapshot: [String: UInt16] {
    Dictionary(uniqueKeysWithValues: confirmed.map { (String($0.key), $0.value) })
  }

  init(id: CGDirectDisplayID, name: String, identityKey: String, isBuiltin: Bool,
       transport: DDCTransport?, settingsStore: SettingsStore? = nil,
       session: DDCSession? = nil, resetDelay: UInt32 = 1_200_000) {
    self.id = id
    self.name = name
    self.identityKey = identityKey
    self.isBuiltin = isBuiltin
    self.isAvailable = transport != nil
    self.session = session ?? DDCSession(transport: transport)
    self.settingsStore = settingsStore
    self.resetDelay = resetDelay
  }

  func reconnect(id: CGDirectDisplayID, name: String, transport: DDCTransport?) {
    self.id = id
    self.name = name
    session.replaceTransport(transport)
    isAvailable = transport != nil
    if isAvailable { probe() } else { disconnect() }
  }

  func disconnect() {
    epoch = UUID()
    requests.removeAll()
    session.cancelPendingWrites()
    session.replaceTransport(nil)
    isAvailable = false
    isProbing = false
    isResetting = false
    pendingCodes = []
    features = [:]
    confirmed = [:]
    refreshRequested = false
    colorReadbackNeeded = false
  }

  /// Retry detection even for existing displays. Defer refresh while the user is
  /// adjusting controls so an older read cannot replace a newer slider value.
  public func probe(restoreSavedSettings: Bool = true) {
    guard isAvailable else { return }
    guard !isBusy else { refreshRequested = true; return }
    isProbing = true
    lastError = nil
    let generation = epoch
    session.perform { s in
      var found: [UInt8: Feature] = [:]
      for vcp in VCPCode.catalog {
        guard let r = s.read(vcp.code), r.max >= 1, r.max <= 255, r.current <= r.max else { continue }
        found[vcp.code] = Feature(code: vcp, current: r.current, max: r.max)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.epoch == generation else { return }
        self.features = found
        self.confirmed = found.mapValues(\.current)
        self.isProbing = false
        if found.isEmpty { self.lastError = "The monitor did not expose any controls. Try Refresh." }
        if restoreSavedSettings { self.applySavedSettings(skipConfirmedMatches: true) }
        self.finishWork()
      }
    }
  }

  /// Optimistic sliders settle to verified readbacks. Only confirmed writes are
  /// persisted; a failed command rolls back and leaves a visible error.
  public func set(_ code: UInt8, _ value: UInt16) {
    setValue(code, value, persistRelatedColors: true)
  }

  private func setValue(_ code: UInt8, _ value: UInt16, persistRelatedColors: Bool) {
    guard isAvailable, !isProbing, !isResetting, var feature = features[code] else {
      lastError = "This control is unavailable or the monitor is busy."
      return
    }
    if pendingCodes.isEmpty { lastError = nil; statusMessage = nil }
    let requested = min(value, feature.max)
    let token = UUID()
    let generation = epoch
    requests[code] = token
    pendingCodes.insert(code)
    feature.current = requested
    features[code] = feature
    session.write(code, requested) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.epoch == generation, self.requests[code] == token else { return }
        self.requests.removeValue(forKey: code)
        self.pendingCodes.remove(code)
        switch result {
        case .confirmed(let actual):
          self.adopt(code, actual.current, persist: true)
          if code == 0x14 {
            self.colorReadbackNeeded = true
            self.persistColorReadback = persistRelatedColors
          }
        case .failed(let actual):
          self.adopt(code, actual?.current ?? self.confirmed[code] ?? feature.current, persist: false)
          if let actual {
            self.lastError = "Could not set \(feature.code.name) to \(requested): the monitor reported \(actual.current)."
          } else {
            self.lastError = "Could not verify \(feature.code.name) at \(requested): the monitor did not return a valid readback. Try Refresh."
          }
        case .superseded:
          break
        }
        self.finishWork()
      }
    }
  }

  public func applySavedSettings() { applySavedSettings(skipConfirmedMatches: false) }

  private func applySavedSettings(skipConfirmedMatches: Bool) {
    guard let saved = settingsStore?.settings(for: identityKey) else { return }
    apply(saved.values, skipConfirmedMatches: skipConfirmedMatches)
  }

  public func apply(_ values: [String: UInt16]) { apply(values, skipConfirmedMatches: false) }

  private func apply(_ values: [String: UInt16], skipConfirmedMatches: Bool) {
    // Re-selecting an already active color slot can reset its gains. After a
    // fresh probe, restore only differences. A slot change invalidates the old
    // gain readbacks, so every value in that snapshot must still be restored.
    let changesColorSlot = values["20"].flatMap { requested in
      features[0x14].map { min(requested, $0.max) != confirmed[0x14] || pendingCodes.contains(0x14) }
    } ?? false
    let codes = features.keys.sorted { ($0 == 0x14 ? -1 : Int($0)) < ($1 == 0x14 ? -1 : Int($1)) }
    for code in codes {
      guard let value = values[String(code)], let feature = features[code] else { continue }
      let requested = min(value, feature.max)
      if skipConfirmedMatches, !changesColorSlot, !pendingCodes.contains(code), confirmed[code] == requested { continue }
      setValue(code, requested, persistRelatedColors: false)
    }
  }

  public func value(for code: UInt8) -> UInt16 { features[code]?.current ?? 0 }
  public func maxValue(for code: UInt8) -> UInt16 { features[code]?.max ?? 100 }

  /// An unchanged readback can mean the monitor was already at factory defaults.
  /// Never infer failure from that alone or substitute maximum RGB gains.
  public func resetColor() {
    guard isAvailable, !isBusy, !colorFeatures.isEmpty else { return }
    let codes = colorFeatures.map(\.id)
    let before = confirmed
    let generation = epoch
    isResetting = true
    lastError = nil
    statusMessage = nil
    session.perform { s in
      let sent = s.writeOnce(VCPCode.restoreColorDefaults, 1)
      if sent { usleep(self.resetDelay) }
      let readback = Self.readColors(codes, session: s)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.epoch == generation else { return }
        for (code, value) in readback { self.adopt(code, value, persist: sent) }
        if !sent || readback.count != codes.count {
          self.lastError = "Could not confirm the color reset. Try Refresh."
        } else if codes.allSatisfy({ readback[$0] == before[$0] }) {
          self.statusMessage = "Color values are unchanged. The monitor may already be at its defaults or may not support reset."
        }
        self.isResetting = false
        self.finishWork()
      }
    }
  }

  private static func readColors(_ codes: [UInt8], session: DDCSession) -> [UInt8: UInt16] {
    var values: [UInt8: UInt16] = [:]
    for code in codes {
      if let r = session.read(code), r.max >= 1, r.max <= 255, r.current <= r.max { values[code] = r.current }
    }
    return values
  }

  private func adopt(_ code: UInt8, _ value: UInt16, persist: Bool) {
    guard var feature = features[code] else { return }
    feature.current = min(value, feature.max)
    features[code] = feature
    confirmed[code] = feature.current
    if persist { settingsStore?.update(identityKey: identityKey, code: code, value: feature.current) }
  }

  private func finishWork() {
    guard !isBusy else { return }
    if colorReadbackNeeded {
      colorReadbackNeeded = false
      isProbing = true
      let generation = epoch
      let codes = colorFeatures.map(\.id)
      let persist = persistColorReadback
      session.perform { s in
        let values = Self.readColors(codes, session: s)
        DispatchQueue.main.async { [weak self] in
          guard let self, self.epoch == generation else { return }
          for (code, value) in values { self.adopt(code, value, persist: persist) }
          if values.count != codes.count { self.lastError = "Some color values could not be read. Try Refresh." }
          self.isProbing = false
          self.finishWork()
        }
      }
    } else if refreshRequested {
      refreshRequested = false
      probe()
    }
  }
}
