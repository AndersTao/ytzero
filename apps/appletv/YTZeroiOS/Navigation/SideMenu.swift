import SwiftUI

/// Where the side menu leads. Main is the home screen; the others get their
/// screens one at a time.
enum MenuDestination: Hashable {
    case main
    case recommendations
    case shorts
    case scheduled
    case subscriptions
    case playlist(APIModels.UserPlaylist)

    var title: String {
        switch self {
        case .main: String(localized: "Main")
        case .recommendations: String(localized: "Recommendations")
        case .shorts: String(localized: "Shorts")
        case .scheduled: String(localized: "Scheduled")
        case .subscriptions: String(localized: "Subscriptions")
        case .playlist(let playlist): playlist.name
        }
    }

    var systemImage: String {
        switch self {
        case .main: "house"
        case .recommendations: "sparkles"
        case .shorts: "play.rectangle.on.rectangle"
        case .scheduled: "clock"
        case .subscriptions: "person.2"
        case .playlist: "music.note.list"
        }
    }
}

/// Opens the side menu from anywhere under it, such as a toolbar button.
struct OpenSideMenuAction {
    let open: () -> Void
    func callAsFunction() { open() }
}

extension EnvironmentValues {
    @Entry var openSideMenu = OpenSideMenuAction(open: {})
}

/// The screens with a panel that slides in from the left: a swipe from the
/// left edge or the menu button opens it, a tap beside it or a swipe back
/// closes it. The panel lists the main places and the profile's playlists,
/// as the web client's sidebar does.
struct SideMenuContainer: View {
    @Environment(AppSession.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var destination: MenuDestination = .main
    @State private var isOpen = false
    /// How far the panel is being dragged, while a finger is on it.
    @State private var drag: CGFloat = 0
    @State private var playlists: [APIModels.UserPlaylist] = []

    private var panelWidth: CGFloat { horizontalSizeClass == .regular ? 320 : 290 }

    var body: some View {
        ZStack(alignment: .leading) {
            screen
                .environment(\.openSideMenu, OpenSideMenuAction { setOpen(true) })

            // Dims what is behind and closes the panel when tapped.
            Color.black
                .opacity(0.45 * progress)
                .ignoresSafeArea()
                .allowsHitTesting(isOpen)
                .onTapGesture { setOpen(false) }
                .accessibilityHidden(true)

            // A thin strip along the left edge that a swipe opens the panel from.
            if !isOpen {
                Color.clear
                    .frame(width: 22)
                    .contentShape(.rect)
                    .ignoresSafeArea()
                    .gesture(openingDrag)
                    .accessibilityHidden(true)
            }

            // Only there while open or being pulled out, so nothing of it is
            // in the way (or read out) behind the screen.
            if isOpen || drag != 0 {
                SideMenuPanel(destination: destination, playlists: playlists) { chosen in
                    destination = chosen
                    setOpen(false)
                }
                .frame(width: panelWidth)
                .offset(x: panelOffset)
                .gesture(closingDrag)
                .transition(.move(edge: .leading))
            }
        }
        .task(id: isOpen) {
            // Fresh each time it opens: a playlist made on the web shows up.
            guard isOpen || playlists.isEmpty, let client = session.client else { return }
            if let loaded = try? await client.playlists() { playlists = loaded }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch destination {
        case .main:
            HomeView()
        default:
            ComingSoonView(destination: destination)
        }
    }

    /// 0 closed, 1 open, following the finger in between.
    private var progress: Double {
        let shown = isOpen ? panelWidth + min(0, drag) : max(0, drag)
        return min(1, max(0, shown / panelWidth))
    }

    private var panelOffset: CGFloat {
        isOpen ? min(0, drag) : -panelWidth + min(panelWidth, max(0, drag))
    }

    private var openingDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in drag = max(0, value.translation.width) }
            .onEnded { value in
                setOpen(value.translation.width > panelWidth / 3 || value.predictedEndTranslation.width > panelWidth / 2)
            }
    }

    private var closingDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in drag = min(0, value.translation.width) }
            .onEnded { value in
                setOpen(!(value.translation.width < -panelWidth / 3 || value.predictedEndTranslation.width < -panelWidth / 2))
            }
    }

    private func setOpen(_ open: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isOpen = open
            drag = 0
        }
    }
}

/// The panel itself: the main places, then "My playlists" with the profile's own.
private struct SideMenuPanel: View {
    let destination: MenuDestination
    let playlists: [APIModels.UserPlaylist]
    let choose: (MenuDestination) -> Void

    private let places: [MenuDestination] = [.main, .recommendations, .shorts, .scheduled, .subscriptions]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("YT Zero")
                    .font(.title2.bold())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                ForEach(places, id: \.self) { place in
                    row(place)
                }
                Divider()
                    .padding(.vertical, 12)
                Text("My playlists")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                if playlists.isEmpty {
                    Text("No playlists yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                ForEach(playlists) { playlist in
                    row(.playlist(playlist), count: playlist.videoCount)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.09).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private func row(_ place: MenuDestination, count: Int? = nil) -> some View {
        let selected = place == destination
        return Button {
            choose(place)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: place.systemImage)
                    .frame(width: 24)
                Text(verbatim: place.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body.weight(selected ? .semibold : .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(selected ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A place the menu has but whose screen is still to be made.
private struct ComingSoonView: View {
    let destination: MenuDestination

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label { Text(verbatim: destination.title) } icon: { Image(systemName: destination.systemImage) }
            } description: {
                Text("Coming soon")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MenuButton()
                }
            }
            .navigationTitle(Text(verbatim: destination.title))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The three lines that open the side menu, before the title.
struct MenuButton: View {
    @Environment(\.openSideMenu) private var openSideMenu

    var body: some View {
        Button {
            openSideMenu()
        } label: {
            Label("Menu", systemImage: "line.3.horizontal")
        }
        .accessibilityIdentifier("menu-button")
    }
}
