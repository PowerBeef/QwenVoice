import SwiftUI

/// Named Dynamic-Type-backed font roles for the Vocello brand-refresh chrome.
/// Every font in the new sidebar / footer player / Home / segmented / status
/// chip surfaces resolves through this enum so a single change here updates
/// the whole app, and so every label honors the user's macOS Display scale
/// and Accessibility text-size preference.
///
/// Roles:
///   - `.vocelloMicroLabel`  uppercase wordmark tag, "RECENT TAKES"
///   - `.vocelloCaption`     status-chip text, footer-player subtitle, mode-launcher sublabel
///   - `.vocelloMonoTime`    footer-player monospaced time readout
///   - `.vocelloFooterTitle` footer-player title, segmented-control label
///   - `.vocelloLauncherTitle` Home mode-launcher card title
///   - `.vocelloSidebarRow`  sidebar row label
///
/// The H1 and wordmark roles live in `CormorantTitle.swift` because they
/// also carry the brand serif.
extension Font {
    static var vocelloMicroLabel: Font { .caption2.weight(.semibold) }

    static var vocelloCaption: Font { .caption.weight(.medium) }

    static var vocelloMonoTime: Font { .caption.weight(.medium).monospacedDigit() }

    static var vocelloFooterTitle: Font { .subheadline.weight(.semibold) }

    static var vocelloLauncherTitle: Font { .callout.weight(.semibold) }

    static func vocelloSidebarRow(active: Bool) -> Font {
        active ? .body.weight(.semibold) : .body
    }
}
