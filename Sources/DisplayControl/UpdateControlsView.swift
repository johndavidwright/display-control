import SwiftUI

struct UpdateControlsView: View {
  @EnvironmentObject private var updates: UpdateController
  @State private var expanded = false

  var body: some View {
    StableDisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Automatically check for updates", isOn: Binding(
          get: { updates.automaticallyChecksForUpdates },
          set: { updates.setAutomaticallyChecksForUpdates($0) }
        ))
        .disabled(!updates.isAvailable)

        Toggle("Automatically download and install", isOn: Binding(
          get: { updates.automaticallyDownloadsUpdates },
          set: { updates.setAutomaticallyDownloadsUpdates($0) }
        ))
        .disabled(!updates.allowsAutomaticUpdates)

        Button("Check for Updates…", action: updates.checkForUpdates)
          .buttonStyle(.borderless)
          .disabled(!updates.canCheckForUpdates)

        if !updates.isAvailable {
          Text("Run the installed app to use updates.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.checkbox)
      .font(.caption)
      .padding(.top, 6)
    } label: {
      Label("Updates", systemImage: "arrow.down.circle")
        .font(.caption).bold()
    }
  }
}
