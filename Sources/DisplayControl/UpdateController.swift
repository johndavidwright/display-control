import AppKit
import Combine
import Sparkle

/// One updater for the app's lifetime, using the same Sparkle interface as F1 Live.
@MainActor
final class UpdateController: ObservableObject {
  private let controller: SPUStandardUpdaterController
  private var observations: [NSKeyValueObservation] = []

  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var automaticallyChecksForUpdates = false
  @Published private(set) var automaticallyDownloadsUpdates = false
  @Published private(set) var allowsAutomaticUpdates = false

  let isAvailable: Bool

  init(startingUpdater: Bool? = nil) {
    // A swift run binary has no update feed, signing key, or app to replace.
    // Tests and previews also pass false to avoid scheduling network checks.
    isAvailable = startingUpdater ?? (Bundle.main.bundleURL.pathExtension == "app")
    controller = SPUStandardUpdaterController(
      startingUpdater: isAvailable,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    observeUpdaterState()
    refreshState()
  }

  func checkForUpdates() {
    guard isAvailable, controller.updater.canCheckForUpdates else { return }
    NSApp.activate(ignoringOtherApps: true)
    controller.checkForUpdates(nil)
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard isAvailable else { return }
    controller.updater.automaticallyChecksForUpdates = enabled
    refreshState()
  }

  func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
    guard isAvailable, controller.updater.allowsAutomaticUpdates else { return }
    controller.updater.automaticallyDownloadsUpdates = enabled
    refreshState()
  }

  private func observeUpdaterState() {
    let updater = controller.updater
    observations = [
      updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshState() }
      },
      updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshState() }
      },
      updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshState() }
      },
      updater.observe(\.allowsAutomaticUpdates, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshState() }
      },
    ]
  }

  private func refreshState() {
    canCheckForUpdates = isAvailable && controller.updater.canCheckForUpdates
    automaticallyChecksForUpdates = isAvailable && controller.updater.automaticallyChecksForUpdates
    automaticallyDownloadsUpdates = isAvailable && controller.updater.automaticallyDownloadsUpdates
    allowsAutomaticUpdates = isAvailable && controller.updater.allowsAutomaticUpdates
  }
}
