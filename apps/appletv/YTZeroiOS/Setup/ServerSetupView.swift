import SwiftUI

/// First launch: which YT Zero server to use. Nothing is built in, so the same
/// app works for anyone's instance.
struct ServerSetupView: View {
    @Environment(AppSession.self) private var session
    @State private var address = ""
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit(connect)
                } footer: {
                    Text("Enter the address of your YT Zero server, for example ytzero.example.com.")
                }
                Section {
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            if checking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(checking || address.isEmpty)
                } footer: {
                    if let message {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect to YT Zero")
        }
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
