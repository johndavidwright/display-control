# DisplayControl

A lightweight macOS **menu bar** app that auto-detects external displays with
**DDC/CI** support and adjusts their parameters — brightness, contrast, volume,
and hardware **color** (RGB gain white balance + color-temperature preset) —
capability-gated per monitor. Built for **Apple Silicon**.

## Status

Feature-complete for personal use: auto-detection, per-display sliders, named
color presets, factory/neutral color reset, persistence across relaunch/wake,
launch-at-login. See the phase checklist at the bottom.

## Requirements

- Apple Silicon Mac, macOS 13+
- Xcode (or Command Line Tools) to build

## Build & run

```bash
# Open in Xcode (native SwiftPM package):
open Package.swift        # or: xed .

# Or from the command line:
swift build -c release
./scripts/make-app.sh     # produces a double-clickable DisplayControl.app
open ./DisplayControl.app # look for the sun icon in the menu bar

# Headless, read-only diagnostics (list displays + detected features):
swift run ddc-diagnose
```

The app runs as a menu-bar **agent** (`LSUIElement` / `setActivationPolicy(.accessory)`),
so there's no Dock icon. It is **unsandboxed** (required for the private
`IOAVService` DDC path) and for **personal use** (no notarization).

## Architecture

```
DisplayControl (SwiftUI MenuBarExtra)     Sources/DisplayControl/
  └─ DisplayManager  (enumerate, match, refresh on reconfigure/wake)
       └─ Display     (per-display feature model, ObservableObject)
            └─ DDCSession   (serial, watchdog-protected DDC channel)
                 └─ Arm64DDC (IOAVService I2C + IORegistry matching)   Sources/DDCKit/
                      └─ CDDCPrivate (private symbol declarations)     Sources/CDDCPrivate/
```

- **Arm64DDC** — I2C framing, checksum, IORegistry→`IOAVService` matching.
  Adapted from [MonitorControl](https://github.com/MonitorControl/MonitorControl)
  (MIT — see `THIRD_PARTY/`). Display↔service matching uses public CoreGraphics
  vendor/product/serial instead of the private CoreDisplay dictionary.
- **DDCSession** — one serial channel per display. All I2C is serialized (never
  overlapping), each op has a caller-side timeout (watchdog), settled writes are
  verified with retry, and a stalled display is isolated so it can't back up work.
- **DisplayManager** — enumerates on the **main thread** (CoreGraphics display
  info returns 0 if called cold on a background thread → all matches fail),
  probes each display on its session queue, and refreshes on
  `CGDisplayRegisterReconfigurationCallback` and `NSWorkspace.didWakeNotification`.
- **SettingsStore** — persists each display's last-known feature values by EDID
  identity to `~/Library/Application Support/DisplayControl/displays.json`
  (debounced writes, flushed on quit). Re-applied on every `DisplayManager`
  refresh — not just on (re)connect — because monitors often reset their own
  DDC state on their own power cycle even when macOS never reports them
  offline. Diagnostic tools run with `autoRestore: false` so they stay
  side-effect-free against the real settings file and hardware.

## Detected VCP features

Rendered only if the monitor answers a read and reports a plausible max (1–255):
Brightness `0x10`, Contrast `0x12`, Volume `0x62`, RGB gain `0x16/0x18/0x1A`,
Color preset `0x14`. "Reset color to factory" tries `0x08` (restore factory
color) and, if the monitor ignores it, falls back to neutral gains (equal = max).

Color preset (`0x14`, labeled **"Color Temp"** in the UI) values follow the
VESA MCCS convention (sRGB, fixed Kelvin points, User 1–3) — see
`ColorPreset.names` in `VCPCode.swift`. RGB gain writes are only honored by some
monitors while a **User** slot is selected; a fixed Kelvin preset can silently
lock the gain sliders out (monitor firmware behavior, not a bug).

## Presets (per-display, user-named)

Separate from the hardware "Color Temp" above: each display has its own
**Presets** section (a `DisclosureGroup` under that display's controls) for
saving that *one monitor's* current values under a name you choose — e.g. lock
in a calibration tool's hardware-roughed color as "sRGB calibration 2026-07"
for that specific display, independent of every other display's presets and of
the monitor's own hardware Color Temp slot.

Stored in `~/Library/Application Support/DisplayControl/presets.json` as
`[identityKey: [DisplayPreset]]` — each display keeps its own ordered list.
Separate file from `SettingsStore`'s last-known-state cache, since presets are
explicit/user-owned and never auto-applied (unlike `SettingsStore`'s
restore-on-launch/wake).

Applying a preset goes through the normal `Display.set()` path (`Display.apply(_
values:)`), so it's also persisted as the new last-known state — e.g. if you
apply a calibration preset and the Mac later sleeps/wakes, it restores to that
preset's values, not whatever was set before you picked it.

`PresetStore` takes an optional `directory:` override for the same reason
`DisplayManager` takes `autoRestore:` — so diagnostics never touch the real
file. `ddc-diagnose preset-test` exercises the full save → disk → reload →
apply round trip, scoped to one display, against a temp directory.

**Input source switching (`0x60`) is intentionally not implemented.** All three
displays this was built against report an unreliable `max` for that opcode (not
a real contiguous range), and switching a monitor to an input with nothing
plugged in typically drops it from macOS's online display list until it's
switched back at the monitor's own controls — not recoverable remotely. Revisit
only if you have a monitor with multiple active inputs.

## DDC troubleshooting (important)

DDC/CI is a fragile control channel. Two rules keep it healthy:

1. **Only one process should talk to DDC at a time.** Don't run `ddc-diagnose`
   or the probe while `DisplayControl.app` is running — cross-process concurrent
   I2C can wedge a monitor's controller.
2. **A wedged controller needs a power interruption, not a retry.**
   - Symptom: writes are ACK'd but ignored, or read-backs are wrong/frozen.
   - A single monitor: power-cycle it (USB-C panels like the XENEON EDGE need a
     **cable unplug/replug** — the soft power button often doesn't reset DDC).
   - If display *enumeration itself* hangs (even `ddc-diagnose` produces no
     output), the Apple-Silicon **DCP is wedged system-wide** → **reboot**.

The app itself serializes all DDC I/O, so in normal use it will not wedge a
display. The failure modes above come from concurrent access (multiple processes)
or inherently flaky monitor firmware.

## Phase checklist

- [x] Phase 1 — DDC core (read/write proven on hardware)
- [x] Phase 0 — Xcode + SwiftPM scaffold
- [x] Phase 2 — auto-detection (EDID identity, capability probe)
- [x] Phase 3 — feature model incl. color
- [x] Phase 4 — menu bar UI (+ serialized/watchdog DDC channel)
- [x] Phase 5 — persistence + restore on launch/reconnect/wake
- [x] Phase 6 — polish (launch-at-login, credits/attribution). Input-source
      switching deliberately skipped — see "Detected VCP features" above.

## Credits

DDC engine adapted from MonitorControl (MIT). See `THIRD_PARTY/MonitorControl-LICENSE.txt`.
