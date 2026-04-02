import Combine
import Foundation

@MainActor
final class AppCommandRouter: ObservableObject {
    static let shared = AppCommandRouter()

    let sidebarSelection = PassthroughSubject<SidebarItem, Never>()

    private init() {}

    func navigate(to item: SidebarItem) {
        sidebarSelection.send(item)
    }
}
