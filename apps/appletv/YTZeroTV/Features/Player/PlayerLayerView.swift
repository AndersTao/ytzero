import AVFoundation
import SwiftUI

/// Just the picture. The controls are this app's own, so AVKit's transport bar
/// does not take the remote's left/right and Menu presses.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // The layer class is fixed above, so this cast cannot fail.
            layer as! AVPlayerLayer
        }
    }
}
