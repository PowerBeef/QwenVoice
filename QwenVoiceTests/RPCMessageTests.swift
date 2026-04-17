import XCTest
@testable import QwenVoice

final class RPCMessageTests: XCTestCase {

    // MARK: - RPCValue round-trip encoding/decoding

    func testStringRoundTrip() throws {
        let value = RPCValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testIntRoundTrip() throws {
        let value = RPCValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.intValue, 42)
    }

    func testDoubleRoundTrip() throws {
        let value = RPCValue.double(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        let decodedDouble = try XCTUnwrap(decoded.doubleValue)
        XCTAssertEqual(decodedDouble, 3.14, accuracy: 0.001)
    }

    func testBoolRoundTrip() throws {
        let value = RPCValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testNullRoundTrip() throws {
        let value = RPCValue.null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testArrayRoundTrip() throws {
        let value = RPCValue.array([.string("a"), .int(1)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.arrayValue?.count, 2)
    }

    func testObjectRoundTrip() throws {
        let value = RPCValue.object(["key": .string("val")])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.objectValue?["key"]?.stringValue, "val")
    }

    func testModelInfoDecodesFromRPCValue() throws {
        let value = RPCValue.object([
            "id": .string("pro_clone"),
            "name": .string("Qwen Voice Clone"),
            "folder": .string("QwenVoiceClone"),
            "mode": .string("clone"),
            "tier": .string("pro"),
            "output_subfolder": .string("Clones"),
            "hugging_face_repo": .string("qwen/pro-clone"),
            "required_relative_paths": .array([.string("weights/model.safetensors"), .string("config.json")]),
            "resolved_path": .string("/tmp/QwenVoiceClone"),
            "downloaded": .bool(true),
            "complete": .bool(false),
            "repairable": .bool(true),
            "missing_required_paths": .array([.string("config.json")]),
            "size_bytes": .int(1024),
            "mlx_audio_version": .string("0.4.2"),
            "supports_streaming": .bool(true),
            "supports_prepared_clone": .bool(true),
            "supports_clone_streaming": .bool(true),
            "supports_batch": .bool(true),
        ])

        let decoded = try value.decoded(as: ModelInfo.self)

        XCTAssertEqual(decoded.id, "pro_clone")
        XCTAssertEqual(decoded.mode, .clone)
        XCTAssertEqual(decoded.resolvedPath, "/tmp/QwenVoiceClone")
        XCTAssertTrue(decoded.downloaded)
        XCTAssertFalse(decoded.complete)
        XCTAssertTrue(decoded.repairable)
        XCTAssertEqual(decoded.missingRequiredPaths, ["config.json"])
        XCTAssertEqual(decoded.sizeBytes, 1024)
    }

    // MARK: - RPCResponse decoding variants

    func testDecodeResultResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCResponse.self, from: data)
        XCTAssertEqual(response.id, 1)
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
        XCTAssertFalse(response.isNotification)
        XCTAssertEqual(response.resultDict["status"]?.stringValue, "ok")
    }

    func testDecodeErrorResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCResponse.self, from: data)
        XCTAssertEqual(response.id, 2)
        XCTAssertNil(response.result)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(response.error?.message, "Method not found")
    }

    func testDecodeNotification() throws {
        let json = #"{"jsonrpc":"2.0","method":"progress","params":{"percent":50}}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCResponse.self, from: data)
        XCTAssertNil(response.id)
        XCTAssertEqual(response.method, "progress")
        XCTAssertTrue(response.isNotification)
    }

    // MARK: - RPCRequest encoding

    func testRequestEncoding() throws {
        let request = RPCRequest(id: 1, method: "ping", params: [:])
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(dict["id"] as? Int, 1)
        XCTAssertEqual(dict["method"] as? String, "ping")
    }
}
