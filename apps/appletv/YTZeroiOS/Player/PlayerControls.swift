import AVKit
import SwiftUI
import UIKit

/// The controls over the picture: close, picture in picture and AirPlay at
/// the top, 15 s back / play / 30 s forward in the middle, title, timeline and
/// speed at the bottom. A tap shows or hides them.
///
/// With the controls away, a double tap on either side of the picture skips
/// 15 s back or forward, as in other video apps. On an iPhone that is only
/// when it is held sideways; standing up, the sides are too narrow to aim for.
struct PlayerControls: View {
    let model: PlayerModel
    let video: Video
    let close: () -> Void
    let startPictureInPicture: (() -> Void)?

    static let doubleTapSkip: Double = 15

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var scrubbing: Double?
    /// The last double tap's side and a counter, so repeated taps restart the mark.
    @State private var skipMark: (forward: Bool, id: Int)?

    private var showsControls: Bool { model.showsOverlay || model.phase != .playing }

    private var sideZonesActive: Bool {
        guard !showsControls, model.player != nil else { return false }
        return UIDevice.current.userInterfaceIdiom == .pad || verticalSizeClass == .compact
    }

    var body: some View {
        ZStack {
            tapSurface
            if let skipMark {
                SkipMark(forward: skipMark.forward)
                    .id(skipMark.id)
                    .frame(maxWidth: .infinity, alignment: skipMark.forward ? .trailing : .leading)
                    .allowsHitTesting(false)
            }
            if showsControls {
                controls
                    .transition(.opacity)
            }
            status
        }
        .animation(.easeOut(duration: 0.2), value: showsControls)
        .foregroundStyle(.white)
    }

    // MARK: Taps

    /// Three bands across the picture. The outer two take a double tap while
    /// the controls are away; a single tap anywhere shows or hides them.
    private var tapSurface: some View {
        GeometryReader { geometry in
            let side = geometry.size.width * 0.35
            HStack(spacing: 0) {
                zone(forward: false).frame(width: side)
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { model.toggleOverlay() }
                zone(forward: true).frame(width: side)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func zone(forward: Bool) -> some View {
        let area = Color.clear.contentShape(.rect)
        if sideZonesActive {
            area
                .onTapGesture(count: 2) { skip(forward: forward) }
                .onTapGesture { model.toggleOverlay() }
                .accessibilityHidden(true)
        } else {
            area.onTapGesture { model.toggleOverlay() }
        }
    }

    private func skip(forward: Bool) {
        model.seek(by: forward ? Self.doubleTapSkip : -Self.doubleTapSkip, quietly: true)
        skipMark = (forward, (skipMark?.id ?? 0) + 1)
        let id = skipMark?.id
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            if skipMark?.id == id { skipMark = nil }
        }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                if model.phase == .playing { centreButtons }
                Spacer()
                if model.phase == .playing { bottomBar }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 22) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Close"))
            if let startPictureInPicture {
                Button(action: startPictureInPicture) {
                    Image(systemName: "pip.enter")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Picture in picture"))
            }
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
        }
    }

    private var centreButtons: some View {
        HStack(spacing: 56) {
            Button { model.seek(by: -PlayerModel.seekBack) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 34))
            }
            .accessibilityLabel(Text("Back 15 seconds"))
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .frame(width: 64, height: 64)
            }
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))
            Button { model.seek(by: PlayerModel.seekForward) } label: {
                Image(systemName: "goforward.30").font(.system(size: 34))
            }
            .accessibilityLabel(Text("Forward 30 seconds"))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(video.channelTitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                speedMenu
            }
            if model.duration > 0 {
                Slider(
                    value: Binding(
                        get: { scrubbing ?? model.position },
                        set: { scrubbing = $0; model.keepOverlay() }
                    ),
                    in: 0...model.duration
                ) { editing in
                    if !editing, let target = scrubbing {
                        model.seek(to: target)
                        scrubbing = nil
                    }
                }
                .tint(.white)
                HStack {
                    Text(verbatim: PlaybackTime.text(scrubbing ?? model.position))
                    Spacer()
                    Text(verbatim: "−" + PlaybackTime.text(max(0, model.duration - (scrubbing ?? model.position))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { rate in
                Button {
                    model.setSpeed(rate)
                } label: {
                    if rate == model.speed {
                        Label(Self.speedText(rate), systemImage: "checkmark")
                    } else {
                        Text(verbatim: Self.speedText(rate))
                    }
                }
            }
        } label: {
            Text(verbatim: Self.speedText(model.speed))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.18), in: .capsule)
        }
        .accessibilityLabel(Text("Playback speed"))
        .simultaneousGesture(TapGesture().onEnded { model.keepOverlay() })
    }

    private static func speedText(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .preparing:
            // Below the top bar's buttons, not under them.
            ProgressView("Preparing video…")
                .tint(.white)
                .allowsHitTesting(false)
        case .failed(let message):
            VStack(spacing: 10) {
                Text("The video could not be played.")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .allowsHitTesting(false)
        case .playing:
            if model.isBuffering, !showsControls {
                ProgressView()
                    .tint(.white)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// "−15 s" or "+15 s" on the side that was double tapped.
private struct SkipMark: View {
    let forward: Bool
    @State private var shown = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: forward ? "goforward.15" : "gobackward.15")
                .font(.system(size: 30, weight: .semibold))
            Text(verbatim: forward ? "+15 s" : "−15 s")
                .font(.footnote.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .frame(width: 120, height: 120)
        .background(.black.opacity(0.35), in: .circle)
        .padding(.horizontal, 48)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.8)
        .onAppear { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
    }
}

/// AVKit's AirPlay picker, which lists the receivers and switches to one.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
