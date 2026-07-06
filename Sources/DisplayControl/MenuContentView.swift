import DDCKit
import SwiftUI

struct MenuContentView: View {
  @EnvironmentObject var manager: DisplayManager
  @State private var launchAtLogin = LoginItem.isEnabled

  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Display Control").font(.headline)
        Spacer()
        Button {
          manager.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Re-detect displays")
      }

      if manager.controllable.isEmpty {
        Text("No DDC-capable displays detected.")
          .foregroundStyle(.secondary)
          .font(.callout)
          .padding(.vertical, 8)
      }

      ForEach(manager.controllable) { display in
        DisplayControlsView(display: display)
        if display.id != manager.controllable.last?.id {
          Divider()
        }
      }

      Divider()

      Toggle("Launch at Login", isOn: $launchAtLogin)
        .toggleStyle(.checkbox)
        .font(.caption)
        .onChange(of: launchAtLogin) { newValue in
          LoginItem.setEnabled(newValue)
        }

      HStack {
        Text("DisplayControl \(version)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Credits") {
          if let url = URL(string: "https://github.com/MonitorControl/MonitorControl") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      }

      HStack {
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
    }
    .padding(14)
    .frame(width: 320)
  }
}
