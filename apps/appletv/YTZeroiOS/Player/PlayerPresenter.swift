import AVKit
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// Plays a video full screen over the app with this app's own controls
/// (`PlayerControls`): 15 s back and 30 s forward, double tap on the sides,
/// picture in picture, AirPlay, and the lock screen and Control Center
/// showing what plays. Finding a stream, resuming and saving the position are
/// the shared `PlayerModel`'s, as on the Apple TV.
///
/// AVKit's own player screen was used before, but on iPhone and iPad its skip
/// buttons are fixed at 10 s and it does not tell when its controls are up.
@Observable
final class PlayerPresenter: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var isPresenting = false

    private var controller: PlayerController?
    private var model: PlayerModel?
    private var video: Video?
    private var client: APIClient?
    private var onFinished: (() -> Void)?
    private var onClose: ((Video) -> Void)?
    private var attach: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var nowPlaying: MPNowPlayingSession?
    /// In picture in picture the player's screen is gone but playback is not.
    private var inPictureInPicture = false
    private var restoring = false

    func present(video: Video, client: APIClient, onFinished: @escaping () -> Void, onClose: @escaping (Video) -> Void) {
        guard !isPresenting, let presenter = Self.topViewController() else { return }
        let model = PlayerModel()
        let controller = PlayerController()
        controller.modalPresentationStyle = .fullScreen
        controller.onDisappear = { [weak self] in self?.controllerDisappeared() }
        controller.pictureInPictureDelegate = self
        controller.showControls(
            PlayerControls(
                model: model,
                video: video,
                close: { [weak self] in self?.close(dismissing: true) },
                startPictureInPicture: AVPictureInPictureController.isPictureInPictureSupported()
                    ? { [weak controller] in controller?.startPictureInPicture() }
                    : nil
            )
        )

        self.model = model
        self.controller = controller
        self.video = video
        self.client = client
        self.onFinished = onFinished
        self.onClose = onClose
        isPresenting = true
        presenter.present(controller, animated: true)

        // The model may swap players (full quality, then the plain relay
        // when that fails), and the picture follows.
        attach = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let controller = self.controller, let model = self.model else { return }
                if let current = model.player, controller.player !== current {
                    controller.player = current
                    self.publishNowPlaying(for: current, model: model, video: video)
                } else if let item = model.player?.currentItem, item.nowPlayingInfo == nil {
                    // A new item for the same player, after a lapsed ticket.
                    item.nowPlayingInfo = Self.nowPlayingInfo(for: video)
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

    /// The lock screen and Control Center: title, channel, play and pause,
    /// the same 15 s / 30 s skips as on screen, and dragging the timeline.
    private func publishNowPlaying(for player: AVPlayer, model: PlayerModel, video: Video) {
        player.currentItem?.nowPlayingInfo = Self.nowPlayingInfo(for: video)
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        let commands = session.remoteCommandCenter
        commands.playCommand.addTarget { [weak model] _ in
            guard let model, model.isPlaying == false else { return .success }
            model.togglePlay()
            return .success
        }
        commands.pauseCommand.addTarget { [weak model] _ in
            guard let model, model.isPlaying else { return .success }
            model.togglePlay()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak model] _ in
            model?.togglePlay()
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: PlayerModel.seekForward)]
        commands.skipForwardCommand.addTarget { [weak model] _ in
            model?.seek(by: PlayerModel.seekForward, quietly: true)
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlayerModel.seekBack)]
        commands.skipBackwardCommand.addTarget { [weak model] _ in
            model?.seek(by: -PlayerModel.seekBack, quietly: true)
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak model] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            model?.seek(to: event.positionTime)
            return .success
        }
        session.becomeActiveIfPossible { _ in }
        nowPlaying = session
    }

    private static func nowPlayingInfo(for video: Video) -> [String: Any] {
        [MPMediaItemPropertyTitle: video.title, MPMediaItemPropertyArtist: video.channelTitle]
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
        controller?.stopPictureInPicture()
        controller?.player = nil
        controller = nil
        model = nil
        nowPlaying = nil
        onFinished = nil
        onClose = nil
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        inPictureInPicture = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        // As AVKit's own screen did: the video carries on in the corner and
        // the app is usable underneath.
        if let controller, controller.presentingViewController != nil {
            controller.dismiss(animated: true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        inPictureInPicture = false
        // Closed from the floating window rather than brought back: done.
        if !restoring, controller?.presentingViewController == nil { close(dismissing: false) }
        restoring = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let controller, controller.presentingViewController == nil, let presenter = Self.topViewController() else {
            completionHandler(true)
            return
        }
        restoring = true
        presenter.present(controller, animated: true) { completionHandler(true) }
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

/// The picture with the controls over it, telling when its screen goes away
/// (closed, or into picture in picture).
final class PlayerController: UIViewController {
    var onDisappear: (() -> Void)?
    weak var pictureInPictureDelegate: AVPictureInPictureControllerDelegate?

    private let picture = PlayerLayerView.LayerView()
    private var pictureInPicture: AVPictureInPictureController?
    private var controls: UIViewController?

    var player: AVPlayer? {
        get { picture.playerLayer.player }
        set {
            picture.playerLayer.player = newValue
            if newValue != nil, pictureInPicture == nil, AVPictureInPictureController.isPictureInPictureSupported() {
                let pip = AVPictureInPictureController(playerLayer: picture.playerLayer)
                pip?.canStartPictureInPictureAutomaticallyFromInline = true
                pip?.delegate = pictureInPictureDelegate
                pictureInPicture = pip
            }
        }
    }

    func showControls(_ overlay: PlayerControls) {
        let hosting = UIHostingController(rootView: overlay)
        hosting.view.backgroundColor = .clear
        controls = hosting
    }

    func startPictureInPicture() {
        guard let pictureInPicture, pictureInPicture.isPictureInPicturePossible else { return }
        pictureInPicture.startPictureInPicture()
    }

    func stopPictureInPicture() {
        if pictureInPicture?.isPictureInPictureActive == true { pictureInPicture?.stopPictureInPicture() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        picture.playerLayer.videoGravity = .resizeAspect
        picture.frame = view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(picture)
        if let controls {
            addChild(controls)
            controls.view.frame = view.bounds
            controls.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controls.view)
            controls.didMove(toParent: self)
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}
