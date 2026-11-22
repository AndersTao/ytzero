import SwiftUI

/// Server address first, then pairing, then the library.
struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            switch session.stage {
            case .needsServer:
                ServerSetupView()
            case .needsPairing:
                PairingView()
            case .ready:
                // A new library for each profile: nothing of the one before stays.
                MainTabView()
                    .id(session.generation)
            }
        }
        // Signed out, also found so at launch: nothing of the profile stays
        // on the Top Shelf.
        .onChange(of: session.stage, initial: true) { _, stage in
            if stage != .ready { TopShelfPublisher.clear() }
        }
        // Another profile: nothing of the one before shows (a child's Top
        // Shelf is not a parent's) until the new library has published its own.
        .onChange(of: session.generation) {
            TopShelfPublisher.clear()
        }
    }
}
