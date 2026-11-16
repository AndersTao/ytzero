import SwiftUI

/// First launch: which YT Zero server to use. Nothing is built in, so the same
/// app works for anyone's instance.
struct ServerSetupView: View {
    @Environment(AppSession.self) private var session
    @State private var address = ""
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 40) {
            Text("Connect to YT Zero")
                .font(.title)
            Text("Enter the address of your YT Zero server, for example ytzero.example.com.")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Server address", text: $address)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 900)
                .onSubmit(connect)
            Button(action: connect) {
                if checking {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .disabled(checking || address.isEmpty)
            if let message {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
        .padding(80)
    }

    private func connect() {
        guard let url = AppSession.normalisedAddress(address) else {
            message = String(localized: "That is not a valid address.")
            return
        }
        checking = true
        message = nil
        Task {
            defer { checking = false }
            do {
                try await APIClient(baseURL: url).checkHealth()
                session.useServer(url)
            } catch {
                message = String(localized: "No YT Zero server answered at that address.")
            }
        }
    }
}
