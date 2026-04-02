import Foundation

struct PreparedRPCRequest {
    let id: Int
    let lineData: Data
}

@MainActor
final class PythonJSONRPCTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<RPCValue, Error>
        let reportsErrors: Bool
    }

    private let writeData: @MainActor (Data) throws -> Void
    private let notificationHandler: @MainActor (RPCResponse) -> Void
    private let errorReporter: @MainActor (String) -> Void
    private let runningCheck: @MainActor () -> Bool

    private var requestID = 0
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var readBuffer = ""

    init(
        runningCheck: @escaping @MainActor () -> Bool,
        writeData: @escaping @MainActor (Data) throws -> Void,
        notificationHandler: @escaping @MainActor (RPCResponse) -> Void,
        errorReporter: @escaping @MainActor (String) -> Void
    ) {
        self.runningCheck = runningCheck
        self.writeData = writeData
        self.notificationHandler = notificationHandler
        self.errorReporter = errorReporter
    }

    func makeRequest(method: String, params: [String: RPCValue] = [:]) throws -> PreparedRPCRequest {
        requestID += 1
        let id = requestID

        let request = RPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard var line = String(data: data, encoding: .utf8) else {
            throw PythonBridgeError.encodingError
        }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else {
            throw PythonBridgeError.encodingError
        }

        return PreparedRPCRequest(id: id, lineData: lineData)
    }

    func execute(
        _ preparedRequest: PreparedRPCRequest,
        reportsErrors: Bool,
        timeout: UInt64
    ) async throws -> RPCValue {
        guard runningCheck() else {
            throw PythonBridgeError.processNotRunning
        }

        return try await withThrowingTaskGroup(of: RPCValue.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RPCValue, any Error>) in
                    Task { @MainActor in
                        self.pendingRequests[preparedRequest.id] = PendingRequest(
                            continuation: continuation,
                            reportsErrors: reportsErrors
                        )
                        do {
                            try self.writeData(preparedRequest.lineData)
                        } catch {
                            self.pendingRequests.removeValue(forKey: preparedRequest.id)
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                throw PythonBridgeError.timeout(seconds: Int(timeout))
            }

            guard let first = try await group.next() else {
                throw PythonBridgeError.timeout(seconds: Int(timeout))
            }
            group.cancelAll()
            return first
        }
    }

    func callArray(
        _ method: String,
        params: [String: RPCValue] = [:],
        timeout: UInt64
    ) async throws -> [RPCValue] {
        let request = try makeRequest(method: method, params: params)
        let result = try await execute(request, reportsErrors: true, timeout: timeout)
        return result.arrayValue ?? []
    }

    func processOutputChunk(_ text: String) {
        readBuffer += text

        while let newlineIndex = readBuffer.firstIndex(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<newlineIndex])
            readBuffer = String(readBuffer[readBuffer.index(after: newlineIndex)...])

            if !line.isEmpty {
                processLine(line)
            }
        }
    }

    func cancelAllPending(error: Error) {
        for (_, pendingRequest) in pendingRequests {
            pendingRequest.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    func reset() {
        readBuffer = ""
    }

    private func processLine(_ line: String) {
        guard let response = PythonBridgeLineParser.parse(line) else {
            #if DEBUG
            print("[PythonBridge] Unparseable line: \(line)")
            #endif
            return
        }

        if response.isNotification {
            guard PythonBridgeLineParser.isHandledNotification(response) else { return }
            notificationHandler(response)
            return
        }

        guard let id = response.id,
              let pendingRequest = pendingRequests.removeValue(forKey: id) else {
            return
        }

        if let error = response.error {
            if pendingRequest.reportsErrors {
                errorReporter(error.message)
            }
            pendingRequest.continuation.resume(
                throwing: PythonBridgeError.rpcError(code: error.code, message: error.message)
            )
        } else if let result = response.result {
            pendingRequest.continuation.resume(returning: result)
        } else {
            pendingRequest.continuation.resume(returning: .null)
        }
    }
}
