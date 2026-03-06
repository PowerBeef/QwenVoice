import Foundation

enum PythonBridgeLineParser {
    static func parse(_ line: String) -> RPCResponse? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RPCResponse.self, from: data)
    }

    static func isHandledNotification(_ response: RPCResponse) -> Bool {
        guard response.isNotification else { return false }
        return handledNotificationMethods.contains(response.method ?? "")
    }

    private static let handledNotificationMethods: Set<String> = [
        "ready",
        "progress",
    ]
}
