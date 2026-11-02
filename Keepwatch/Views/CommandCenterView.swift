import SwiftUI

enum CommandSubTab: String, CaseIterable, Identifiable {
    case pulse = "Pulse"
    case portal = "Portal"
    case media = "Media"
    case downloads = "Queue"
    case files = "Files"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pulse: return "gauge.medium"
        case .portal: return "square.grid.2x2"
        case .media: return "film.stack"
        case .downloads: return "arrow.down.circle"
        case .files: return "folder"
        }
    }
}

struct CommandCenterView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            subTabBar
            Group {
                switch router.commandSubTab {
                case .pulse:
                    OverviewView()
                case .portal:
                    SitesView()
                case .media:
                    MediaView()
                case .downloads:
                    DownloadsView()
                case .files:
                    FilesView()
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var subTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CommandSubTab.allCases) { item in
                    let selected = router.commandSubTab == item
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            router.commandSubTab = item
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol)
                                .font(.caption.weight(.semibold))
                            Text(item.rawValue)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selected ? Theme.background : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected ? Theme.accent : Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Theme.background)
    }
}
