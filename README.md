# DisplayControl

A lightweight macOS **menu bar** app for external displays with **DDC/CI**
support. Adjust brightness, contrast, volume, RGB gains, and the monitor's color
preset. Controls appear only when the monitor returns a valid, plausible value.
Built for **Apple Silicon**, macOS **13+**, using SwiftUI and Swift Package Manager.

## Install and update

Download the app ZIP from [GitHub Releases](https://github.com/johndavidwright/display-control/releases/latest),
unzip it, and move DisplayControl.app to Applications. Quit any older copy before
opening the new one. Versions through 0.2.5 need this manual installation once.

The **Updates** section offers Check for Updates, automatic checks, and optional
automatic download and installation, using [Sparkle](https://sparkle-project.org/)
as in F1 Live. Sparkle asks about automatic checks on the second launch unless
you have already chosen a preference. Automatic installation is opt-in.
Both the update archive and feed are signed; downloads are verified before
extraction. Update preferences are stored by Sparkle, separately from monitor
settings. Updates are disabled for a bare executable launched with swift run.

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
and verifies the entire app bundle.

## Controls and saved values

- Main controls: brightness `0x10`, contrast `0x12`, volume `0x62`.
- Color controls: RGB gain `0x16/0x18/0x1A`, color preset `0x14`.
- Factory color reset: action `0x08`.

Color and Presets sections use a short fade and caret rotation. The menu stays
anchored at the top as it changes height, preventing a flash above the title
when a section collapses.

Sliders update immediately while the hardware write runs. Each settled write is
read back, with bounded retries if the monitor ignored it. Failed writes show an
error and return the slider to the readback or last confirmed value. Outgoing
values are clamped to the feature's maximum; unavailable controls are rejected.
Only confirmed writes are saved.

The XENEON EDGE (EDID vendor/product `0E5800ED`) uses different RGB scales:
its DDC writes accept 0–100, while readbacks report 0–255. The app normalizes
those RGB readbacks to percentages, matching the existing saved calibration
values. This conversion is limited to that model's RGB controls; other monitors
retain their reported scale.

The monitor's Color Temp choices use the MCCS names in `ColorPreset.names`.
Some monitors accept RGB writes only in a User color slot. Selecting a color slot
can itself change the gains, so its readbacks are refreshed. A saved snapshot
selects and verifies its color slot before writing the gains. Reported preset
ranges remain monitor-dependent; a value within the reported range can still be
rejected by firmware, in which case the app reports the failed verification.

**Reset color to factory** sends the monitor's factory-reset command and reads
its color values back. Unchanged values can mean the monitor is already at its
defaults or does not support the command. The app reports that ambiguity and
never substitutes maximum RGB gains for factory values.

Input source switching (`0x60`) remains intentionally unsupported: the monitors
used for this project report unreliable ranges, and switching to an inactive
input can remove a display from macOS until it is switched back physically.

## Persistence and named presets

Files live in `~/Library/Application Support/DisplayControl/`:

- `displays.json`: confirmed last-known values, keyed by display identity.
  Saves are debounced and serialized; quitting flushes completed changes.
  An in-flight hardware write has to finish before its value can be saved.
- `presets.json`: per-display named snapshots, explicitly saved/applied/deleted.
  Saving waits for hardware operations to settle and snapshots confirmed values.
  Failed file operations leave the previous preset list intact.

Saved settings are restored after detection, refresh, and wake. After probing,
values that already match are left alone, including the active color slot.
Changing the color slot still restores all snapshot values because selecting a
slot can change the gains. Existing displays
are re-probed, so an initial failed probe can recover without restarting the app.
Fresh service handles reuse the display's serial worker, including across
reconnects. Applying a named preset makes its confirmed writes the new saved
state. Failed restore writes leave their previous saved values available for a
later retry.

Both stores report load/save errors. A malformed existing file is preserved and
writes to it are blocked for that run. Repair or restore the file, then relaunch
the app. Tests can inject a temporary directory for either store.

Displays normally use their EDID UUID as identity, falling back to public
vendor/model/serial information. Live display objects also use the registry connection path to keep their
sessions separate. The existing on-disk identity format is unchanged: identical
monitors with missing or duplicated EDID serials can still share saved settings
and should not be assumed to have independent calibrations.

## Diagnostics

Quit DisplayControl and other DDC apps before running hardware diagnostics.
The default command reads controls without restoring or saving settings. Help
and invalid arguments are handled before any display or settings access.

```bash
swift run ddc-diagnose --help
swift run ddc-diagnose

# Explicit hardware writes; names must match exactly one controllable monitor:
swift run ddc-diagnose set 'Dell' 10 50
swift run ddc-diagnose persist-set 'Dell' 10 50

# Restore the selected monitor's saved values and check contrast (hex 12):
swift run ddc-diagnose persist-check 'Dell' 12

# Select User 1, then write red gain 150 (clamped to the monitor's maximum):
swift run ddc-diagnose presettest 'Dell'

# Save/reload a preset in a temp directory, apply it, verify hardware readbacks:
swift run ddc-diagnose preset-test
```

`persist-set` saves only the selected confirmed control (and associated color
readbacks when changing the color slot). `persist-check` explicitly restores the
selected monitor. Neither restores other monitors during discovery.
`preset-test` does write hardware and is not a read-only test.

Commands wait for operations to complete with a deadline. They report confirmed
readbacks and exit nonzero on failure. Exit codes: `0` success, `1` operational
failure, `2` invalid arguments. They do not infer success from an optimistic
slider value or a fixed sleep.

## Architecture

```text
DisplayControl (SwiftUI MenuBarExtra)
  DisplayManager  — enumerate, debounce callbacks, observe child state
    Display       — main-thread UI state, confirmed values, reset/restore
      DDCSession  — coalescing, ordered writes, verification, timeout handling
        DDCTransport / PacketDDCTransport — validated DDC/CI packets
          DDCI2C / IOAVI2C — private IOAVService calls
  SettingsStore / PresetStore — disk persistence

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

## Publishing releases

The Build and Test workflow runs mock-based tests and verifies packaging on
pushes to main and pull requests. Pushing a `v*` tag runs the release workflow:
tests, Apple Silicon packaging, EdDSA signing, and GitHub Release publication.

1. Update both version fields in `Resources/Info.plist` to the same new version.
2. Update `RELEASE_NOTES.md` and commit the changes to main.
3. Create and push the matching tag (for example, `v0.3.1`).
4. Confirm Publish Release succeeds before announcing the release.

The release contains an app ZIP, its SHA-256 checksum, and the signed
`appcast.xml` consumed by installed copies of DisplayControl. The stable feed
address is the latest GitHub Release's `appcast.xml` asset. Keep the repository
and release downloads public so app users do not need GitHub credentials.

For a local release build:

```bash
./scripts/package-release.sh
./scripts/generate-appcast.sh
```

Local signing uses the `com.jdw.DisplayControl` account created by Sparkle's
`generate_keys` tool in the login Keychain. CI uses the encrypted repository
secret `SPARKLE_PRIVATE_KEY`, passed to the signer through standard input. The
public counterpart is `SUPublicEDKey` in Info.plist. Keep the private key backed
up securely and out of Git: replacing it without a supported key migration
prevents installed copies from accepting future updates.

## DDC troubleshooting

DDC/CI is a fragile hardware control channel. Serialization applies within this
app, not across processes; concurrent DDC applications can interfere. Firmware,
adapters, or a wedged controller can still cause failures despite serialization.

If a monitor ignores writes or returns frozen values, try a power interruption.
USB-C panels may require unplugging/replugging the cable because the soft power
button may not reset DDC. If display enumeration itself hangs system-wide, a
reboot may be required to recover Apple's display controller.

## Credits

IOAVService framing, timing, and IORegistry traversal are adapted from
[MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT).
See `THIRD_PARTY/MonitorControl-LICENSE.txt`.

In-app updates use Sparkle 2.9.6. The packaged app includes both Sparkle's license
and the MonitorControl license in Contents/Resources.
