import Foundation

enum ActivityPresentation: Equatable {
    case inlinePlayer
    case standaloneCard
}

struct ActivityStatus: Equatable {
    let label: String
    let fraction: Double?
    let presentation: ActivityPresentation
}

enum SidebarStatus: Equatable {
    case idle
    case starting
    case running(ActivityStatus)
    case error(String)
    case crashed(String)
}
