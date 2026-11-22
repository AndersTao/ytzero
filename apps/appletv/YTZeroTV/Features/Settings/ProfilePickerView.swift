import SwiftUI

/// "Who is watching?" on the whole screen, as the Apple TV's own apps ask
/// it: a row of large round pictures that lift when the remote is on them,
/// with Add profile at the end and Sign out below. A long press on a profile
/// removes it from this Apple TV. Leaving a child profile asks for the child
/// lock PIN, as the list it replaces did.
struct ProfilePickerView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let model: ProfilesModel
    @State private var adding = false
    @State private var pin = ""
    @FocusState private var focused: String?

    private static let avatarSize: CGFloat = 220
    private static let addID = "add-profile"

    var body: some View {
        VStack(spacing: 72) {
            Text("Who is watching?")
                .font(.title.bold())
            if let message = model.message {
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 64) {
                    ForEach(model.choices) { choice in
                        tile(for: choice)
                    }
                    if model.hasLoaded && !model.switchesInSession {
                        addTile
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
                // Centred while the row is narrower than the screen.
                .frame(minWidth: 1920 - 160)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .focusSection()

            Button("Sign out", role: .destructive) {
                let client = session.client
                session.signOut()
                Task { await client?.signOut() }
                dismiss()
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            if !model.hasLoaded && model.message == nil { ProgressView() }
        }
        .defaultFocus($focused, model.choices.first(where: \.isActive)?.id)
        .task { await model.load(session: session) }
        .fullScreenCover(isPresented: $adding) {
            PairingView(adding: true) {
                adding = false
                dismiss()
            }
            .environment(session)
        }
        .alert(pinTitle, isPresented: pinShown, presenting: model.pinRequest) { request in
            SecureField("PIN", text: $pin)
            Button("OK") { submit(pin, for: request) }
            Button("Cancel", role: .cancel) { pin = "" }
        } message: { request in
            switch request.kind {
            case .childLock: Text("A parent enters the child lock PIN to leave the child profile.")
            case .profile: Text("Enter the PIN of \(request.target.name).")
            }
        }
    }

    /// The picture is what lifts when focused; the name sits under it.
    private func tile(for choice: ProfilesModel.Choice) -> some View {
        let name = choice.name.isEmpty ? String(localized: "Profile") : choice.name
        return Button {
            if choice.isActive {
                dismiss()
            } else {
                Task { if await model.choose(choice, session: session) { dismiss() } }
            }
        } label: {
            VStack(spacing: 28) {
                ProfileAvatar(name: choice.name, avatar: choice.avatar, color: choice.avatarColor, client: session.client, size: Self.avatarSize)
                    // The system's own lift, light and shadow, on the picture
                    // rather than the whole tile.
                    .hoverEffect(.highlight)
                HStack(spacing: 10) {
                    if choice.isActive {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(verbatim: name)
                }
                .font(.headline)
                .foregroundStyle(focused == choice.id ? .primary : .secondary)
                .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .focused($focused, equals: choice.id)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(choice.isActive ? Text("In use") : Text(verbatim: ""))
        .accessibilityIdentifier("profile-\(choice.profileID)")
        .contextMenu {
            if choice.token != nil && !choice.isActive {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                    Task { await model.remove(choice, session: session) }
                }
            }
        }
    }

    private var addTile: some View {
        Button {
            adding = true
        } label: {
            VStack(spacing: 28) {
                Circle()
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 88, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .hoverEffect(.highlight)
                Text("Add profile")
                    .font(.headline)
                    .foregroundStyle(focused == Self.addID ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .focused($focused, equals: Self.addID)
        .accessibilityLabel(Text("Add profile"))
    }

    private var pinTitle: String {
        switch model.pinRequest?.kind {
        case .profile: String(localized: "Profile PIN")
        default: String(localized: "Child lock PIN")
        }
    }

    private var pinShown: Binding<Bool> {
        Binding(get: { model.pinRequest != nil }, set: { if !$0 { model.pinRequest = nil } })
    }

    private func submit(_ code: String, for request: ProfilesModel.PinRequest) {
        pin = ""
        model.pinRequest = nil
        Task {
            let switched = await model.choose(
                request.target,
                session: session,
                childLockPin: request.kind == .childLock ? code : request.childLockPin,
                pin: request.kind == .profile ? code : nil
            )
            if switched { dismiss() }
        }
    }
}
