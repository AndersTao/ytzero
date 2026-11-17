import AVFoundation
import SwiftUI

@main
struct YTZeroApp: App {
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
            HomeView()
        }
    }
}
