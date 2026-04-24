import Foundation

/// Centralized namespace for iPhone UI accessibility identifiers used by
/// assistive technologies and stable UI references.
///
/// Tier 6: previously these strings were hardcoded at each use site, which
/// meant a control-type change (TextField -> TextEditor, etc.) could silently
/// drop the identifier. Reference these constants instead so the compiler
/// catches renames and typos.
enum IOSAccessibilityIdentifier {
    enum TextInput {
        static let limitMessage = "textInput_limitMessage"
        static let lengthCount = "textInput_lengthCount"
        static let lengthStatus = "textInput_lengthStatus"
    }
}
