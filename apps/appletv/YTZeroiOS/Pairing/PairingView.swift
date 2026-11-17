import SwiftUI
import UIKit

/// Sign in on this phone: the approval page opens in the browser, where the
/// server's own sign-in is, and the app picks up the session once approved.
struct PairingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var model = PairingModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)
                Text("Sign in to YT Zero")
                    .font(.title.bold())
                Text("Sign in on your server's page and approve this device. You come back here afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                content
                Spacer()
                Button("Use another server", role: .destructive) {
                    session.forgetServer()
                }
            }
            .padding(32)
        }
        .task {
            guard let client = session.client else { return }
            await model.run(client: client, deviceName: UIDevice.current.name) { token in
                session.signedIn(with: token)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .waiting(let code, let link, _):
            Text(code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            if let url = URL(string: link) {
                Button {
                    openURL(url)
                } label: {
                    Label("Sign in and approve", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
            }
            Label("Waiting for approval…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
