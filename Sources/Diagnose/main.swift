import DDCKit
import DiagnoseSupport
import Foundation

struct DiagnosticFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

func waitUntil(_ completed: () -> Bool, timeout: TimeInterval = 30) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !completed() {
    guard Date() < deadline else { throw DiagnosticFailure("Timed out waiting for the monitor.") }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
}

func target(named name: String, manager: DisplayManager) throws -> Display {
  let matches = manager.controllable.filter { $0.name.localizedCaseInsensitiveContains(name) }
  guard matches.count == 1 else {
    throw DiagnosticFailure("Expected one controllable display matching '\(name)', found \(matches.count).")
  }
  return matches[0]
}

func checkResult(_ display: Display) throws {
  try waitUntil { !display.isBusy }
  if let error = display.lastError { throw DiagnosticFailure(error) }
}

func checkedWrite(_ display: Display, code: UInt8, value: UInt16) throws -> UInt16 {
  guard let feature = display.features[code] else { throw DiagnosticFailure("This monitor does not expose the requested control.") }
  let expected = min(value, feature.max)
  display.set(code, value)
  try checkResult(display)
  guard display.value(for: code) == expected else { throw DiagnosticFailure("Monitor readback did not match the requested value.") }
  print("\(display.name): 0x\(String(format: "%02X", code)) readback = \(expected) (requested \(value))")
  return expected
}

func run(_ command: DiagnosticCommand) throws {
  if command == .help { print(DiagnosticCommand.usage); return }
  // Never restore unrelated displays or write real settings during discovery.
  let manager = DisplayManager(autoRestore: false)
  try waitUntil { !manager.isBusy }
  switch command {
  case .help:
    break
  case .list:
    print("Detected \(manager.displays.count) display(s); \(manager.controllable.count) DDC-controllable.\n")
    for display in manager.displays {
      print("• \(display.name) [\(display.isBuiltin ? "built-in" : display.supportsDDC ? "DDC" : "no DDC")]\n  id=\(display.identityKey)")
      for feature in display.mainFeatures + display.colorFeatures {
        print("  0x\(String(format: "%02X", feature.id)) \(feature.code.name): \(feature.current) / \(feature.max)")
      }
      if let error = display.lastError { print("  \(error)") }
    }
  case let .set(name, code, value, persist):
    let display = try target(named: name, manager: manager)
    let actual = try checkedWrite(display, code: code, value: value)
    if persist {
      let store = SettingsStore()
      store.update(identityKey: display.identityKey, code: code, value: actual)
      // Selecting a color slot can also change gains; persist those readbacks.
      if code == 0x14 {
        for feature in display.colorFeatures {
          store.update(identityKey: display.identityKey, code: feature.id, value: feature.current)
        }
      }
      guard store.flush() else { throw DiagnosticFailure("The hardware changed, but settings could not be saved.") }
      print("Confirmed values saved.")
    }
  case let .persistCheck(name, code):
    let display = try target(named: name, manager: manager)
    let store = SettingsStore()
    if let error = store.lastError { throw DiagnosticFailure(error) }
    guard let saved = store.settings(for: display.identityKey),
          let requested = saved.values[String(code)], let feature = display.features[code] else {
      throw DiagnosticFailure("No saved value exists for that supported control.")
    }
    display.apply(saved.values)
    try checkResult(display)
    display.probe(restoreSavedSettings: false)
    try checkResult(display)
    guard display.value(for: code) == min(requested, feature.max) else { throw DiagnosticFailure("Saved value was not restored on the monitor.") }
    print("\(display.name): confirmed restored readback = \(display.value(for: code))")
  case let .colorTest(name):
    let display = try target(named: name, manager: manager)
    guard display.features[0x14]?.max ?? 0 >= 11, display.features[0x16] != nil else {
      throw DiagnosticFailure("The display must expose User 1 and red gain.")
    }
    _ = try checkedWrite(display, code: 0x14, value: 11)
    _ = try checkedWrite(display, code: 0x16, value: 150)
  case .presetTest:
    guard let display = manager.controllable.first else { throw DiagnosticFailure("No controllable displays.") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ddc-preset-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PresetStore(directory: directory)
    guard store.save(name: "Test Preset", for: display) else { throw DiagnosticFailure(store.lastError ?? "Could not save preset.") }
    let reloaded = PresetStore(directory: directory)
    guard let preset = reloaded.presets(for: display.identityKey).first,
          preset.values == display.confirmedSnapshot else { throw DiagnosticFailure("Preset reload did not match the saved values.") }
    reloaded.apply(preset, to: display)
    try checkResult(display)
    display.probe(restoreSavedSettings: false)
    try checkResult(display)
    guard preset.values.allSatisfy({ display.confirmedSnapshot[$0.key] == $0.value }) else {
      throw DiagnosticFailure("Monitor readbacks did not match the preset.")
    }
    print("PASS: saved, reloaded, applied, and verified \(display.name)'s preset.")
  }
}

let command: DiagnosticCommand
do {
  command = try DiagnosticCommand(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
  fputs(DiagnosticCommand.usage + "\n", stderr)
  exit(2)
}
do {
  try run(command)
} catch {
  fputs("Error: \(error.localizedDescription)\n", stderr)
  exit(1)
}
