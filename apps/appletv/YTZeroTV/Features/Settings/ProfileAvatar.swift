import SwiftUI

/// A profile's picture, or its initial on its colour as the web client draws it.
struct ProfileAvatar: View {
    let name: String
    let avatar: String
    let color: String
    let client: APIClient?
    var size: CGFloat = 48

    @State private var image: Image?

    var body: some View {
        Circle()
            .fill(Color(hex: color) ?? .gray)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Text(initial)
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .clipShape(.circle)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: avatar) {
                guard !avatar.isEmpty, let client, let data = try? await client.avatarData(avatar),
                      let picture = UIImage(data: data) else { return }
                image = Image(uiImage: picture)
            }
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

private extension Color {
    /// "#rrggbb", as the server stores a profile's colour.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
