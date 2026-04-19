import ExtensionFoundation
import Foundation

@main
final class VocelloEngineExtension: AppExtension {
    private let host = VocelloEngineExtensionHost()

    required init() {}

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: host.accept(connection:))
    }

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.qvoice.ios", name: "vocello-engine-service")
    }
}
