import AppKit
import DDCKit
import SwiftUI

/// Makes the process a menu-bar agent (no Dock icon) even without a bundle
/// Info.plist. The packaged .app also sets LSUIElement (see scripts/make-app.sh).
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}

@main
struct DisplayControlApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var manager = DisplayManager()
  @StateObject private var presetStore = PresetStore()
  @StateObject private var updates = UpdateController()

  var body: some Scene {
    MenuBarExtra("DisplayControl", systemImage: "sun.max.circle") {
      MenuContentView()
        .environmentObject(manager)
        .environmentObject(presetStore)
        .environmentObject(updates)
    }
    .menuBarExtraStyle(.window)
  }
}
