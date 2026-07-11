import Foundation
@preconcurrency import XCTest

/// A per-test application session. Callers own the instance and must not share it
/// across test methods.
@MainActor
public final class VocelloUIApplicationSession {
    public let app: XCUIApplication

    public init() {
        self.app = XCUIApplication()
    }

    public init(app: XCUIApplication) {
        self.app = app
    }

    /// Starts a clean host-app process using Xcode's configured UI-test target.
    public func launch(
        environment: [String: String],
        arguments: [String] = []
    ) {
        app.terminate()
        app.launchEnvironment = environment
        app.launchArguments = arguments
        app.launch()
    }

    public func terminate() {
        app.terminate()
    }
}

/// Predicate-backed waits used by both Apple-platform UI-test targets.
@MainActor
public enum VocelloUIWait {
    public static func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @discardableResult
    public static func exists(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let result = element.waitForExistence(timeout: timeout)
        if !result {
            XCTFail("Expected element to exist within \(timeout)s: \(element)", file: file, line: line)
        }
        return result
    }

    @discardableResult
    public static func disappears(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        condition(
            "element to disappear: \(element)",
            timeout: timeout,
            file: file,
            line: line
        ) {
            !element.exists
        }
    }

    @discardableResult
    public static func enabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        condition(
            "element to become enabled: \(element)",
            timeout: timeout,
            file: file,
            line: line
        ) {
            element.exists && element.isEnabled
        }
    }

    @discardableResult
    public static func value(
        _ element: XCUIElement,
        contains expected: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        condition(
            "element value to contain '\(expected)': \(element)",
            timeout: timeout,
            file: file,
            line: line
        ) {
            guard element.exists, let value = element.value as? String else { return false }
            return value.localizedCaseInsensitiveContains(expected)
        }
    }

    @discardableResult
    public static func label(
        _ element: XCUIElement,
        contains expected: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        condition(
            "element label to contain '\(expected)': \(element)",
            timeout: timeout,
            file: file,
            line: line
        ) {
            element.exists && element.label.localizedCaseInsensitiveContains(expected)
        }
    }

    /// Waits on live UI state without fixed sleeps or private test markers.
    @discardableResult
    public static func condition(
        _ description: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        evaluate: @escaping () -> Bool
    ) -> Bool {
        let anchor = NSObject()
        let predicate = NSPredicate { _, _ in evaluate() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: anchor)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            XCTFail("Timed out after \(timeout)s waiting for \(description)", file: file, line: line)
            return false
        }
        return true
    }
}

/// The platform-native primary activation gesture, always against an exact element.
@MainActor
public enum VocelloUIPrimaryAction {
    @discardableResult
    public static func perform(
        on element: XCUIElement,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard VocelloUIWait.condition(
            "element to become hittable for its primary action: \(element)",
            timeout: timeout,
            file: file,
            line: line,
            evaluate: { element.exists && element.isEnabled && element.isHittable }
        ) else {
            return false
        }

        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
        return true
    }
}

/// Deterministic text replacement without coordinate taps or label-based queries.
@MainActor
public enum VocelloUITextEntry {
    @discardableResult
    public static func replace(
        in element: XCUIElement,
        with text: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard VocelloUIPrimaryAction.perform(
            on: element,
            timeout: timeout,
            file: file,
            line: line
        ) else {
            return false
        }

        #if os(macOS)
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(.delete, modifierFlags: [])
        #else
        if let currentValue = element.value as? String, !currentValue.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        #endif
        element.typeText(text)
        return true
    }
}

/// Screenshots are retained in the xcresult; no out-of-band coordinate metadata is used.
@MainActor
public enum VocelloUIScreenshot {
    public static func attach(
        _ app: XCUIApplication,
        named name: String,
        lifetime: XCTAttachment.Lifetime = .keepAlways
    ) {
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = lifetime
            activity.add(attachment)
        }
    }
}

/// Canonical UI-driven benchmark corpus and ordering shared by Apple UI-test targets.
public enum VocelloUIBenchMatrix {
    public enum Mode: String, CaseIterable, Sendable {
        case custom
        case design
        case clone
    }

    public enum Length: String, CaseIterable, Sendable {
        case short
        case medium
        case long
    }

    public enum WarmState: String, Sendable {
        case cold
        case warm
    }

    public struct Take: Equatable, Sendable {
        public let mode: Mode
        public let length: Length
        public let warmState: WarmState
        public let repetition: Int
        public let text: String

        public var cellID: String {
            "\(mode.rawValue)/\(length.rawValue)/\(warmState.rawValue)#\(repetition)"
        }
    }

    public struct Configuration: Equatable, Sendable {
        public let modes: [Mode]
        public let lengths: [Length]
        public let warmRepetitions: Int

