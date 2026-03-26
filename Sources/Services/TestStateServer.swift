import Foundation
import Network

/// Lightweight HTTP server for test-mode UI state queries.
/// Listens on localhost:19876. Only starts when UITestAutomationSupport.isEnabled.
final class TestStateServer: @unchecked Sendable {
    static let port: UInt16 = 19876
    private var listener: NWListener?

    func start() {
        guard UITestAutomationSupport.isEnabled else { return }

        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            print("[TestStateServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                print("[TestStateServer] Listening on localhost:\(Self.port)")
            }
        }

        listener?.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let data, error == nil else {
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            self?.routeRequest(request, connection: connection)
        }
    }

    private func routeRequest(_ request: String, connection: NWConnection) {
        let path = extractPath(from: request)

        switch path {
        case "/health":
            sendJSON(["ok": true], connection: connection)
        case "/state":
            Task { @MainActor in
                let state = TestStateProvider.shared.snapshot()
                self.sendJSON(state, connection: connection)
            }
        case let p where p.hasPrefix("/navigate"):
            handleNavigate(path: p, connection: connection)
        case let p where p.hasPrefix("/activate-window"):
            handleActivateWindow(path: p, connection: connection)
        case let p where p.hasPrefix("/capture-screenshot"):
            handleCaptureScreenshot(path: p, connection: connection)
        case let p where p.hasPrefix("/start-generation"):
            handleStartGeneration(path: p, connection: connection)
        case let p where p.hasPrefix("/start-preview"):
            handleStartGeneration(path: p, connection: connection, legacyPreviewRoute: true)
        default:
            sendJSON(["error": "not_found", "path": path], status: 404, connection: connection)
        }
    }

    private func handleNavigate(path: String, connection: NWConnection) {
        guard let screen = extractQueryParam(from: path, key: "screen") else {
            sendJSON(["error": "missing_screen_param"], status: 400, connection: connection)
            return
        }

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .testNavigateToScreen,
                object: nil,
                userInfo: ["screen": screen]
            )
            // Brief delay for navigation to take effect
            try? await Task.sleep(for: .milliseconds(200))
            let state = TestStateProvider.shared.snapshot()
            self.sendJSON(state, connection: connection)
        }
    }

    private func handleActivateWindow(path: String, connection: NWConnection) {
        let reason = extractQueryParam(from: path, key: "reason") ?? "remote_request"

        Task { @MainActor in
            _ = await UITestWindowCoordinator.shared.activateMainWindow(reason: reason)
            let state = TestStateProvider.shared.snapshot()
            self.sendJSON(state, connection: connection)
        }
    }

    private func handleCaptureScreenshot(path: String, connection: NWConnection) {
        guard let name = extractQueryParam(from: path, key: "name"), !name.isEmpty else {
            sendJSON(["error": "missing_name_param"], status: 400, connection: connection)
            return
        }

        Task { @MainActor in
            let result = UITestWindowCoordinator.shared.captureMainWindowScreenshot(name: name)
            var state = TestStateProvider.shared.snapshot()
            state["screenshotCaptured"] = result.captured
            state["screenshotName"] = name
            state["screenshotCaptureMode"] = result.mode.rawValue
            state["screenshotFailureReason"] = result.failureReason ?? ""
            self.sendJSON(state, connection: connection)
        }
    }

    private func handleStartGeneration(
        path: String,
        connection: NWConnection,
        legacyPreviewRoute: Bool = false
    ) {
        guard let screen = extractQueryParam(from: path, key: "screen") else {
            sendJSON(["error": "missing_screen_param"], status: 400, connection: connection)
            return
        }

        let text = extractQueryParam(from: path, key: "text") ?? ""
        let voiceDescription = extractQueryParam(from: path, key: "voiceDescription")
        let emotion = extractQueryParam(from: path, key: "emotion")
        let referenceAudioPath = extractQueryParam(from: path, key: "referenceAudioPath")
        let referenceTranscript = extractQueryParam(from: path, key: "referenceTranscript")

        Task { @MainActor in
            var userInfo: [String: String] = [
                "screen": screen,
                "text": text,
            ]
            if let voiceDescription, !voiceDescription.isEmpty {
                userInfo["voiceDescription"] = voiceDescription
            }
            if let emotion, !emotion.isEmpty {
                userInfo["emotion"] = emotion
            }
            if let referenceAudioPath, !referenceAudioPath.isEmpty {
                userInfo["referenceAudioPath"] = referenceAudioPath
            }
            if let referenceTranscript, !referenceTranscript.isEmpty {
                userInfo["referenceTranscript"] = referenceTranscript
            }

            NotificationCenter.default.post(
                name: .testStartGeneration,
                object: nil,
                userInfo: userInfo
            )
            try? await Task.sleep(for: .milliseconds(200))
            let state = TestStateProvider.shared.snapshot()
            self.sendJSON(state, connection: connection)
        }
    }

    private func sendJSON(_ dict: [String: Any], status: Int = 200, connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: dict) else {
            connection.cancel()
            return
        }

        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func extractPath(from request: String) -> String {
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1])
    }

    private func extractQueryParam(from path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, String(kv[0]) == key {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }
}

extension Notification.Name {
    static let testNavigateToScreen = Notification.Name("testNavigateToScreen")
    static let testStartLivePreview = Notification.Name("testStartLivePreview")
    static let testStartGeneration = Notification.Name("testStartGeneration")
}
