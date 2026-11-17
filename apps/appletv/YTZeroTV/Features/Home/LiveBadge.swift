import SwiftUI

/// "LIVE" on a stream that is on now, "Livestream" on a recording of one, so
/// they can be told from ordinary uploads at a glance.
struct LiveBadge: View {
    let kind: Video.LiveBadge

    var body: some View {
        Text(kind == .live ? "LIVE" : "Livestream")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(kind == .live ? Color.red : Color.black.opacity(0.75), in: .rect(cornerRadius: 8))
    }
}
