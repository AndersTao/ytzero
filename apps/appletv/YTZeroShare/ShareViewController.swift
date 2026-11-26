import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "YT Zero" in the share sheet, from Safari, the YouTube app or anywhere a
/// YouTube link is shared: saves the video to the profile's "Saved for
/// later" row on Main, with the session of the profile watching in the app
/// (`SharedStore`). It closes by itself once the video is saved.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in self?.finish() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task {
            await model.save(from: items.flatMap { $0.attachments ?? [] })
            if model.isDone {
                try? await Task.sleep(for: .seconds(1.2))
                finish()
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
final class ShareModel {
    enum State: Equatable {
        case saving
        case saved(already: Bool)
        case failed(String)
    }

    private(set) var state = State.saving

    var isDone: Bool {
        if case .saved = state { true } else { false }
    }

    func save(from attachments: [NSItemProvider]) async {
        guard let link = await Self.link(in: attachments) else {
            state = .failed(String(localized: "This is not a YouTube video."))
            return
        }
        guard let client = SharedStore.signedInClient() else {
            state = .failed(String(localized: "Open the YT Zero app and sign in first."))
            return
        }
        do {
            state = .saved(already: try await client.saveForLater(link.videoID))
        } catch APIError.unauthorized {
            state = .failed(String(localized: "Open the YT Zero app and sign in first."))
        } catch APIError.server(status: 403, _) {
            state = .failed(String(localized: "This profile can only watch videos that are already in YT Zero."))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The first YouTube video among what was shared: a link, or text with
    /// a link in it.
    private static func link(in attachments: [NSItemProvider]) async -> VideoLink? {
        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               let link = VideoLink(youTubeURL: url) {
                return link
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let link = VideoLink(text: text) {
                return link
            }
        }
        return nil
    }
}

private struct ShareView: View {
    let model: ShareModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .saving:
                ProgressView()
                Text("Saving for later…")
            case .saved(let already):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text(already ? "Already saved. It is first in the row again." : "Saved for later.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(message)
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }
}
