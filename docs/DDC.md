# DDC reference and diagnostics

[Back to DisplayControl](../README.md) · [Development](DEVELOPMENT.md)

This reference covers monitor communication, saved values, known limitations,
and the command-line diagnostic tool. Run commands from the repository root.

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

## DDC troubleshooting

DDC/CI is a fragile hardware control channel. Serialization applies within this
app, not across processes; concurrent DDC applications can interfere. Firmware,
adapters, or a wedged controller can still cause failures despite serialization.

If a monitor ignores writes or returns frozen values, try a power interruption.
USB-C panels may require unplugging/replugging the cable because the soft power
button may not reset DDC. If display enumeration itself hangs system-wide, a
reboot may be required to recover Apple's display controller.
