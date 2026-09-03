import DDCKit
import SwiftUI

/// Controls for a single display: main sliders + a collapsible color section.
struct DisplayControlsView: View {
  @ObservedObject var display: Display

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(display.name)
        .font(.subheadline).bold()

      ForEach(display.mainFeatures) { feature in
        FeatureSlider(display: display, feature: feature, icon: icon(for: feature.code.code))
      }

      if !display.colorFeatures.isEmpty {
        ColorControlsView(display: display)
      }

      DisplayPresetsView(display: display)
      if display.isBusy {
        Text(display.isProbing ? "Reading controls…" : "Applying changes…")
          .font(.caption2).foregroundStyle(.secondary)
      }
      if let error = display.lastError { Text(error).font(.caption).foregroundStyle(.red) }
      if let message = display.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
    }
  }

  private func icon(for code: UInt8) -> String {
    switch code {
    case 0x10: return "sun.max"
    case 0x12: return "circle.lefthalf.filled"
    case 0x62: return "speaker.wave.2"
    default: return "slider.horizontal.3"
    }
  }
}

/// A labeled slider bound to a single VCP feature, using the display's own max.
struct FeatureSlider: View {
  @ObservedObject var display: Display
  let feature: Feature
  var icon: String = "slider.horizontal.3"

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .frame(width: 16)
        .foregroundStyle(.secondary)
      Slider(value: binding, in: 0 ... Double(feature.max))
        .accessibilityLabel(feature.code.name)
        .help(feature.code.name)
        .disabled(display.isProbing || display.isResetting)
      Text("\(Int(binding.wrappedValue))")
        .font(.caption).monospacedDigit()
        .frame(width: 30, alignment: .trailing)
    }
  }

  private var binding: Binding<Double> {
    Binding(
      get: { Double(display.value(for: feature.code.code)) },
      set: { display.set(feature.code.code, UInt16($0.rounded())) }
    )
  }
}
