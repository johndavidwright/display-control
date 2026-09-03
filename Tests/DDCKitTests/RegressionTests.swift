import Combine
import DiagnoseSupport
import Foundation
import XCTest
@testable import DDCKit

final class MockTransport: DDCTransport {
  private let lock = NSLock()
  private var values: [UInt8: DDCValue]
  private var recordedWrites: [(UInt8, UInt16)] = []
  var failReads = false
  var rejectWrites = false
  var ignoreWriteCount = 0
  var beforeRead: (() -> Void)?

  init(_ values: [UInt8: DDCValue] = [0x10: DDCValue(current: 50, max: 100)]) { self.values = values }
  var writes: [(UInt8, UInt16)] { lock.lock(); defer { lock.unlock() }; return recordedWrites }
  func read(_ code: UInt8) -> DDCValue? {
    beforeRead?()
    lock.lock(); defer { lock.unlock() }
    return failReads ? nil : values[code]
  }
  func write(_ code: UInt8, _ value: UInt16) -> Bool {
    lock.lock(); defer { lock.unlock() }
    recordedWrites.append((code, value))
    if rejectWrites { return false }
    if ignoreWriteCount > 0 { ignoreWriteCount -= 1; return true }
    // Factory reset is intentionally idempotent in this mock.
    if let previous = values[code] { values[code] = DDCValue(current: value, max: previous.max) }
    return true
  }
}

final class MockI2C: DDCI2C {
  var replies: [[UInt8]?] = []
  var reads = 0
  var packets: [[UInt8]] = []
  var acceptsWrites = true
  func write(_ packet: [UInt8]) -> Bool { packets.append(packet); return acceptsWrites }
  func read(count: Int) -> [UInt8]? {
    reads += 1
    return replies.isEmpty ? nil : replies.removeFirst()
  }
}

