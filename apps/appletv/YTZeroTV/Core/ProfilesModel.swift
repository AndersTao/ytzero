import Foundation
import Observation

/// The profile picker in Settings: who can watch on this device, moving to
/// one of them, and the PIN that leaving a child profile asks for.
///
/// Where the server lets a session switch profile by itself (no login, a
/// shared login, OIDC through a gateway), the one session switches. Where it
/// pins a session to one profile, the device holds a session per profile,
/// each paired with "Add profile", and the server only confirms the move: that
/// the profile was paired here, and the child lock PIN when leaving a child.
@Observable
final class ProfilesModel {
    struct Choice: Identifiable, Equatable {
        let profileID: Int
        let name: String
        let avatar: String
        let avatarColor: String
        let isChild: Bool
        let hasPin: Bool
        let isActive: Bool
        /// The session kept for it here; nil where the session switches by itself.
        let token: String?

        var id: String { token ?? "profile-\(profileID)" }
    }

    struct PinRequest: Identifiable, Equatable {
        enum Kind: Equatable {
            /// The app-wide child lock, to leave a child profile.
            case childLock
            /// The chosen profile's own PIN (only where nothing else signs in).
            case profile
        }

        let id = UUID()
        let target: Choice
        let kind: Kind
        /// Already given when the profile's own PIN is asked for next.
        let childLockPin: String?
    }

    private(set) var choices: [Choice] = []
    private(set) var switchesInSession = false
    private(set) var hasLoaded = false
    private(set) var isWorking = false
    var pinRequest: PinRequest?
    /// Something to tell, e.g. a wrong PIN.
    var message: String?

    /// Who is signed in here, and their names and pictures, from the server.
    func load(session: AppSession) async {
        guard let client = session.client else { return }
        do {
            let status = try await client.authStatus()
            switchesInSession = status.canSwitch == true
            if switchesInSession {
                let list = try await client.profiles()
                if let current = list.profiles.first(where: { $0.id == list.activeID }) {
                    session.update(id: current.id, name: current.name, avatar: current.avatar, avatarColor: current.avatarColor, isChild: current.isChild, token: client.token)
                }
                let visible = status.hideOtherProfiles == true ? list.profiles.filter { $0.id == list.activeID } : list.profiles
                choices = visible.map { profile in
                    Choice(profileID: profile.id, name: profile.name, avatar: profile.avatar, avatarColor: profile.avatarColor,
                           isChild: profile.isChild, hasPin: profile.hasPin == true, isActive: profile.id == list.activeID, token: nil)
                }
            } else {
                let list = try await client.deviceProfiles()
                for profile in list.profiles {
                    session.update(id: profile.id, name: profile.name, avatar: profile.avatar, avatarColor: profile.avatarColor,
                                   isChild: profile.isChild, token: profile.id == list.activeID ? client.token : nil)
                }
                await identifyUnlinked(session: session, baseURL: client.baseURL)
                choices = session.profiles.map { profile in
                    Choice(profileID: profile.id, name: profile.name, avatar: profile.avatar, avatarColor: profile.avatarColor,
                           isChild: profile.isChild, hasPin: false, isActive: profile.token == session.token, token: profile.token)
                }
            }
            hasLoaded = true
        } catch APIError.unauthorized {
            session.signOut()
        } catch is CancellationError {
        } catch {
            message = error.localizedDescription
        }
    }

    /// A session the server did not list with this one (paired before sessions
    /// were linked) is asked who it is itself; one the server no longer takes is dropped.
    private func identifyUnlinked(session: AppSession, baseURL: URL) async {
        for stored in session.profiles where stored.id == 0 && stored.token != session.token {
            let other = APIClient(baseURL: baseURL, token: stored.token)
            do {
                let list = try await other.deviceProfiles()
                if let profile = list.profiles.first(where: { $0.id == list.activeID }) {
                    session.update(id: profile.id, name: profile.name, avatar: profile.avatar, avatarColor: profile.avatarColor,
                                   isChild: profile.isChild, token: stored.token)
                }
            } catch APIError.unauthorized {
                session.remove(stored)
            } catch {
                continue
            }
        }
    }

    /// Moves to `choice`. True once switched; otherwise a PIN may be asked for.
    func choose(_ choice: Choice, session: AppSession, childLockPin: String? = nil, pin: String? = nil) async -> Bool {
        guard !choice.isActive, !isWorking, let client = session.client else { return false }
        isWorking = true
        defer { isWorking = false }
        let leavingChild = session.activeProfile?.isChild == true || choices.contains { $0.isActive && $0.isChild }
        do {
            let result = switchesInSession
                ? try await client.switchProfile(to: choice.profileID, childLockPin: childLockPin, pin: pin)
                : try await client.switchDeviceProfile(to: choice.profileID, childLockPin: childLockPin)
            switch result {
            case .switched:
                if switchesInSession {
                    session.update(id: choice.profileID, name: choice.name, avatar: choice.avatar, avatarColor: choice.avatarColor,
                                   isChild: choice.isChild, token: session.token)
                    session.profileChanged()
                } else if let profile = session.profiles.first(where: { $0.token == choice.token }) {
                    session.activate(profile)
                }
                return true
            case .needsPin:
                pinRequest = PinRequest(target: choice, kind: .childLock, childLockPin: nil)
            case .wrongPin:
                // The web switch answers a missing PIN as a wrong one.
                if childLockPin == nil && leavingChild {
                    pinRequest = PinRequest(target: choice, kind: .childLock, childLockPin: nil)
                } else if switchesInSession && choice.hasPin && pin == nil {
                    pinRequest = PinRequest(target: choice, kind: .profile, childLockPin: childLockPin)
                } else {
                    message = String(localized: "Wrong PIN – try again.")
                    pinRequest = PinRequest(target: choice, kind: pin == nil ? .childLock : .profile, childLockPin: pin == nil ? nil : childLockPin)
                }
            case .locked:
                message = String(localized: "The child profile is locked. A parent can unlock it.")
            case .notPaired:
                // Paired before this device's sessions were linked, so the
                // server cannot vouch for the move: only a grown-up profile
                // may make it, and it is linked again by adding the profile anew.
                if !leavingChild, let profile = session.profiles.first(where: { $0.token == choice.token }) {
                    session.activate(profile)
                    return true
                }
                message = String(localized: "Add this profile again to switch to it.")
            }
        } catch APIError.unauthorized {
            session.signOut()
        } catch {
            message = error.localizedDescription
        }
        return false
    }

    /// Signs a profile out on this device, on the server too.
    func remove(_ choice: Choice, session: AppSession) async {
        guard !choice.isActive, let token = choice.token, let client = session.client,
              let profile = session.profiles.first(where: { $0.token == token }) else { return }
        isWorking = true
        defer { isWorking = false }
        if choice.profileID > 0 { try? await client.removeDeviceProfile(choice.profileID) }
        // Also when it was never linked to this session: it ends its own session.
        await APIClient(baseURL: client.baseURL, token: token).signOut()
        session.remove(profile)
        await load(session: session)
    }
}
