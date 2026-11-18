import SwiftUI

/// Full screen. Right +30 s, left −15 s, select or Play/Pause pauses and
/// plays, Menu goes back to the shelves.
struct PlayerView: View {
    let video: Video
    let onFinished: () -> Void
    /// After closing, once the position is saved: the video as far as watched.
    let onClosed: (Video) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = PlayerModel()

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                PlayerLayerView(player: player)
            }
            overlay
            if let flash = model.flash {
                Text(flash)
                    .font(.system(size: 56, weight: .bold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 24)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 24))
                    .transition(.opacity)
            }
            phaseMessage
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .onTapGesture { model.togglePlay() }
        .onPlayPauseCommand { model.togglePlay() }
        .onMoveCommand { direction in
            switch direction {
            case .right: model.seek(by: PlayerModel.seekForward)
            case .left: model.seek(by: -PlayerModel.seekBack)
            default: model.showOverlayBriefly()
            }
        }
        .onExitCommand { dismiss() }
        .animation(.easeOut(duration: 0.25), value: model.flash)
        .animation(.easeOut(duration: 0.3), value: model.showsOverlay)
        .task {
            guard let client = session.client else { return }
            await model.start(video: video, client: client)
            if model.finished {
                onFinished()
                dismiss()
            }
        }
        .onDisappear {
            guard let client = session.client else { return }
            let model = model
            Task { onClosed(await model.stop(video: video, client: client)) }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if model.showsOverlay {
            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                Text(video.channelTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(video.title)
                    .font(.title2.bold())
                    .lineLimit(2)
                ProgressView(value: model.duration > 0 ? min(1, model.position / model.duration) : 0)
                    .tint(.white)
                Text(verbatim: "\(PlaybackTime.text(model.position)) / \(PlaybackTime.text(model.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 96)
            .padding(.bottom, 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 420)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var phaseMessage: some View {
        switch model.phase {
        case .preparing:
            ProgressView("Preparing video…")
        case .failed(let message):
            VStack(spacing: 16) {
                Text("The video could not be played.")
                    .font(.title3)
                Text(message)
                    .foregroundStyle(.secondary)
                Text("Press Menu to go back.")
                    .foregroundStyle(.secondary)
            }
        case .playing:
            if model.isBuffering {
                ProgressView()
            }
        }
    }
}
