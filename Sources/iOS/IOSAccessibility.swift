import SwiftUI
import UIKit

private struct IOSReduceMotionEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IOSReduceTransparencyEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var iosReduceMotionEnabled: Bool {
        get { self[IOSReduceMotionEnabledKey.self] }
        set { self[IOSReduceMotionEnabledKey.self] = newValue }
    }

    var iosReduceTransparencyEnabled: Bool {
        get { self[IOSReduceTransparencyEnabledKey.self] }
        set { self[IOSReduceTransparencyEnabledKey.self] = newValue }
    }
}

// iOS counterpart to the macOS `appAnimation` helper at
// Sources/Views/Components/AppTheme.swift. Honors Reduce Motion via the
// SwiftUI environment so animations are skipped when the user has the
// accessibility setting enabled. AGENTS.md requires Reduce Motion to be
// honored across the app.

extension View {
    func iosAppAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(IOSAccessibleAnimationModifier(animation: animation, value: value))
    }

    /// Apply `accessibilityIdentifier` only when an id is provided. Lets a view
    /// take an optional id without the caller branching.
    @ViewBuilder
    func iosAccessibilityIdentifier(_ id: String?) -> some View {
        if let id {
            accessibilityIdentifier(id)
        } else {
            self
        }
    }
}

private struct IOSAccessibleAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.iosReduceMotionEnabled) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

@MainActor
enum IOSAccessibleAnimation {
    static func perform<R>(_ animation: Animation?, _ block: () -> R) -> R {
        let shouldReduceMotion = UIAccessibility.isReduceMotionEnabled || IOSAppDefaults.reduceMotionEnabled
        let resolved = shouldReduceMotion ? nil : animation
        return withAnimation(resolved, block)
    }
}
