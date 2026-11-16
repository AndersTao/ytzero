import SwiftUI

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
