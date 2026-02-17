@testable import NeverDrop
import CoreAudio
import XCTest

final class MockMicMonitor: MicrophoneMonitoring, @unchecked Sendable {
    private var continuation: AsyncStream<Bool>.Continuation?

    func statusStream() -> AsyncStream<Bool> {
        AsyncStream { self.continuation = $0 }
    }

    func emit(_ active: Bool) {
        continuation?.yield(active)
    }

    func excludeDevice(_ deviceID: AudioDeviceID) {}
    func clearExclusions() {}
}

@MainActor
final class CallDetectorTests: XCTestCase {

    func testInitialStateIsIdle() {
        let detector = CallDetector(micMonitor: MockMicMonitor())
        XCTAssertEqual(detector.state, .idle)
    }

    func testUserAcceptRequiresCallDetected() {
        let detector = CallDetector(micMonitor: MockMicMonitor())
        detector.userAcceptedTranscription()
        XCTAssertEqual(detector.state, .idle)
    }

    func testUserDeclineRequiresCallDetected() {
        let detector = CallDetector(micMonitor: MockMicMonitor())
        detector.userDeclinedTranscription()
        XCTAssertEqual(detector.state, .idle)
    }

    func testStopRecordingRequiresRecording() {
        let detector = CallDetector(micMonitor: MockMicMonitor())
        var endedFired = false
        detector.onCallEnded = { endedFired = true }
        detector.stopRecording()
        XCTAssertFalse(endedFired)
        XCTAssertEqual(detector.state, .idle)
    }

    func testResetToIdle() {
        let detector = CallDetector(micMonitor: MockMicMonitor())
        detector.resetToIdle()
        XCTAssertEqual(detector.state, .idle)
    }

    func testMicActivationTriggersCallDetected() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50)
        )

        let expectation = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { expectation.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(detector.state, .callDetected)
        detector.stopMonitoring()
    }

    func testAcceptTransitionsToRecording() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50)
        )

        let detected = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { detected.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [detected], timeout: 1.0)
        detector.userAcceptedTranscription()
        XCTAssertEqual(detector.state, .recording)
        detector.stopMonitoring()
    }

    func testStopRecordingFiresCallEnded() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50)
        )

        let detected = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { detected.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [detected], timeout: 1.0)
        detector.userAcceptedTranscription()

        var endedFired = false
        detector.onCallEnded = { endedFired = true }
        detector.stopRecording()

        XCTAssertTrue(endedFired)
        XCTAssertEqual(detector.state, .idle)
        detector.stopMonitoring()
    }

    func testStopRecordingDoesNotRecurse() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50)
        )

        let detected = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { detected.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [detected], timeout: 1.0)
        detector.userAcceptedTranscription()

        var callEndedCount = 0
        detector.onCallEnded = { callEndedCount += 1 }
        detector.stopRecording()
        XCTAssertEqual(callEndedCount, 1)

        detector.stopRecording()
        XCTAssertEqual(callEndedCount, 1)
        detector.stopMonitoring()
    }

    func testCooldownBlocksImmediateRedetection() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50),
            postStopCooldown: .seconds(10)
        )

        let detected = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { detected.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [detected], timeout: 1.0)
        detector.userAcceptedTranscription()
        detector.resetToIdle()
        XCTAssertEqual(detector.state, .idle)

        let notDetected = XCTestExpectation(description: "Should not detect")
        notDetected.isInverted = true
        detector.onCallDetected = { notDetected.fulfill() }

        mock.emit(true)
        await fulfillment(of: [notDetected], timeout: 0.3)
        XCTAssertEqual(detector.state, .idle)
        detector.stopMonitoring()
    }

    func testDeactivationDuringRecordingTriggersEnd() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50),
            deactivationDelay: .milliseconds(100)
        )

        let detected = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { detected.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [detected], timeout: 1.0)
        detector.userAcceptedTranscription()
        XCTAssertEqual(detector.state, .recording)

        let ended = XCTestExpectation(description: "Call ended")
        detector.onCallEnded = { ended.fulfill() }

        mock.emit(false)
        await fulfillment(of: [ended], timeout: 1.0)
        XCTAssertEqual(detector.state, .idle)
        detector.stopMonitoring()
    }

    func testMicDeactivationWhileCallDetectedResetsToIdle() async throws {
        let mock = MockMicMonitor()
        let detector = CallDetector(
            micMonitor: mock,
            activationDelay: .milliseconds(50)
        )

        let detected = XCTestExpectation(description: "Call detected")
        detector.onCallDetected = { detected.fulfill() }

        detector.startMonitoring()
        await Task.yield()
        mock.emit(true)

        await fulfillment(of: [detected], timeout: 1.0)
        XCTAssertEqual(detector.state, .callDetected)

        mock.emit(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(detector.state, .idle)
        detector.stopMonitoring()
    }
}
