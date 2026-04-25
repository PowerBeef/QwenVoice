import SwiftUI

/// Top-level sidebar navigation in the brand-refresh shell.
/// Sub-screens (modes inside Generate, tabs inside Library/Settings) are
/// owned by the per-section host views and don't appear in the sidebar.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home = "Home"
    case generate = "Generate"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .home:     return "sparkles"
        case .generate: return "waveform"
        case .library:  return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }

    /// Per-section brand tint (champagne for Home/Generate, silver-gold for
    /// Library, silver for Settings). Generate's per-mode tint lives one
    /// level deeper inside the segmented control.
    var sidebarTint: Color {
        switch self {
        case .home, .generate: return AppTheme.accent
        case .library:         return AppTheme.library
        case .settings:        return AppTheme.settings
        }
    }

    var accessibilityID: String {
        "sidebarSection_\(rawValue.lowercased())"
    }
}

/// Sub-tabs that live inside `SidebarSection.library`.
enum LibraryTab: String, CaseIterable, Identifiable, Hashable {
    case history = "History"
    case voices = "Saved Voices"

    var id: String { rawValue }

    var sidebarItem: SidebarItem {
        switch self {
        case .history: return .history
        case .voices:  return .voices
        }
    }
}

/// Sub-tabs that live inside `SidebarSection.settings`. Preferences keeps
/// resolving through the existing `Settings` scene wrapper for now —
/// `models` is the only sub-tab embedded in the main window.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case models = "Models"
    case preferences = "Preferences"

    var id: String { rawValue }

    var sidebarItem: SidebarItem? {
        switch self {
        case .models:      return .models
        case .preferences: return nil
        }
    }
}

extension GenerationMode: Identifiable {
    public var id: String { rawValue }
}

extension SidebarItem {
    /// The top-level sidebar section that contains this screen.
    var section: SidebarSection {
        switch self {
        case .customVoice, .voiceDesign, .voiceCloning: return .generate
        case .history, .voices:                          return .library
        case .models:                                    return .settings
        }
    }

    /// The Generate mode this item maps to, when applicable.
    var libraryTab: LibraryTab? {
        switch self {
        case .history: return .history
        case .voices:  return .voices
        default:       return nil
        }
    }

    var settingsTab: SettingsTab? {
        switch self {
        case .models: return .models
        default:      return nil
        }
    }
}
