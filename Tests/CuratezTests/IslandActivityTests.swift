import XCTest
@testable import Curatez

final class IslandActivityTests: XCTestCase {
    func testClipboardRecognizerSeparatesWebLinksFromPlainText() throws {
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("https://example.com/articles/42?q=swift"),
            .webURL(try XCTUnwrap(URL(string: "https://example.com/articles/42?q=swift")))
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("www.example.com/article"),
            .webURL(try XCTUnwrap(URL(string: "https://www.example.com/article")))
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("example.com/article"),
            .webURL(try XCTUnwrap(URL(string: "https://example.com/article")))
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("localhost:3000/board?id=7"),
            .webURL(try XCTUnwrap(URL(string: "https://localhost:3000/board?id=7")))
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("http://127.0.0.1:8080/status"),
            .webURL(try XCTUnwrap(URL(string: "http://127.0.0.1:8080/status")))
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("这是一段包含 example.com 的普通文本"),
            .text("这是一段包含 example.com 的普通文本")
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("ftp://example.com/file"),
            .text("ftp://example.com/file")
        )
        XCTAssertEqual(
            ClipboardTextRecognizer.recognize("report.pdf"),
            .webURL(try XCTUnwrap(URL(string: "https://report.pdf")))
        )
    }

    func testVideoSupportRecognizesOnlyDirectPlayableVideoURLs() throws {
        XCTAssertTrue(VideoSupport.isPlayableRemoteURL(
            try XCTUnwrap(URL(string: "https://cdn.example.com/demo.mp4"))
        ))
        XCTAssertTrue(VideoSupport.isPlayableRemoteURL(
            try XCTUnwrap(URL(string: "https://cdn.example.com/live/stream.m3u8?token=abc"))
        ))
        XCTAssertFalse(VideoSupport.isPlayableRemoteURL(
            try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=123"))
        ))
        XCTAssertFalse(VideoSupport.isPlayableRemoteURL(
            try XCTUnwrap(URL(string: "file:///tmp/demo.mov"))
        ))
    }

    func testEveryLifecycleStatusHasAnExplicitBloubPresentation() {
        let expected: [(CuratezTaskStatus, BloubExpression, BloubMotion)] = [
            (.idle, .neutral, .breathe),
            (.ready, .attentive, .breathe),
            (.processing, .focused, .think),
            (.succeeded, .pleased, .celebrate),
            (.needsAttention, .surprised, .pulse),
            (.failed, .concerned, .shake),
            (.paused, .sleeping, .doze)
        ]

        for (status, expression, motion) in expected {
            let presentation = CuratezIslandActivity(
                task: .browserSnapshot,
                status: status
            ).bloubPresentation
            XCTAssertEqual(presentation.expression, expression, "Unexpected expression for \(status)")
            XCTAssertEqual(presentation.motion, motion, "Unexpected motion for \(status)")
        }
    }

    func testOnlyAttentionStateShowsNotificationDot() {
        for status in [
            CuratezTaskStatus.idle,
            .ready,
            .processing,
            .succeeded,
            .needsAttention,
            .failed,
            .paused
        ] {
            let presentation = CuratezIslandActivity(task: .captureText, status: status)
                .bloubPresentation
            XCTAssertEqual(presentation.showsNotificationDot, status == .needsAttention)
        }
    }

    func testPointerTargetUsesScreenRelativeAnglesAndClampsAtEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let center = CGPoint(x: 500, y: 400)

        XCTAssertEqual(
            BloubPointerTarget.resolve(
                pointer: center,
                avatarCenter: center,
                screenFrame: screen
            ),
            BloubPointerTarget(yaw: 0, pitch: 0)
        )
        XCTAssertEqual(
            BloubPointerTarget.resolve(
                pointer: CGPoint(x: 2000, y: -1000),
                avatarCenter: center,
                screenFrame: screen
            ),
            BloubPointerTarget(yaw: 16, pitch: -13)
        )
        XCTAssertEqual(
            BloubPointerTarget.resolve(
                pointer: CGPoint(x: 0, y: 800),
                avatarCenter: center,
                screenFrame: screen
            ),
            BloubPointerTarget(yaw: -16, pitch: 13)
        )
    }

    func testRandomIdleSequenceUsesTheRequestedExpressionDurations() throws {
        let start = try XCTUnwrap(BloubIdleSequence.sequenceBlend(at: 0))
        XCTAssertEqual(start.from.expression, .neutral)
        XCTAssertEqual(start.to.expression, .curious)

        let curious = try XCTUnwrap(BloubIdleSequence.sequenceBlend(at: 0.72))
        XCTAssertEqual(curious.from.expression, .curious)
        XCTAssertEqual(curious.to.expression, .curious)
        XCTAssertEqual(curious.from.motion, .breathe)
        XCTAssertEqual(curious.to.motion, .breathe)

        let changingToShy = try XCTUnwrap(BloubIdleSequence.sequenceBlend(at: 1.3))
        XCTAssertEqual(changingToShy.from.expression, .curious)
        XCTAssertEqual(changingToShy.to.expression, .shy)

        let shy = try XCTUnwrap(BloubIdleSequence.sequenceBlend(at: 2))
        XCTAssertEqual(shy.from.expression, .shy)
        XCTAssertEqual(shy.to.expression, .shy)
        XCTAssertEqual(shy.from.motion, .breathe)
        XCTAssertEqual(shy.to.motion, .breathe)

        let returning = try XCTUnwrap(BloubIdleSequence.sequenceBlend(at: 2.6))
        XCTAssertEqual(returning.from.expression, .shy)
        XCTAssertEqual(returning.to.expression, .neutral)

        XCTAssertNil(BloubIdleSequence.sequenceBlend(at: 2.8))
    }
}