final class RegressionTests: XCTestCase {
  func eventually(timeout: TimeInterval = 4, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayControlTests-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  func display(_ transport: MockTransport, store: SettingsStore? = nil) -> Display {
    let session = DDCSession(transport: transport, ioTimeout: 0.2, writeThrottle: 0.01, settleDelay: 0)
    let display = Display(id: 1, name: "Mock", identityKey: "mock", isBuiltin: false,
                          transport: transport, settingsStore: store, session: session, resetDelay: 0)
    display.probe()
    eventually { !display.isBusy }
    return display
  }

  func reply(code: UInt8 = 0x10, status: UInt8 = 0) -> [UInt8] {
    var bytes: [UInt8] = [0x6E, 0x88, 0x02, status, code, 0, 0, 100, 0, 42]
    bytes.append(bytes.reduce(UInt8(0x50), ^))
    return bytes
  }

  func testReadRetriesIOFailureAndWrongControl() {
    let io = MockI2C()
    io.replies = [nil, reply(code: 0x12), reply()]
    let transport = PacketDDCTransport(io: io, sleep: { _ in })
    XCTAssertEqual(transport.read(0x10), DDCValue(current: 42, max: 100))
    XCTAssertEqual(io.reads, 3)
  }

  func testReadRejectsUnsupportedMalformedAndCorruptReplies() {
    for invalid in [reply(status: 1), Array(reply().dropLast()), [UInt8](repeating: 0, count: 11)] {
      let io = MockI2C()
      io.replies = Array(repeating: invalid, count: 5)
      XCTAssertNil(PacketDDCTransport(io: io, sleep: { _ in }).read(0x10))
    }
    for index in [0, 1, 2, 3, 4, 5] {
      var bytes = reply()
      bytes[index] = 0xFF
      bytes[10] = bytes.dropLast().reduce(UInt8(0x50), ^)
      let io = MockI2C()
      io.replies = Array(repeating: bytes, count: 5)
      XCTAssertNil(PacketDDCTransport(io: io, sleep: { _ in }).read(0x10), "field \(index)")
    }
  }

  func testFailedReadNeverReturnsZeroValueAsSuccess() {
    let io = MockI2C()
    XCTAssertNil(PacketDDCTransport(io: io, sleep: { _ in }).read(0x10))
    XCTAssertEqual(io.reads, 5)
  }

  func testWritePacketPreservesSixteenBitValueAndChecksum() {
    let io = MockI2C()
    XCTAssertTrue(PacketDDCTransport(io: io, sleep: { _ in }).write(0x10, 0x0123))
    let bytes = io.packets[0]
    XCTAssertEqual(Array(bytes.prefix(5)), [0x84, 0x03, 0x10, 0x01, 0x23])
    XCTAssertEqual(bytes.reduce(UInt8(0x6E ^ 0x51), ^), 0)
  }

  func testUnsupportedAndOutOfRangeWrites() throws {
    let transport = MockTransport()
    let directory = try temporaryDirectory()
    let store = SettingsStore(directory: directory)
    let display = display(transport, store: store)
    display.set(0x60, 1)
    XCTAssertTrue(transport.writes.isEmpty)
    XCTAssertNotNil(display.lastError)
    display.set(0x10, 150)
    eventually { !display.isBusy }
    XCTAssertEqual(transport.writes.first?.1, 100)
    XCTAssertEqual(display.value(for: 0x10), 100)
    XCTAssertEqual(store.settings(for: "mock")?.values["16"], 100)
  }

  func testRejectedWriteRollsBackAndDoesNotPersist() throws {
    let transport = MockTransport()
    let store = SettingsStore(directory: try temporaryDirectory())
    let display = display(transport, store: store)
    transport.rejectWrites = true
    display.set(0x10, 80)
    XCTAssertEqual(display.value(for: 0x10), 80)
    eventually { !display.isBusy }
    XCTAssertEqual(display.value(for: 0x10), 50)
    XCTAssertNotNil(display.lastError)
    XCTAssertNil(store.settings(for: "mock"))
  }

  func testFinalRetryIsReadBackAndConfirmed() {
    let transport = MockTransport()
    let display = display(transport)
    transport.ignoreWriteCount = 2
    display.set(0x10, 80)
    eventually { !display.isBusy }
    XCTAssertEqual(transport.writes.count, 3)
    XCTAssertEqual(display.value(for: 0x10), 80)
    XCTAssertNil(display.lastError)
  }

  func testCoalescingKeepsNewestValueAndCompletesPendingState() {
    let transport = MockTransport()
    let display = display(transport)
    for value in UInt16(51)...80 { display.set(0x10, value) }
    eventually { !display.isBusy }
    XCTAssertEqual(display.value(for: 0x10), 80)
    XCTAssertEqual(transport.writes.map(\.1), [80])
    XCTAssertTrue(display.pendingCodes.isEmpty)
  }

  func testFactoryResetDoesNotReplaceUnchangedDefaultsWithMaximum() {
    let transport = MockTransport([0x16: DDCValue(current: 90, max: 100),
                                   0x18: DDCValue(current: 95, max: 100),
                                   0x1A: DDCValue(current: 100, max: 100)])
    let display = display(transport)
    display.resetColor()
    eventually { !display.isBusy }
    XCTAssertEqual(transport.writes.map(\.0), [0x08])
    XCTAssertEqual(display.value(for: 0x16), 90)
    XCTAssertEqual(display.value(for: 0x18), 95)
    XCTAssertNil(display.lastError)
    XCTAssertNotNil(display.statusMessage)
  }

  func testPresetSelectsColorSlotBeforeWritingGains() {
    let transport = MockTransport([0x14: DDCValue(current: 5, max: 12), 0x16: DDCValue(current: 90, max: 100)])
    let display = display(transport)
    display.apply(["20": 11, "22": 65])
    eventually { !display.isBusy }
    XCTAssertEqual(transport.writes.map(\.0), [0x14, 0x16])
    XCTAssertEqual(display.value(for: 0x16), 65)
  }

  func testRefreshRetriesFailedProbeAndNotifiesParent() {
    let transport = MockTransport()
    transport.failReads = true
    let descriptor = DisplayDescriptor(id: 1, name: "Mock", identityKey: "mock", isBuiltin: false, transport: transport)
    let manager = DisplayManager(settingsStore: nil, discover: { [descriptor] })
    eventually { !manager.isBusy }
    XCTAssertTrue(manager.controllable.isEmpty)
    transport.failReads = false
    var publishedControls = false
    let subscription = manager.objectWillChange.sink { if !manager.controllable.isEmpty { publishedControls = true } }
    manager.refresh()
    eventually { !manager.isBusy && publishedControls }
    XCTAssertEqual(manager.controllable.count, 1)
    withExtendedLifetime(subscription) {}
  }

  func testReconnectReusesDisplayAndReplacesTransport() {
    let first = MockTransport()
    var descriptors = [DisplayDescriptor(id: 1, name: "Mock", identityKey: "mock", isBuiltin: false, transport: first)]
    let manager = DisplayManager(settingsStore: nil, discover: { descriptors })
    eventually { !manager.isBusy }
    let original = manager.displays[0]
    descriptors = []
    manager.refresh()
    XCTAssertFalse(original.isAvailable)
    let second = MockTransport([0x10: DDCValue(current: 75, max: 100)])
    descriptors = [DisplayDescriptor(id: 2, name: "Mock", identityKey: "mock", isBuiltin: false, transport: second)]
    manager.refresh()
    eventually { !manager.isBusy }
    XCTAssertTrue(manager.displays[0] === original)
    XCTAssertEqual(original.id, 2)
    XCTAssertEqual(original.value(for: 0x10), 75)
  }

  func testRefreshCallbacksAreDebounced() {
    var discoveries = 0
    let manager = DisplayManager(settingsStore: nil, discover: { discoveries += 1; return [] })
    for _ in 0..<10 { manager.scheduleRefresh(after: 0.02) }
    eventually { discoveries == 2 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(discoveries, 2)
  }

  func testTimeoutDoesNotOverlapReplacementAndRecoversAfterDrain() {
    let old = MockTransport()
    let gate = DispatchSemaphore(value: 0)
    let entered = expectation(description: "old worker entered")
    old.beforeRead = { entered.fulfill(); gate.wait() }
    let session = DDCSession(transport: old, ioTimeout: 0.03, writeThrottle: 0, settleDelay: 0)
    let timedOut = expectation(description: "caller timed out")
    session.perform { s in XCTAssertNil(s.read(0x10)); timedOut.fulfill() }
    wait(for: [entered, timedOut], timeout: 2)
    let replacement = MockTransport([0x10: DDCValue(current: 75, max: 100)])
    session.replaceTransport(replacement)
    let refused = expectation(description: "no overlapping replacement")
    session.perform { s in XCTAssertNil(s.read(0x10)); refused.fulfill() }
    wait(for: [refused], timeout: 2)
    gate.signal()
    var recovered = false
    eventually {
      if recovered { return true }
      session.perform { s in
        let result = s.read(0x10)
        DispatchQueue.main.async { if result?.current == 75 { recovered = true } }
      }
      return false
    }
  }

  func testConcurrentFlushCannotOverwriteNewerSettings() throws {
    let directory = try temporaryDirectory()
    let oldSaveEntered = expectation(description: "old save took snapshot")
    let releaseOldSave = DispatchSemaphore(value: 0)
    let store = SettingsStore(directory: directory) { data, url in
      let snapshot = try JSONDecoder().decode([String: DisplaySettings].self, from: data)
      if snapshot["mock"]?.values["16"] == 20 {
        oldSaveEntered.fulfill()
        releaseOldSave.wait()
      }
      try data.write(to: url, options: .atomic)
    }
    store.update(identityKey: "mock", code: 0x10, value: 20)
    let oldDone = expectation(description: "old flush")
    DispatchQueue.global().async { XCTAssertTrue(store.flush()); oldDone.fulfill() }
    wait(for: [oldSaveEntered], timeout: 2)
    store.update(identityKey: "mock", code: 0x10, value: 80)
    let newDone = expectation(description: "new flush")
    DispatchQueue.global().async { XCTAssertTrue(store.flush()); newDone.fulfill() }
    releaseOldSave.signal()
    wait(for: [oldDone, newDone], timeout: 2)
    XCTAssertEqual(SettingsStore(directory: directory).settings(for: "mock")?.values["16"], 80)
  }

  func testSaveFailureIsVisibleAndRetryable() throws {
    let directory = try temporaryDirectory()
    var fail = true
    let store = SettingsStore(directory: directory) { data, url in
      if fail { throw CocoaError(.fileWriteNoPermission) }
      try data.write(to: url, options: .atomic)
    }
    store.update(identityKey: "mock", code: 0x10, value: 80)
    XCTAssertFalse(store.flush())
    eventually { store.lastError != nil }
    fail = false
    XCTAssertTrue(store.flush())
    eventually { store.lastError == nil }
    XCTAssertEqual(SettingsStore(directory: directory).settings(for: "mock")?.values["16"], 80)
  }

  func testMalformedStoresAreNotOverwritten() throws {
    let directory = try temporaryDirectory()
    let damaged = Data("invalid-json".utf8)
    try damaged.write(to: directory.appendingPathComponent("displays.json"))
    try damaged.write(to: directory.appendingPathComponent("presets.json"))
    let settings = SettingsStore(directory: directory)
    settings.update(identityKey: "mock", code: 0x10, value: 80)
    XCTAssertFalse(settings.flush())
    XCTAssertNotNil(settings.lastError)
    let presets = PresetStore(directory: directory)
    XCTAssertFalse(presets.save(name: "Test", for: display(MockTransport())))
    XCTAssertNotNil(presets.lastError)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("displays.json")), damaged)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("presets.json")), damaged)
  }

  func testPresetRoundTripUsesConfirmedValuesAndRefusesPendingSave() throws {
    let directory = try temporaryDirectory()
    let presets = PresetStore(directory: directory)
    let display = display(MockTransport())
    display.set(0x10, 80)
    XCTAssertFalse(presets.save(name: "Pending", for: display))
    eventually { !display.isBusy }
    XCTAssertTrue(presets.save(name: "Confirmed", for: display))
    let reloaded = PresetStore(directory: directory)
    XCTAssertEqual(reloaded.presets(for: "mock").first?.values["16"], 80)
    XCTAssertTrue(reloaded.presets(for: "another-monitor").isEmpty)
  }

  func testDiagnosticArgumentsFailBeforeAnyHardwareAccess() throws {
    for args in [["set", "Dell", "10"], ["persist-set", "Dell", "10"], ["set"],
                 ["persist-check", "Dell", "bad"], ["presettest"], ["unknown"],
                 ["set", "Dell", "100", "50"], ["set", "Dell", "10", "-1"]] {
      XCTAssertThrowsError(try DiagnosticCommand(arguments: args), "\(args)")
    }
    XCTAssertEqual(try DiagnosticCommand(arguments: ["--help"]), .help)
    XCTAssertEqual(try DiagnosticCommand(arguments: []), .list)
    XCTAssertEqual(try DiagnosticCommand(arguments: ["set", "Dell", "0x10", "80"]),
                   .set(name: "Dell", code: 0x10, value: 80, persist: false))
  }

  func testFailedColorRestorePreservesSavedGainForRetry() throws {
    let store = SettingsStore(directory: try temporaryDirectory())
    store.update(identityKey: "mock", code: 0x14, value: 5)
    store.update(identityKey: "mock", code: 0x16, value: 80)
    let transport = MockTransport([0x14: DDCValue(current: 5, max: 12), 0x16: DDCValue(current: 90, max: 100)])
    transport.rejectWrites = true
    let display = display(transport, store: store)
    eventually { !display.isBusy }
    XCTAssertNotNil(display.lastError)
    XCTAssertEqual(display.value(for: 0x16), 90)
    XCTAssertEqual(store.settings(for: "mock")?.values["22"], 80)
  }

  func testDuplicateEDIDsKeepIndependentLiveConnections() {
    let first = MockTransport()
    let second = MockTransport([0x10: DDCValue(current: 75, max: 100)])
    let descriptors = [
      DisplayDescriptor(id: 1, name: "First", identityKey: "duplicate", isBuiltin: false, transport: first, connectionKey: "port-a"),
      DisplayDescriptor(id: 2, name: "Second", identityKey: "duplicate", isBuiltin: false, transport: second, connectionKey: "port-b")
    ]
    let manager = DisplayManager(settingsStore: nil, discover: { descriptors })
    eventually { !manager.isBusy }
    XCTAssertEqual(manager.displays.count, 2)
    XCTAssertFalse(manager.displays[0] === manager.displays[1])
    XCTAssertEqual(manager.displays.map { $0.value(for: 0x10) }, [50, 75])
  }

  func testDisconnectCancelsUnsentWritesBeforeReconnect() {
    let first = MockTransport()
    let display = display(first)
    display.set(0x10, 80)
    display.disconnect()
    let second = MockTransport([0x10: DDCValue(current: 75, max: 100)])
    display.reconnect(id: 2, name: "Mock", transport: second)
    eventually { !display.isBusy }
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    XCTAssertTrue(first.writes.isEmpty)
    XCTAssertTrue(second.writes.isEmpty)
    XCTAssertEqual(display.value(for: 0x10), 75)
  }

  func testLaunchRestoreDoesNotRewriteAnAlreadyMatchingCalibration() throws {
    let values: [UInt8: DDCValue] = [
      0x10: DDCValue(current: 22, max: 100), 0x14: DDCValue(current: 11, max: 11),
      0x16: DDCValue(current: 99, max: 100), 0x18: DDCValue(current: 83, max: 100),
      0x1A: DDCValue(current: 74, max: 100)
    ]
    let store = SettingsStore(directory: try temporaryDirectory())
    for (code, value) in values { store.update(identityKey: "mock", code: code, value: value.current) }
    let transport = MockTransport(values)
    let display = display(transport, store: store)
    XCTAssertTrue(transport.writes.isEmpty)
    XCTAssertEqual(display.value(for: 0x1A), 74)
    XCTAssertNil(display.lastError)
  }

  func testLaunchRestoreWritesOnlyChangedValuesWhenColorSlotMatches() throws {
    let store = SettingsStore(directory: try temporaryDirectory())
    store.update(identityKey: "mock", code: 0x14, value: 11)
    store.update(identityKey: "mock", code: 0x1A, value: 74)
    let transport = MockTransport([0x14: DDCValue(current: 11, max: 11), 0x1A: DDCValue(current: 100, max: 100)])
    let display = display(transport, store: store)
    XCTAssertEqual(transport.writes.map(\.0), [0x1A])
    XCTAssertEqual(display.value(for: 0x1A), 74)
  }

  func testLaunchRestoreStillWritesMatchingGainAfterChangingColorSlot() throws {
    let store = SettingsStore(directory: try temporaryDirectory())
    store.update(identityKey: "mock", code: 0x14, value: 11)
    store.update(identityKey: "mock", code: 0x1A, value: 74)
    let transport = MockTransport([0x14: DDCValue(current: 5, max: 11), 0x1A: DDCValue(current: 74, max: 100)])
    let display = display(transport, store: store)
    XCTAssertEqual(transport.writes.map(\.0), [0x14, 0x1A])
    XCTAssertNil(display.lastError)
  }

  func testXeneonRGBReadbacksUseExistingPercentageCalibrationUnits() {
    let raw = MockTransport([
      0x16: DDCValue(current: 252, max: 255), 0x18: DDCValue(current: 211, max: 255),
      0x1A: DDCValue(current: 188, max: 255), 0x10: DDCValue(current: 200, max: 255)
    ])
    let transport = DisplayDDCTransport(base: raw, identityKey: "0E5800ED-0000-0000-1715-0104B5221478")
    XCTAssertEqual(transport.read(0x16), DDCValue(current: 99, max: 100))
    XCTAssertEqual(transport.read(0x18), DDCValue(current: 83, max: 100))
    XCTAssertEqual(transport.read(0x1A), DDCValue(current: 74, max: 100))
    XCTAssertEqual(transport.read(0x10), DDCValue(current: 200, max: 255))
    XCTAssertTrue(transport.write(0x1A, 74))
    XCTAssertEqual(raw.writes.first?.1, 74)
  }

  func testRGBNormalizationDoesNotAffectOtherMonitorsOrPercentageReplies() {
    let raw = MockTransport([0x1A: DDCValue(current: 188, max: 255)])
    let other = DisplayDDCTransport(base: raw, identityKey: "10AC8040-0000-0000-2418-0104A53C2278")
    XCTAssertEqual(other.read(0x1A), DDCValue(current: 188, max: 255))
    let percentage = DisplayDDCTransport(base: MockTransport([0x1A: DDCValue(current: 74, max: 100)]), identityKey: "0E5800ED-test")
    XCTAssertEqual(percentage.read(0x1A), DDCValue(current: 74, max: 100))
  }

  func testRealXeneonReadbacksRestoreWithoutWritingOrReportingFalseFailure() throws {
    let identity = "0E5800ED-0000-0000-1715-0104B5221478"
    let store = SettingsStore(directory: try temporaryDirectory())
    let saved: [UInt8: UInt16] = [0x14: 11, 0x16: 99, 0x18: 83, 0x1A: 74]
    for (code, value) in saved { store.update(identityKey: identity, code: code, value: value) }
    let raw = MockTransport([
      0x14: DDCValue(current: 11, max: 11), 0x16: DDCValue(current: 252, max: 255),
      0x18: DDCValue(current: 211, max: 255), 0x1A: DDCValue(current: 188, max: 255)
    ])
    let descriptor = DisplayDescriptor(id: 1, name: "XENEON EDGE", identityKey: identity, isBuiltin: false,
                                      transport: DisplayDDCTransport(base: raw, identityKey: identity))
    let manager = DisplayManager(settingsStore: store, discover: { [descriptor] })
    eventually { !manager.isBusy }
    XCTAssertTrue(raw.writes.isEmpty)
    XCTAssertNil(manager.displays[0].lastError)
    XCTAssertEqual(manager.displays[0].value(for: 0x1A), 74)
    XCTAssertEqual(store.settings(for: identity)?.values["26"], 74)
  }

}
