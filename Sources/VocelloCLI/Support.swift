import Foundation

/// A user-facing CLI error whose message is printed verbatim (no stack noise).
struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

/// Minimal flag parser: `--key value` pairs, bare `--flag`s, and positionals.
/// Clean enough for a focused tool without pulling in an external arg-parser dep.
struct Args {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private(set) var positionals: [String] = []

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let token = argv[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    values[String(key[..<eq])] = String(key[key.index(after: eq)...])
                    i += 1
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    values[key] = argv[i + 1]
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                positionals.append(token)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }

    func require(_ key: String, _ hint: String) throws -> String {
        guard let v = values[key], !v.isEmpty else {
            throw CLIError("missing required --\(key) (\(hint))")
        }
        return v
    }
}

enum CLIPaths {
    /// Resolve the runtime data directory the engine roots at (models/, cache/,
    /// outputs/, diagnostics/). Mirrors the app's AppPaths selection without
    /// depending on the app target: explicit --data-dir wins, else
    /// QWENVOICE_APP_SUPPORT_DIR, else ~/Library/Application Support/QwenVoice
    /// (or QwenVoice-Debug when QWENVOICE_DEBUG is truthy — matching the app so
    /// the CLI shares the debug-isolated models/diagnostics during benchmarks).
    static func dataDirectory(override: String?) -> URL {
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["QWENVOICE_APP_SUPPORT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let debug = (env["QWENVOICE_DEBUG"]?.lowercased()).map { ["1", "true", "on", "yes"].contains($0) } ?? false
        let folder = debug ? "QwenVoice-Debug" : "QwenVoice"
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support"), isDirectory: true)
        return base.appendingPathComponent(folder, isDirectory: true)
    }
}

let vocelloCLIVersion = "0.1.0"
