import XCTest

// `MobilePausedOutputBuffer.swift` is compiled directly into this logic-test
// target (see project.yml): the retention policy for output that arrives while
// a terminal session is paused, exercised on the exact source the app ships.

final class PausedOutputBufferTests: XCTestCase {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    func testHoldsOutputUnderTheBoundAndDrainsInOrder() {
        var buffer = MobilePausedOutputBuffer(limit: 64)

        XCTAssertNil(buffer.append(bytes("first ")))
        XCTAssertNil(buffer.append(bytes("second")))
        XCTAssertEqual(buffer.count, 12)

        XCTAssertEqual(buffer.drain(), bytes("first second"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOverflowReturnsEverythingHeldIncludingTheNewChunkAndNothingIsLost() {
        var buffer = MobilePausedOutputBuffer(limit: 8)

        XCTAssertNil(buffer.append(bytes("12345678")), "exactly at the bound is still held")
        let overflow = buffer.append(bytes("9"))

        XCTAssertEqual(overflow, bytes("123456789"))
        XCTAssertTrue(buffer.isEmpty, "overflow hands back the bytes and empties the buffer")
    }

    func testSplitEscapeSequenceSurvivesAnOverflowBoundary() {
        // An escape sequence split across two frames must reach the emulator
        // contiguous and in order: overflow flushes, it never drops.
        var buffer = MobilePausedOutputBuffer(limit: 4)
        var delivered = Data()

        for chunk in ["ab", "\u{1b}[", "31m", "x"] {
            if let overflow = buffer.append(bytes(chunk)) {
                delivered.append(overflow)
            }
        }
        delivered.append(buffer.drain())

        XCTAssertEqual(delivered, bytes("ab\u{1b}[31mx"))
    }

    func testDrainOnEmptyBufferIsEmpty() {
        var buffer = MobilePausedOutputBuffer(limit: 4)
        XCTAssertEqual(buffer.drain(), Data())
    }
}
