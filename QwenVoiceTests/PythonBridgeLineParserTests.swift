import XCTest
@testable import QwenVoice

final class PythonBridgeLineParserTests: XCTestCase {

    func testParseValidResultResponse() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}"#
        let response = PythonBridgeLineParser.parse(json)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.id, 1)
        XCTAssertNotNil(response?.result)
        XCTAssertNil(response?.error)
        XCTAssertFalse(response?.isNotification ?? true)
    }

    func testParseValidNotification() {
        let json = #"{"jsonrpc":"2.0","method":"ready","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)
        XCTAssertNotNil(response)
        XCTAssertNil(response?.id)
        XCTAssertEqual(response?.method, "ready")
        XCTAssertTrue(response?.isNotification ?? false)
    }

    func testParseInvalidJSON() {
        let response = PythonBridgeLineParser.parse("not valid json {{{")
        XCTAssertNil(response)
    }

    func testParseEmptyString() {
        let response = PythonBridgeLineParser.parse("")
        XCTAssertNil(response)
    }

    func testIsHandledNotificationReady() {
        let json = #"{"jsonrpc":"2.0","method":"ready","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertTrue(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testIsHandledNotificationProgress() {
        let json = #"{"jsonrpc":"2.0","method":"progress","params":{"percent":50}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertTrue(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testIsHandledNotificationGenerationChunk() {
        let json = #"{"jsonrpc":"2.0","method":"generation_chunk","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertTrue(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testNonNotificationNotHandled() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertFalse(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testUnknownNotificationNotHandled() {
        let json = #"{"jsonrpc":"2.0","method":"unknown_event","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertFalse(PythonBridgeLineParser.isHandledNotification(response))
    }
}
