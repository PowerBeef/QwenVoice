import Foundation

/// User-defaults keys for iOS app-level preferences. Lives in iOSSupport so
/// both the iOS target and the iOS-flavored services can share it.
public enum IOSAppDefaults {
    private static var defaults: UserDefaults { .standard }

    private enum Keys {
        static let hasCompletedOnboarding = "vocello.ios.hasCompletedOnboarding"
        static let autoplayCompletions = "vocello.ios.autoplayCompletions"
        static let lastTab = "vocello.ios.lastTab"
        static let lastStudioMode = "vocello.ios.lastStudioMode"
    }

    /// Last bottom-tab the user was on (raw value), for state restoration.
    public static var lastTabRawValue: String? {
        get { defaults.string(forKey: Keys.lastTab) }
        set { defaults.set(newValue, forKey: Keys.lastTab) }
    }

    /// Last Studio mode the user was editing (raw value), for state restoration.
    public static var lastStudioModeRawValue: String? {
        get { defaults.string(forKey: Keys.lastStudioMode) }
        set { defaults.set(newValue, forKey: Keys.lastStudioMode) }
    }

    public static let reduceMotionEnabledKey = "vocello.ios.reduceMotionEnabled"
    public static let reduceTransparencyEnabledKey = "vocello.ios.reduceTransparencyEnabled"

    /// True once the user has dismissed the first-run onboarding flow.
    /// Skipped automatically when any model is already installed (returning
    /// users coming from a build before onboarding shipped).
    public static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    /// True if generations should auto-play their preview as soon as the
    /// audio is ready. Default true.
    public static var autoplayCompletions: Bool {
        get {
            if defaults.object(forKey: Keys.autoplayCompletions) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.autoplayCompletions)
        }
        set { defaults.set(newValue, forKey: Keys.autoplayCompletions) }
    }

    /// App-level Reduce Motion override used by the in-app Settings toggle.
    /// The OS accessibility setting is still honored separately at the root.
    public static var reduceMotionEnabled: Bool {
        get { defaults.bool(forKey: reduceMotionEnabledKey) }
        set { defaults.set(newValue, forKey: reduceMotionEnabledKey) }
    }

    /// App-level Reduce Transparency override used by the in-app Settings toggle.
    /// The OS accessibility setting is still honored separately at the root.
    public static var reduceTransparencyEnabled: Bool {
        get { defaults.bool(forKey: reduceTransparencyEnabledKey) }
        set { defaults.set(newValue, forKey: reduceTransparencyEnabledKey) }
    }
}
