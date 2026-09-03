# Development

[Back to DisplayControl](../README.md) · [DDC reference](DDC.md) · [Releasing](RELEASING.md)

Run the commands below from the repository root.

## Build and run

Requires Xcode or the Command Line Tools.

```bash
swift test
./scripts/make-app.sh
open ./DisplayControl.app

# Build a separate bundle without replacing the existing app:
./scripts/make-app.sh release /absolute/path/to/DisplayControl.app

# Open the package in Xcode:
xed .
```

The app runs as a menu-bar agent (`LSUIElement`) without a Dock icon. It uses
private IOAVService APIs, is unsandboxed, and is ad-hoc signed for personal use.
It is not notarized. The packaging script verifies the signature before
replacing the destination bundle.

App metadata and the version live in `Resources/Info.plist`. The packaging
script embeds Sparkle.framework and its helpers, preserves their signatures,
and verifies the entire app bundle. It includes the DisplayControl, MonitorControl,
and Sparkle license notices in `Contents/Resources`.

### Updater behavior

Sparkle asks about automatic checks on the second launch unless the user has
already chosen a preference. Automatic installation is opt-in. Both the archive
and feed are signed, and downloads are verified before extraction.

Update preferences are stored by Sparkle, separately from monitor settings.
Updates are disabled for a bare executable launched with `swift run`.

## Architecture

```text
DisplayControl (SwiftUI MenuBarExtra)
  DisplayManager  — enumerate, debounce callbacks, observe child state
    Display       — main-thread UI state, confirmed values, reset/restore
      DDCSession  — coalescing, ordered writes, verification, timeout handling
        DDCTransport / PacketDDCTransport — validated DDC/CI packets
          DDCI2C / IOAVI2C — private IOAVService calls
  SettingsStore / PresetStore — disk persistence
  UpdateController / Sparkle — update checks, preferences, and installation

Arm64DDC       — IORegistry traversal and display/service matching
CDDCPrivate    — private macOS symbol declarations
DiagnoseSupport — argument parsing without hardware access
```

Every session has one scheduler and one serial worker. A timeout returns control
to the scheduler but cannot interrupt a stuck kernel call. While that call is
active, the session refuses new I/O, even if its service handle is replaced.
Completion alone releases the worker slot, avoiding timeout/completion races.
CoreGraphics enumeration and service creation still run on the main thread and
are not covered by the I/O watchdog.

## Verification

`swift test` uses mock transports and temporary files. It does not access
monitors, real saved settings, or login registration. Coverage includes invalid
DDC replies, retries, rejected/clamped writes, coalescing, color-reset
idempotence, color ordering, observation, reconnects, callback debouncing,
timeout recovery, concurrent saves, persistence failures, and argument parsing.

For a live acceptance check, with only this DDC app running:

1. Open the menu during discovery and confirm controls appear when probing ends.
2. Adjust brightness and a User-slot RGB gain; check the monitor and save a preset.
3. Apply a different color slot, then restore the preset and confirm the readbacks.
4. Reset color twice; the second reset must not force gains to their maximum.
5. Sleep/wake and disconnect/reconnect a monitor; verify detection and restoration.
6. Check Launch at Login in System Settings, including the approval-required state.
7. Expand and collapse Color and Presets, including rapid clicks. Confirm the
   title stays fixed and the panel does not flash or leave an empty section.
8. Open Updates and check for updates. Verify that Sparkle opens its standard
   dialog, reports the installed version correctly, and preserves preferences.
