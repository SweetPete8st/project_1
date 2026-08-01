import FeatureUI
import SwiftUI

@main
struct ShredApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var liveActivity: LiveActivityController?

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    if liveActivity == nil {
                        liveActivity = LiveActivityController(model: model)
                    }
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be registered before any BG submit (auto-start listening window).
        AutoStartBackgroundService.shared.register()
        return true
    }
}
