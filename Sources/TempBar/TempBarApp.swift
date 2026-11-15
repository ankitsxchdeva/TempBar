import SwiftUI

@main
struct TempBarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Text(model.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        // Its own window: the menu bar panel never shrinks after showing taller content.
        Window("TempBar Settings", id: SettingsView.windowID) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.isConfigured ? .suppressed : .presented)
    }
}
