import DDCKit
import SwiftUI

struct MenuContentView: View {
  @EnvironmentObject var manager: DisplayManager
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var loginError: String?
  @State private var loginNeedsApproval = LoginItem.needsApproval

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
        Text(manager.isBusy ? "Checking displays…" : "No DDC-capable displays detected.")
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

      if let error = manager.settingsStore?.lastError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Divider()

      Toggle("Launch at Login", isOn: Binding(
        get: { launchAtLogin },
        set: { requested in
          do {
            try LoginItem.setEnabled(requested)
            loginError = nil
          } catch {
            loginError = error.localizedDescription
          }
          launchAtLogin = LoginItem.isEnabled
          loginNeedsApproval = LoginItem.needsApproval
        }
      ))
        .toggleStyle(.checkbox)
        .font(.caption)
      if loginNeedsApproval {
        Button("Allow Launch at Login in System Settings", action: LoginItem.openSettings)
          .font(.caption)
      }
      if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }

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
    // MenuBarExtra briefly proposes its old height while resizing. Fill that
    // height and stay at the top instead of centering in it, which exposes a
    // strip above the title during collapse. The ideal height stays compact.
    .frame(maxHeight: .infinity, alignment: .top)
    // Keep an opaque backing outside the disclosure fades. The system's
    // translucent MenuBarExtra material can expose the desktop during resize.
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      launchAtLogin = LoginItem.isEnabled
      loginNeedsApproval = LoginItem.needsApproval
    }
  }
}
