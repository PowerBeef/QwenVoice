import XCTest
@testable import QwenVoiceCore

@MainActor
final class AllocationRetryAnnotationTests: XCTestCase {
    func testRetryAnnotationPreservesResultAndRecordsAttempt() {
        let original = GenerationResult(
            audioPath: "fixture.wav",
            durationSeconds: 1.25,
            streamSessionDirectory: nil,
            usedStreaming: true,
            diagnosticTimingsMS: ["existing": 4],
            diagnosticBooleanFlags: ["existing": true],
            diagnosticStringFlags: ["identity": "fixture"]
        )

        let annotated = MLXTTSEngine.annotatingAllocationRetry(
            original,
            streamingUsed: true,
            attempted: true,
            succeeded: true,
            cleanupMS: 17
        )

        XCTAssertEqual(annotated.audioPath, original.audioPath)
        XCTAssertEqual(annotated.diagnosticTimingsMS["existing"], 4)
        XCTAssertEqual(annotated.diagnosticTimingsMS["allocationRetryCleanupMS"], 17)
        XCTAssertEqual(annotated.diagnosticBooleanFlags["existing"], true)
        XCTAssertEqual(annotated.diagnosticBooleanFlags["allocationRetryAttempted"], true)
        XCTAssertEqual(annotated.diagnosticBooleanFlags["allocationRetrySucceeded"], true)
        XCTAssertEqual(annotated.diagnosticBooleanFlags["allocationRetryStreamingUsed"], true)
        XCTAssertEqual(annotated.diagnosticStringFlags["identity"], "fixture")
    }

    func testNoRetryIsExplicitRatherThanSilentlyUnannotated() {
        let annotated = MLXTTSEngine.annotatingAllocationRetry(
            GenerationResult(
                audioPath: "fixture.wav",
                durationSeconds: 1,
                streamSessionDirectory: nil,
                usedStreaming: false
            ),
            streamingUsed: false,
            attempted: false,
            succeeded: false,
            cleanupMS: nil
        )

        XCTAssertEqual(annotated.diagnosticBooleanFlags["allocationRetryAttempted"], false)
        XCTAssertEqual(annotated.diagnosticBooleanFlags["allocationRetrySucceeded"], false)
        XCTAssertNil(annotated.diagnosticTimingsMS["allocationRetryCleanupMS"])
    }
}
