import Foundation
import Observation

/// Signs this Apple TV in with the server's TV pairing: show a code, wait for
/// someone to approve it on a phone, keep the session that comes back.
@Observable
final class PairingModel {
    enum State: Equatable {
        case loading
        case waiting(code: String, link: String, address: String)
        case failed(String)
    }

    private(set) var state: State = .loading

    func run(client: APIClient, deviceName: String = "Apple TV", onToken: (String) -> Void) async {
        while !Task.isCancelled {
            do {
                let code = try await client.beginPairing(deviceName: deviceName)
                state = .waiting(code: code.userCode, link: code.verificationURIComplete ?? code.verificationURI, address: code.verificationURI)
                let deadline = ContinuousClock.now + .seconds(max(30, code.expiresIn))
                while ContinuousClock.now < deadline {
                    try await Task.sleep(for: .seconds(max(2, code.interval)))
                    do {
                        onToken(try await client.exchange(deviceCode: code.deviceCode))
                        return
                    } catch APIError.pending {
                        continue
                    } catch APIError.expired {
                        break
                    }
                }
                // The code ran out: start over with a new one.
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
