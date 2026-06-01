import ExtensionFoundation
import Foundation

/// iOS TTS engine, hosted out-of-process via **ExtensionKit** — the iOS
/// counterpart to the macOS `QwenVoiceEngineService` XPC service. Heavy MLX
/// generation runs here so the app process stays light. Connections are handed
/// to `VocelloEngineExtensionHost`, which adapts the XPC wire protocol.
///
/// Compile-safe only on `main`: on-device execution is deferred pending Apple's
/// increased-memory entitlement (see CLAUDE.md "Release & iPhone status").
@main
final class VocelloEngineExtension: AppExtension {
    private let host = VocelloEngineExtensionHost()

    required init() {}

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: host.accept(connection:))
    }

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.patricedery.vocello", name: "vocello-engine-service")
    }
}
