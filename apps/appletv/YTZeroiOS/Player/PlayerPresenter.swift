import AVKit
import Observation
import SwiftUI
import UIKit

/// Plays a video in the system player, presented over the app: its own Done,
/// scrubbing, AirPlay and picture in picture, with the lock screen and
/// Control Center showing what plays. Finding a stream, resuming and saving
/// the position are the shared `PlayerModel`'s, as on the Apple TV.
@Observable
final class PlayerPresenter: NSObject, AVPlayerViewControllerDelegate {
    private(set) var isPresenting = false

    private var controller: PlayerController?
    private var model: PlayerModel?
    private var video: Video?
    private var client: APIClient?
    private var onFinished: (() -> Void)?
    private var onClose: ((Video) -> Void)?
    private var attach: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    /// In picture in picture the player's screen is gone but playback is not.
    private var inPictureInPicture = false
    private var restoring = false

    func present(video: Video, client: APIClient, onFinished: @escaping () -> Void, onClose: @escaping (Video) -> Void) {
        guard !isPresenting, let presenter = Self.topViewController() else { return }
        let model = PlayerModel()
        let controller = PlayerController()
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.modalPresentationStyle = .fullScreen
        controller.onDisappear = { [weak self] in self?.controllerDisappeared() }
        let status = UIHostingController(rootView: PlayerStatusView(model: model))
        status.view.backgroundColor = .clear
        status.view.isUserInteractionEnabled = false
        status.view.frame = controller.contentOverlayView?.bounds ?? .zero
        status.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.contentOverlayView?.addSubview(status.view)
        controller.addChild(status)
        status.didMove(toParent: controller)

        self.model = model
        self.controller = controller
        self.video = video
        self.client = client
        self.onFinished = onFinished
        self.onClose = onClose
        isPresenting = true
        presenter.present(controller, animated: true)

        // The screen gets the player once it plays. Handed over while still
        // loading, AVKit takes it for paused and keeps its controls up until
        // someone taps. The model may also swap players (full quality, then
        // the plain relay when that fails), and the screen follows.
        attach = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let controller = self.controller, let model = self.model else { return }
                let current = model.phase == .playing ? model.player : nil
                if current != nil, controller.player !== current {
                    controller.player = current
                }
                if let item = model.player?.currentItem, item.externalMetadata.isEmpty {
                    item.externalMetadata = Self.metadata(for: video)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        playback = Task { [weak self] in
            await model.start(video: video, client: client)
            guard let self, !Task.isCancelled else { return }
            if model.finished {
                self.onFinished?()
                self.close(dismissing: true)
            }
        }
    }

    /// What the lock screen, Control Center and AirPlay receivers show.
    private static func metadata(for video: Video) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        return [item(.commonIdentifierTitle, video.title), item(.iTunesMetadataTrackSubTitle, video.channelTitle)]
    }

    private func controllerDisappeared() {
        // Going into picture in picture takes the screen away, not the video.
        guard !inPictureInPicture, !restoring else { return }
        close(dismissing: false)
    }

    private func close(dismissing: Bool) {
        guard isPresenting else { return }
        isPresenting = false
        attach?.cancel()
        playback?.cancel()
        if dismissing, let controller, controller.presentingViewController != nil {
            controller.dismiss(animated: true)
        }
        // The home screen hears only once the position is saved: asked
        // sooner, the server answered with the old one.
        if let model, let video, let client {
            let onClose = onClose
            Task { onClose?(await model.stop(video: video, client: client)) }
        }
        controller?.player = nil
        controller = nil
        model = nil
        onFinished = nil
        onClose = nil
    }

    // MARK: AVPlayerViewControllerDelegate

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
        // Closed from the floating window rather than brought back: done.
        if !restoring, playerViewController.presentingViewController == nil { close(dismissing: false) }
        restoring = false
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard playerViewController.presentingViewController == nil, let presenter = Self.topViewController() else {
            completionHandler(true)
            return
        }
        restoring = true
        presenter.present(playerViewController, animated: true) { completionHandler(true) }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// The system player, telling when its screen goes away (Done, a swipe down,
/// or picture in picture).
final class PlayerController: AVPlayerViewController {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

/// Over the picture while there is nothing to show yet, or when it failed.
private struct PlayerStatusView: View {
    let model: PlayerModel

    var body: some View {
        switch model.phase {
        case .preparing:
            // Below the player's own buttons in the middle, not under them.
            ProgressView("Preparing video…")
                .tint(.white)
                .foregroundStyle(.white)
                .padding(.top, 240)
        case .failed(let message):
            VStack(spacing: 10) {
                Text("The video could not be played.")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .foregroundStyle(.white)
        case .playing:
            EmptyView()
        }
    }
}
