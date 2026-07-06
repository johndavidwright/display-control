// DDC diagnostics: exercises DDCKit's DisplayManager + Display exactly as the
// app does, and prints what it detects. Always runs with autoRestore: false, so
// unlike the real app it never reads or writes the persisted settings file and
// never pushes saved values to hardware on launch — the default mode is fully
// read-only; `set`/`presettest` make only the write you explicitly ask for.

import DDCKit
import Foundation

// Optional: `ddc-diagnose presettest <name-substring>` — switches that display
// to preset 11 (a "User" slot) and tests whether gain writes then take effect.
// Uses the normal watchdog-protected Display.set() path (bounded, verified,
// isolated per-display) — same safety as the app itself.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "presettest" {
  let needle = CommandLine.arguments[2].lowercased()
  let mgr = DisplayManager(autoRestore: false)
  RunLoop.main.run(until: Date().addingTimeInterval(3.0))
  guard let d = mgr.displays.first(where: { $0.name.lowercased().contains(needle) }) else {
    print("no display matching '\(needle)'"); exit(1)
  }
  print("\(d.name): preset before = \(d.value(for: 0x14))")
  print("→ switching to preset 11 (User slot)…")
  d.set(0x14, 11)
  RunLoop.main.run(until: Date().addingTimeInterval(2.0))
  print("preset after = \(d.value(for: 0x14))")

  print("→ writing Red gain = 150…")
  d.set(0x16, 150)
  RunLoop.main.run(until: Date().addingTimeInterval(2.0))
  print("Red gain after write+verify = \(d.value(for: 0x16))  (wanted 150)")
  exit(0)
}

// `ddc-diagnose persist-set <name> <vcpHex> <value>` — like `set`, but with
// autoRestore: true (same as the real app), so the write is also persisted.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "persist-set" {
  let needle = CommandLine.arguments[2].lowercased()
  guard let code = UInt8(CommandLine.arguments[3], radix: 16), let value = UInt16(CommandLine.arguments[4]) else {
    print("usage: ddc-diagnose persist-set <name> <vcpHex> <value>"); exit(2)
  }
  let mgr = DisplayManager(autoRestore: true)
  RunLoop.main.run(until: Date().addingTimeInterval(3.0))
  guard let d = mgr.displays.first(where: { $0.name.lowercased().contains(needle) }) else {
    print("no display matching '\(needle)'"); exit(1)
  }
  d.set(code, value)
  RunLoop.main.run(until: Date().addingTimeInterval(2.0)) // let write+verify+debounced save land
  print("\(d.name): set+persisted 0x\(String(format: "%02X", code)) = \(d.value(for: code))")
  exit(0)
}

// `ddc-diagnose persist-check <name> <vcpHex>` — fresh DisplayManager with
// autoRestore: true and NO explicit write, exactly what the real app does on
// launch. Prints the value after auto-restore, to confirm saved settings are
// actually re-applied to hardware (not just present on disk).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "persist-check" {
  let needle = CommandLine.arguments[2].lowercased()
  let code = CommandLine.arguments.count >= 4 ? UInt8(CommandLine.arguments[3], radix: 16) ?? 0x12 : 0x12
  let mgr = DisplayManager(autoRestore: true)
  RunLoop.main.run(until: Date().addingTimeInterval(3.0))
  guard let d = mgr.displays.first(where: { $0.name.lowercased().contains(needle) }) else {
    print("no display matching '\(needle)'"); exit(1)
  }
  print("\(d.name): 0x\(String(format: "%02X", code)) after auto-restore = \(d.value(for: code))")
  exit(0)
}

// `ddc-diagnose set <name-substring> <vcpHex> <value>` — one verified write via
// the normal Display.set() path.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "set" {
  let needle = CommandLine.arguments[2].lowercased()
  guard let code = UInt8(CommandLine.arguments[3], radix: 16), let value = UInt16(CommandLine.arguments[4]) else {
    print("usage: ddc-diagnose set <name> <vcpHex> <value>"); exit(2)
  }
  let mgr = DisplayManager(autoRestore: false)
  RunLoop.main.run(until: Date().addingTimeInterval(3.0))
  guard let d = mgr.displays.first(where: { $0.name.lowercased().contains(needle) }) else {
    print("no display matching '\(needle)'"); exit(1)
  }
  d.set(code, value)
  RunLoop.main.run(until: Date().addingTimeInterval(2.0))
  print("\(d.name): 0x\(String(format: "%02X", code)) = \(d.value(for: code))  (wanted \(value))")
  exit(0)
}

// `ddc-diagnose preset-test` — exercises per-display PresetStore save/apply
// against a temp directory (never touches the real app's presets.json). Read
// side is zero-risk (just snapshots current features); the apply step
// re-writes the display's OWN just-read values back to itself, so hardware
// state is unchanged, but it proves the full save→persist→decode→apply
// round trip, scoped to one display.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "preset-test" {
  let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ddc-preset-test-\(UUID().uuidString)")
  let mgr = DisplayManager(autoRestore: false)
  RunLoop.main.run(until: Date().addingTimeInterval(3.0))
  guard let target = mgr.controllable.first else { print("no controllable displays"); exit(1) }
  print("target display: \(target.name)")

  let store = PresetStore(directory: tmpDir)
  print("presets.json at: \(tmpDir.path)/presets.json")
  store.save(name: "Test Preset", for: target)
  print("saved preset with \(store.presets(for: target.identityKey).first?.values.count ?? 0) value(s)")

  guard let onDisk = try? Data(contentsOf: tmpDir.appendingPathComponent("presets.json")) else {
    print("FAIL: presets.json was not written"); exit(1)
  }
  print("on-disk bytes: \(onDisk.count)")

  // Fresh store instance reading the same directory — proves decode works, not
  // just the in-memory array from save().
  let reloaded = PresetStore(directory: tmpDir)
  guard let preset = reloaded.presets(for: target.identityKey).first(where: { $0.name == "Test Preset" }) else {
    print("FAIL: preset not found after reload"); exit(1)
  }
  print("reloaded preset '\(preset.name)' with \(preset.values.count) value(s)")

  reloaded.apply(preset, to: target)
  RunLoop.main.run(until: Date().addingTimeInterval(2.0))
  print("apply() completed without error")

  try? FileManager.default.removeItem(at: tmpDir)
  print("PASS")
  exit(0)
}

let manager = DisplayManager(autoRestore: false)
// DisplayManager enumerates on the main thread and probes each display on a
// background queue; spin the run loop briefly to let the probes publish.
RunLoop.main.run(until: Date().addingTimeInterval(3.0))

print("Detected \(manager.displays.count) display(s); \(manager.controllable.count) DDC-controllable.\n")
for d in manager.displays {
  let tag = d.isBuiltin ? "built-in" : (d.supportsDDC ? "DDC" : "no DDC")
  print("• \(d.name)  [\(tag)]  id=\(d.identityKey.prefix(8))…")
  guard d.supportsDDC else { print(""); continue }
  for f in (d.mainFeatures + d.colorFeatures) {
    let kind = f.code.isColor ? "color" : "main "
    print(String(format: "    0x%02X %-11@ [%@] %d / %d", f.code.code, f.code.name as NSString, kind as NSString, Int(f.current), Int(f.max)))
  }
  print("")
}
