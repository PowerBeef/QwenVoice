import Foundation
import QwenVoiceCore

/// In-process engine for the CLI. Mirrors `EngineServiceHost`'s runtime wiring
/// (manifest → platform-expanded registry → `NativeRuntimeFactory.make` →
/// `engine.initialize`) but without XPC — the CLI links `QwenVoiceCore` and
/// drives `MLXTTSEngine` directly.
@MainActor
struct CLIRuntime {
    let engine: MLXTTSEngine
    let registry: ContractBackedModelRegistry
    let dataDirectory: URL

    static func bootstrap(dataDirectory: URL, manifestOverride: URL?) async throws -> CLIRuntime {
        let manifestURL = try manifestOverride ?? locateManifestURL()
        let deviceClass = NativeMemoryPolicyResolver.deviceClass()
        let registry = try ContractBackedModelRegistry(manifestURL: manifestURL)
            .expandedForPlatform(.macOS, deviceClass: deviceClass, includeBaseAliases: true)
        // Same tiered prewarm policy as the XPC host: defer the dedicated custom
        // prewarm on the 8 GB floor tier (the work folds into the first generation).
        let customPrewarmPolicy: NativeCustomPrewarmPolicy =
            deviceClass == .floor8GBMac ? .skipDedicatedCustomPrewarm : .eager
        let runtime = try NativeRuntimeFactory.make(
            registry: registry,
            paths: .rooted(at: dataDirectory),
            storeVersionSeed: storeVersionSeed(),
            customPrewarmPolicy: customPrewarmPolicy
        )
        try await runtime.engine.initialize(appSupportDirectory: dataDirectory)
        return CLIRuntime(engine: runtime.engine, registry: registry, dataDirectory: dataDirectory)
    }

    /// Resolve a (mode, variant) to the variant-scoped model id the engine loads
    /// (e.g. `pro_custom_speed` / `pro_custom_quality`).
    func modelID(mode: GenerationMode, quality: Bool) throws -> String {
        guard let base = registry.model(for: mode) else {
            throw CLIError("No model for mode '\(mode.rawValue)' in the manifest.")
        }
        let variants = base.platformVariants(for: .macOS)
        guard !variants.isEmpty else {
            throw CLIError("No macOS variants for mode '\(mode.rawValue)'.")
        }
        let wanted: ModelVariantKind = quality ? .quality : .speed
        guard let variant = variants.first(where: { $0.kind == wanted }) else {
            let available = variants.map { $0.kind.rawValue }.joined(separator: ", ")
            throw CLIError("No \(quality ? "Quality" : "Speed") variant for '\(mode.rawValue)' (have: \(available)).")
        }
        return base.variantScopedID(for: variant)
    }

    /// Default Custom Voice speaker id from the contract (e.g. Aiden).
    var defaultSpeakerID: String { registry.defaultSpeaker.id }

    // MARK: - Manifest / version

    static func locateManifestURL() throws -> URL {
        // 1) Bundled resource (shipped CLI). 2) repo-relative when run from the
        // repo root (dev + benchmarks). 3) next to the executable.
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        let fm = FileManager.default
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        let candidates = [
            fm.currentDirectoryPath + "/Sources/Resources/qwenvoice_contract.json",
            exeDir + "/qwenvoice_contract.json",
            exeDir + "/../../../../Sources/Resources/qwenvoice_contract.json",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CLIError("Could not locate qwenvoice_contract.json. Pass --manifest <path>.")
    }

    static func storeVersionSeed(bundle: Bundle = .main) -> String {
        let id = bundle.bundleIdentifier ?? "com.qwenvoice.cli"
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? vocelloCLIVersion
        let build = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return "\(id)|\(marketing)|\(build)"
    }
}
