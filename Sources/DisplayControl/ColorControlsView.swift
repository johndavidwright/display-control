import DDCKit
import SwiftUI

/// Collapsible hardware-color section: RGB gain (white balance), color preset,
/// and a factory-color reset. Only shows controls the display actually supports.
struct ColorControlsView: View {
  @ObservedObject var display: Display
  @State private var expanded = false

  private let gainCodes: [UInt8] = [0x16, 0x18, 0x1A]
  private let presetCode: UInt8 = 0x14

  var body: some View {
    StableDisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(gainFeatures) { feature in
          FeatureSlider(display: display, feature: feature, icon: gainIcon(feature.code.code))
        }

        if let preset = display.features[presetCode] {
          HStack(spacing: 8) {
            Image(systemName: "thermometer.medium").frame(width: 16).foregroundStyle(.secondary)
            Text("Color Temp").font(.caption)
            Spacer()
            Picker("", selection: presetBinding(preset)) {
              ForEach(1 ... max(1, Int(preset.max)), id: \.self) { v in
                Text(ColorPreset.name(for: UInt16(v))).tag(v)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.caption)
            .frame(maxWidth: 130)
            .disabled(display.isProbing || display.isResetting)
          }
        }

        Button {
          display.resetColor()
        } label: {
          Label("Reset color to factory", systemImage: "arrow.uturn.backward")
            .font(.caption)
        }
        .disabled(display.isBusy)
        .buttonStyle(.borderless)
        .padding(.top, 2)
      }
      .padding(.top, 6)
    } label: {
      Label("Color", systemImage: "paintpalette")
        .font(.caption).bold()
    }
  }

  private var gainFeatures: [Feature] {
    gainCodes.compactMap { display.features[$0] }
  }

  private func gainIcon(_ code: UInt8) -> String {
    switch code {
    case 0x16: return "r.circle"
    case 0x18: return "g.circle"
    case 0x1A: return "b.circle"
    default: return "circle"
    }
  }

  private func presetBinding(_ feature: Feature) -> Binding<Int> {
    Binding(
      get: { Int(display.value(for: presetCode)) },
      set: { display.set(presetCode, UInt16($0)) }
    )
  }
}
