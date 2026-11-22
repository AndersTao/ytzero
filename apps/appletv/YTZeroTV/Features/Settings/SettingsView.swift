import SwiftUI

/// Who is watching first, since that is what Settings is mostly opened for:
/// choose a profile, add one by pairing again, remove one. Then signing out,
/// and on the iPhone and iPad also changing server. On the Apple TV it opens
/// from the profile picture and holds only the profiles and signing out.
struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let model: ProfilesModel
    @State private var adding = false
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            List {
                if let message = model.message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(model.choices) { choice in
                        row(for: choice)
                    }
                    if model.hasLoaded && !model.switchesInSession {
                        Button {
                            adding = true
                        } label: {
                            Label("Add profile", systemImage: "person.badge.plus")
                        }
                    }
                } header: {
                    Text("Who is watching?")
                } footer: {
                    #if !os(tvOS)
                    if model.hasLoaded && !model.switchesInSession {
                        Text("Each profile signs in on its own: Add profile shows a code to approve on the phone of the person being added. Hold a profile to remove it.")
                    }
                    #endif
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        let client = session.client
                        session.signOut()
                        Task { await client?.signOut() }
                        dismiss()
                    }
                    // On the TV this list is opened from the profile picture
                    // and holds only profiles and signing out; another server
                    // is chosen from the sign-in screen.
                    #if !os(tvOS)
                    Button("Use another server", role: .destructive) {
                        session.forgetServer()
                    }
                    #endif
                }
            }
            #if !os(tvOS)
            .navigationTitle("Settings")
            #endif
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .overlay {
                if !model.hasLoaded && model.message == nil { ProgressView() }
            }
        }
        .task { await model.load(session: session) }
        #if os(tvOS)
        .fullScreenCover(isPresented: $adding) { addProfile }
        #else
        .sheet(isPresented: $adding) { addProfile }
        #endif
        .alert(pinTitle, isPresented: pinShown, presenting: model.pinRequest) { request in
            SecureField("PIN", text: $pin)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("OK") { submit(pin, for: request) }
            Button("Cancel", role: .cancel) { pin = "" }
        } message: { request in
            switch request.kind {
            case .childLock: Text("A parent enters the child lock PIN to leave the child profile.")
            case .profile: Text("Enter the PIN of \(request.target.name).")
            }
        }
    }

    /// One button per row. Remove is in the row's menu (a long press on the
    /// Apple TV, as on the video cards; touch and hold or swipe on a phone):
    /// a second button in a tvOS list row is pressed along with the first.
    private func row(for choice: ProfilesModel.Choice) -> some View {
        Button {
            Task { if await model.choose(choice, session: session) { dismiss() } }
        } label: {
            HStack(spacing: 24) {
                ProfileAvatar(name: choice.name, avatar: choice.avatar, color: choice.avatarColor, client: session.client, size: avatarSize)
                Text(choice.name.isEmpty ? String(localized: "Profile") : choice.name)
                Spacer()
                if choice.isActive {
                    Image(systemName: "checkmark")
                        .accessibilityLabel("In use")
                }
            }
        }
        .accessibilityIdentifier("profile-\(choice.profileID)")
        .contextMenu {
            if choice.token != nil && !choice.isActive {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                    Task { await model.remove(choice, session: session) }
                }
            }
        }
        #if os(iOS)
        .swipeActions {
            if choice.token != nil && !choice.isActive {
                Button("Remove", role: .destructive) {
                    Task { await model.remove(choice, session: session) }
                }
            }
        }
        #endif
    }

    private var addProfile: some View {
        PairingView(adding: true) {
            adding = false
            dismiss()
        }
        .environment(session)
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        60
        #else
        36
        #endif
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
