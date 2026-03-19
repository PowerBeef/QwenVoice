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
