import Foundation
import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var pendingShareURL: URL?

    func consumePendingShareURL() -> URL? {
        let url = pendingShareURL
        pendingShareURL = nil
        return url
    }
}