        public init(
            modes: [Mode] = Mode.allCases,
            lengths: [Length] = Length.allCases,
            warmRepetitions: Int = 3
        ) throws {
            guard !modes.isEmpty else { throw ConfigurationError.emptyModes }
            guard !lengths.isEmpty else { throw ConfigurationError.emptyLengths }
            guard Set(modes.map(\.rawValue)).count == modes.count else {
                throw ConfigurationError.duplicateValue("mode")
            }
            guard Set(lengths.map(\.rawValue)).count == lengths.count else {
                throw ConfigurationError.duplicateValue("length")
            }
            guard warmRepetitions >= 1 else {
                throw ConfigurationError.invalidWarmRepetitions(warmRepetitions)
            }
            self.modes = modes
            self.lengths = lengths
            self.warmRepetitions = warmRepetitions
        }

        public init(
            environment: [String: String],
            keyPrefix: String
        ) throws {
            let modes = try Self.parseList(
                environment["\(keyPrefix)_MODES"],
                defaultValue: Mode.allCases,
                type: Mode.self,
                kind: "mode"
            )
            let lengths = try Self.parseList(
                environment["\(keyPrefix)_LENGTHS"],
                defaultValue: Length.allCases,
                type: Length.self,
                kind: "length"
            )
            let warm: Int
            if let raw = environment["\(keyPrefix)_WARM"], !raw.isEmpty {
                guard let parsed = Int(raw) else { throw ConfigurationError.invalidInteger(raw) }
                warm = parsed
            } else {
                warm = 3
            }
            try self.init(modes: modes, lengths: lengths, warmRepetitions: warm)
        }

        private static func parseList<Value: RawRepresentable>(
            _ raw: String?,
            defaultValue: [Value],
            type: Value.Type,
            kind: String
        ) throws -> [Value] where Value.RawValue == String {
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return defaultValue
            }
            return try raw.split(separator: ",").map { component in
                let value = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = Value(rawValue: value) else {
                    throw ConfigurationError.unknownValue(kind: kind, value: value)
                }
                return parsed
            }
        }
    }

    public enum ConfigurationError: Error, CustomStringConvertible {
        case emptyModes
        case emptyLengths
        case duplicateValue(String)
        case invalidWarmRepetitions(Int)
        case invalidInteger(String)
        case unknownValue(kind: String, value: String)

        public var description: String {
            switch self {
            case .emptyModes:
                return "benchmark mode list is empty"
            case .emptyLengths:
                return "benchmark length list is empty"
            case .duplicateValue(let kind):
                return "benchmark \(kind) list contains a duplicate"
            case .invalidWarmRepetitions(let value):
                return "benchmark warm repetition count must be at least 1, got \(value)"
            case .invalidInteger(let value):
                return "benchmark integer is invalid: \(value)"
            case .unknownValue(let kind, let value):
                return "unknown benchmark \(kind): \(value)"
            }
        }
    }

    public static let voiceDesignBrief =
        "A warm, calm middle-aged male narrator with a clear, measured pace."
    public static let cloneVoiceID = "A_warm_elderly_woman"

    #if os(iOS)
    // iPhone generation intentionally caps spoken scripts at 150 characters.
    // Its long cell exercises that production boundary instead of bypassing it.
    private static let longBenchmarkText =
        "The morning train slipped quietly out of the station, carrying sleepy travelers toward the coast while grey water shimmered beyond the fogged windows."
    #else
    private static let longBenchmarkText =
        "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast. Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a steady, hypnotic hum. By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence."
    #endif

    public static let corpus: [(length: Length, text: String)] = [
        (.short, "The train left the station at dawn."),
        (.medium, "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast."),
        (.long, longBenchmarkText),
    ]

    public static let defaultConfiguration = try! Configuration()

    public static let defaultTakes: [Take] = {
        let result = takes(configuration: defaultConfiguration)
        precondition(result.count == 29, "The canonical Vocello UI benchmark must contain 29 takes")
        return result
    }()

    public static func text(for length: Length) -> String {
        guard let entry = corpus.first(where: { $0.length == length }) else {
            preconditionFailure("Missing UI benchmark corpus entry for \(length.rawValue)")
        }
        return entry.text
    }

    /// Custom and Design each begin with one cold medium take. Clone has no
    /// cold take. Every selected mode then runs the configured warm length grid.
    public static func takes(configuration: Configuration) -> [Take] {
        var result: [Take] = []
        let coldLength = configuration.lengths.contains(.medium)
            ? Length.medium
            : configuration.lengths[0]

        for mode in configuration.modes {
            if mode != .clone {
                result.append(
                    Take(
                        mode: mode,
                        length: coldLength,
                        warmState: .cold,
                        repetition: 0,
                        text: text(for: coldLength)
                    )
                )
            }
            for length in configuration.lengths {
                for repetition in 0..<configuration.warmRepetitions {
                    result.append(
                        Take(
                            mode: mode,
                            length: length,
                            warmState: .warm,
                            repetition: repetition,
                            text: text(for: length)
                        )
                    )
                }
            }
        }
        return result
    }
}
