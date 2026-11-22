import SwiftUI
import UIKit

/// Sign in on this phone: the approval page opens in the browser, where the
/// server's own sign-in is, and the app picks up the session once approved.
/// From Settings it adds another profile: whoever approves is the one added,
/// usually on their own phone with the QR code.
struct PairingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var model = PairingModel()
    private let adding: Bool
    private let onDone: () -> Void

    init(adding: Bool = false, onDone: @escaping () -> Void = {}) {
        self.adding = adding
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                if adding, case .waiting(_, let link, _) = model.state, let image = QRCode.image(for: link) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .padding(14)
                        .background(.white, in: .rect(cornerRadius: 16))
                        .accessibilityLabel("QR code for signing in")
                } else {
                    Image(systemName: adding ? "person.badge.plus" : "play.rectangle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)
                }
                (adding ? Text("Add a profile") : Text("Sign in to YT Zero"))
                    .font(.title.bold())
                (adding
                    ? Text("Scan the code with the phone of the person to add and sign in there as them, or approve here if this phone is signed in as them.")
                    : Text("Sign in on your server's page and approve this device. You come back here afterwards."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                content
                Spacer()
                if adding {
                    Button("Cancel", action: onDone)
                } else {
                    Button("Use another server", role: .destructive) {
                        session.forgetServer()
                    }
                }
            }
            .padding(32)
        }
        .task {
            guard let client = session.client else { return }
            await model.run(client: client, deviceName: UIDevice.current.name, link: adding) { token in
                if adding {
                    session.added(token: token)
                    onDone()
                } else {
                    session.signedIn(with: token)
                }
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
