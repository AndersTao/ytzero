import AVFoundation
import SwiftUI

@main
struct YTZeroApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = AppSession()

    init() {
        // Playback, not ambient: sound with the ring switch off, and it keeps
        // playing in the background and in picture in picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(.white)
        }
    }
}

/// Server address first, then pairing, then the library.
struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.stage {
        case .needsServer:
            ServerSetupView()
        case .needsPairing:
            PairingView()
        case .ready:
            // A new library for each profile: nothing of the one before stays.
            SideMenuContainer()
                .id(session.generation)
        }
    }
}

/// Only for the background session that brings offline copies here: it has
/// to be there again when iOS wakes the app for transfers that ended.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = OfflineStore.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        OfflineStore.shared.backgroundCompletion = completionHandler
    }
}
