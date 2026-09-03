import DDCKit
import SwiftUI

/// Per-display, user-named snapshots — e.g. lock in a calibration tool's
/// hardware-roughed color as "sRGB calibration" for THIS monitor, independent
/// of the hardware "Color Temp" slot and of any other display's presets.
struct DisplayPresetsView: View {
  @ObservedObject var display: Display
  @EnvironmentObject var presetStore: PresetStore
  @State private var expanded = false
  @State private var isAdding = false
  @State private var newName = ""

  private var presets: [DisplayPreset] { presetStore.presets(for: display.identityKey) }

  var body: some View {
    StableDisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 6) {
        if presets.isEmpty && !isAdding {
          Text("No presets saved for this display yet.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        ForEach(presets) { preset in
          HStack {
            Button {
              presetStore.apply(preset, to: display)
            } label: {
              Text(preset.name).font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(display.isBusy)
            Spacer()
            Button {
              presetStore.delete(preset, for: display.identityKey)
            } label: {
              Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Delete preset")
          }
        }

        if isAdding {
          HStack {
            TextField("Preset name", text: $newName)
              .textFieldStyle(.roundedBorder)
              .font(.caption)
              .onSubmit(savePreset)
            Button("Save", action: savePreset)
              .disabled(trimmedName.isEmpty || display.isBusy)
          }
        } else {
          Button {
            isAdding = true
          } label: {
            Label("Save current as preset…", systemImage: "plus.circle")
              .font(.caption)
          }
          .buttonStyle(.borderless)
        }
      }
      .padding(.top, 6)
      if let error = presetStore.lastError { Text(error).font(.caption).foregroundStyle(.red) }
    } label: {
      Label("Presets", systemImage: "star")
        .font(.caption).bold()
    }
  }

  private var trimmedName: String {
    newName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func savePreset() {
    guard !trimmedName.isEmpty else { return }
    guard presetStore.save(name: trimmedName, for: display) else { return }
    newName = ""
    isAdding = false
  }
}
