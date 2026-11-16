import SwiftUI

/// How far into a video someone got, along the bottom of its thumbnail.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(.red)
                    .scaleEffect(x: value, anchor: .leading)
            }
            .clipShape(.capsule)
            .padding(12)
            .accessibilityHidden(true)
    }
}
