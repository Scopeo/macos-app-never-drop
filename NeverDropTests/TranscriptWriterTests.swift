@testable import NeverDrop
import XCTest

final class TranscriptWriterTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "TranscriptWriterTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        super.tearDown()
    }

    func testOpenCreatesFile() throws {
        let writer = TranscriptWriter(directoryPath: tempDir)
        try writer.open()
        defer { writer.close() }

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".txt"))
    }

    func testAppendWritesSpeakerHeader() throws {
        let writer = TranscriptWriter(directoryPath: tempDir)
        writer.userName = "Alice"
        try writer.open()

        writer.append(text: "Hello", speaker: .you, relativeTime: 65)
        writer.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        let content = try String(contentsOfFile: tempDir + "/" + files[0], encoding: .utf8)

        XCTAssertTrue(content.contains("[01:05] Alice:"))
        XCTAssertTrue(content.contains("Hello"))
    }

    func testSpeakerChangeInsertsNewHeader() throws {
        let writer = TranscriptWriter(directoryPath: tempDir)
        writer.userName = "Bob"
        try writer.open()

        writer.append(text: "Hi", speaker: .you, relativeTime: 0)
        writer.append(text: "Hey", speaker: .identified("1"), relativeTime: 3)
        writer.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        let content = try String(contentsOfFile: tempDir + "/" + files[0], encoding: .utf8)

        XCTAssertTrue(content.contains("Bob:"))
        XCTAssertTrue(content.contains("Speaker 1:"))
    }

    func testConsecutiveSameSpeakerNoExtraHeader() throws {
        let writer = TranscriptWriter(directoryPath: tempDir)
        try writer.open()

        writer.append(text: "One", speaker: .you, relativeTime: 0)
        writer.append(text: "Two", speaker: .you, relativeTime: 2)
        writer.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        let content = try String(contentsOfFile: tempDir + "/" + files[0], encoding: .utf8)

        let youCount = content.components(separatedBy: "You:").count - 1
        XCTAssertEqual(youCount, 1)
    }

    func testCloseIsIdempotent() throws {
        let writer = TranscriptWriter(directoryPath: tempDir)
        try writer.open()
        writer.close()
        writer.close()
    }

    func testAppendWithoutOpenIsNoOp() {
        let writer = TranscriptWriter(directoryPath: tempDir)
        writer.append(text: "Orphan", speaker: .you, relativeTime: 0)
    }
}
