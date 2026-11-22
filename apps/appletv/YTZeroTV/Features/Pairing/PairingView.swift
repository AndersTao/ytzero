import SwiftUI

/// Scan the code with a phone, sign in there and approve this Apple TV. From
/// Settings it adds another profile: whoever approves is the one added.
struct PairingView: View {
    @Environment(AppSession.self) private var session
    @State private var model = PairingModel()
    private let adding: Bool
    private let onDone: () -> Void

    init(adding: Bool = false, onDone: @escaping () -> Void = {}) {
        self.adding = adding
        self.onDone = onDone
    }

    var body: some View {
        HStack(spacing: 100) {
            qrCode
            VStack(alignment: .leading, spacing: 28) {
                (adding ? Text("Add a profile") : Text("Sign in to YT Zero"))
                    .font(.title)
                (adding
                    ? Text("Scan the QR code with the phone of the person to add, and sign in there as them.")
                    : Text("Scan the QR code with your phone, sign in and approve this Apple TV."))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                content
                if adding {
                    Button("Cancel", action: onDone)
                } else {
                    Button("Use another server", role: .destructive) {
                        session.forgetServer()
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(80)
        .task {
            guard let client = session.client else { return }
            await model.run(client: client, link: adding) { token in
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
    private var qrCode: some View {
        if case .waiting(_, let link, _) = model.state, let image = QRCode.image(for: link) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 420, height: 420)
                .padding(24)
                .background(.white, in: .rect(cornerRadius: 24))
                .accessibilityLabel("QR code for signing in")
        } else {
            RoundedRectangle(cornerRadius: 24)
                .fill(.quaternary)
                .frame(width: 468, height: 468)
                .overlay { ProgressView() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .waiting(let code, _, let address):
            Text("Or go to \(address)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 88, weight: .bold, design: .monospaced))
            Label("Waiting for approval…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
