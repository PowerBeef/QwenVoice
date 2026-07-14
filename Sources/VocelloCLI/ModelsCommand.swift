import Foundation
import QwenVoiceCore

/// `vocello models` — read-only inventory of the contract's models: install state,
/// on-disk size, and (for `status`) any missing required files. No download
/// machinery — honors the no-bundled-weights framing. Uses the lightweight
/// registry bootstrap (no engine boot).
enum ModelsCommand {
    struct ModelJSON: Encodable {
        let id: String
        let mode: String
        let name: String
        let installed: Bool
        let missingPaths: [String]
        let installedBytes: Int64
        let estimatedDownloadBytes: Int64?
    }

    @MainActor
    static func run(_ argv: [String]) async throws {
        var argv = argv
        let action = argv.first?.lowercased() ?? "list"
        if action == "help" || action == "--help" { printHelp(); return }
        if action == "install" {
            argv.removeFirst()
            try await runInstall(argv)
            return
        }
        let detailed = (action == "status")
        if !argv.isEmpty, action == "list" || action == "ls" || action == "status" { argv.removeFirst() }
        guard action == "list" || action == "ls" || action == "status" || action.hasPrefix("--") else {
            throw CLIError("unknown models action '\(action)' (use list | status [<id>])")
        }

        let args = Args(argv)
        CLIOutput.configure(args)
        let ctx = try CLIRuntime.bootstrapRegistryOnly(
            dataDirectory: CLIPaths.dataDirectory(override: args.string("data-dir")),
            manifestOverride: args.string("manifest").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        let onlyID = args.positionals.first  // optional `status <id>` / `list <id>` filter

        var rows: [ModelJSON] = []
        for m in ctx.registry.models {
            if let onlyID, m.id != onlyID { continue }
            let installed: Bool
            let missing: [String]
            switch ctx.registry.availability(forModelID: m.id, in: ctx.modelsDirectory) {
            case .available: installed = true; missing = []
            case .unavailable(_, let paths): installed = false; missing = paths
            case .unknown: installed = false; missing = []
            }
            rows.append(ModelJSON(
                id: m.id, mode: m.mode.rawValue, name: m.name,
                installed: installed, missingPaths: missing,
                installedBytes: directorySize(m.installDirectory(in: ctx.modelsDirectory)),
                estimatedDownloadBytes: m.estimatedDownloadBytes))
        }
        if let onlyID, rows.isEmpty { throw CLIError("no model '\(onlyID)' in the contract") }

        if args.flag("json") { emitJSON(rows); return }

        guard !rows.isEmpty else { print("(no models in contract)"); return }
        for r in rows {
            let mark = r.installed ? "✓" : (r.missingPaths.isEmpty ? "?" : "✗")
            let size = r.installed
                ? humanBytes(r.installedBytes)
                : (r.estimatedDownloadBytes.map { "~\(humanBytes($0)) to download" } ?? "not installed")
            print("\(mark) \(r.id)\t[\(r.mode)]\t\(size)")
            if detailed {
                for p in r.missingPaths { print("    missing: \(p)") }
            }
        }
    }

    /// `vocello models install <id>` — download a model via the shared `HuggingFaceDownloader`
    /// engine (the same one the macOS app uses) into the shared models directory. A
    /// CLI-installed model is immediately usable by the app, and vice-versa.
    @MainActor
    static func runInstall(_ argv: [String]) async throws {
        let args = Args(argv)
        CLIOutput.configure(args)

        guard let modelID = args.positionals.first?.lowercased() else {
            throw CLIError("install requires a model id (e.g. pro_custom_speed). Run `vocello models list` for ids.")
        }

        let ctx = try CLIRuntime.bootstrapRegistryOnly(
            dataDirectory: CLIPaths.dataDirectory(override: args.string("data-dir")),
            manifestOverride: args.string("manifest").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        guard let descriptor = ctx.registry.model(id: modelID) else {
            throw CLIError("unknown model id '\(modelID)' (run `vocello models list` for valid ids)")
        }

        if case .available = ctx.registry.availability(forModelID: modelID, in: ctx.modelsDirectory) {
            note("Already installed: \(modelID)")
            return
        }

        let targetDir = descriptor.installDirectory(in: ctx.modelsDirectory)
        let repo = descriptor.huggingFaceRepo
        let revision = descriptor.huggingFaceRevision ?? "main"
        note("Installing \(modelID) from \(repo) (revision \(revision.prefix(7))\u{2026})")

        let diagnostics = ModelDownloadDiagnosticsStore(
            directory: ctx.modelsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("diagnostics/model-downloads", isDirectory: true)
        )
        let downloader = HuggingFaceDownloader(
            progressHandler: { progress in
                diagnostics.record(progress: progress)
                let pct = progress.totalBytes > 0
                    ? Int(Double(progress.downloadedBytes) / Double(progress.totalBytes) * 100)
                    : 0
                let speed = progress.bytesPerSecond.map { "\(humanBytes($0))/s" } ?? "—"
                let eta = progress.estimatedSecondsRemaining.map { " · ETA \(max(1, Int($0.rounded())))s" } ?? ""
                noteVerbose("  \(progress.phase.rawValue) · \(pct)% · \(humanBytes(progress.downloadedBytes))/\(humanBytes(progress.totalBytes)) · \(speed)\(eta)")
            },
            transferMetricsHandler: { diagnostics.record(metrics: $0) }
        )

        do {
            try await downloader.downloadRepo(repo: repo, revision: revision, to: targetDir)
            diagnostics.recordSuccess(
                expectedBytes: descriptor.estimatedDownloadBytes ?? directorySize(targetDir)
            )
        } catch {
            diagnostics.recordFailure(classification: "download", message: error.localizedDescription)
            throw error
        }

        print("✓ Installed \(modelID) (\(humanBytes(directorySize(targetDir))))")
    }

    static func printHelp() {
        print("""
        vocello models — inventory and install models

        Usage:
          vocello models list [--json]
          vocello models status [<id>] [--json]               # adds missing-file detail
          vocello models install <id> [--verbose]             # download into the shared models dir

        <id> may be a variant-scoped id (pro_custom_speed / pro_custom_quality / …) or a
        base alias (pro_custom → preferred variant). Same engine + dir as the macOS app,
        so a CLI-installed model is immediately usable in the app.

        Options:
          --json       emit JSON instead of a table (list/status)
          --verbose    show per-update download progress (install)
          --data-dir   runtime dir (default ~/Library/Application Support/QwenVoice[-Debug])
          --manifest   override path to qwenvoice_contract.json
        """)
    }
}
