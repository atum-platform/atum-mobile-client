import XCTest
@testable import AtumChat

final class MediaPolicyTests: XCTestCase {
    func testMediaKindUsesMimetypeBeforeFilenameAndExposesDesignFacts() {
        let kind = MediaKind(mimetype: "application/pdf; charset=binary", filename: "notes.docx")
        XCTAssertEqual(kind, .pdf)
        XCTAssertEqual(kind.glyphAlias, "FileTypePdf")
        XCTAssertEqual(kind.copyKey, .mediaKindPDF)

        XCTAssertEqual(MediaKind(mimetype: "TEXT/CSV", filename: "notes.pdf"), .spreadsheet)
        XCTAssertEqual(MediaKind(mimetype: "video/mp4", filename: "notes.pdf"), .video)
        XCTAssertEqual(MediaKind(mimetype: "image/svg+xml", filename: "drawing.svg"), .image)
        XCTAssertFalse(MediaKind.usesImagePresentation(mimetype: "image/svg+xml", filename: "drawing.svg"),
                       "SVG is a file row even when Matrix carries it as m.image")
        XCTAssertTrue(MediaKind.usesImagePresentation(mimetype: "image/jpeg", filename: "photo.jpg"))
    }

    func testMediaKindFallsBackToCaseInsensitiveFilenameExtension() {
        let cases: [(String, MediaKind)] = [
            ("report.PDF", .pdf), ("notes.DOCX", .document), ("table.Numbers", .spreadsheet),
            ("slides.KEY", .presentation), ("archive.7Z", .archive)
        ]
        for (filename, expected) in cases {
            XCTAssertEqual(MediaKind(mimetype: "application/octet-stream", filename: filename), expected, filename)
        }
        XCTAssertEqual(MediaKind(mimetype: nil, filename: "untyped.bin"), .other)
        XCTAssertEqual(MediaKind.other.glyphAlias, "File")
        XCTAssertEqual(MediaKind.other.copyKey, .file)
        XCTAssertEqual(MediaKind.image.copyKey, .photo)
    }

    func testAttachmentPolicyKeepsTheValidSubsetAndNeverExposesTheLimit() {
        let decision = MediaAttachmentPolicy.decide(
            stagedCount: 0,
            candidates: [
                .init(kind: .file, byteSize: 2),
                .init(kind: .photo, byteSize: MediaAttachmentPolicy.fallbackUploadLimit + 1),
                .init(kind: .file, byteSize: 3)
            ],
            uploadLimit: nil
        )
        XCTAssertEqual(decision.acceptedIndices, [0, 2])
        XCTAssertEqual(decision.refusal, .tooLargePhoto)
        XCTAssertEqual(decision.refusal?.copyKey, .mediaTooLargePhoto)
        XCTAssertNil(decision.refusal?.numberArgument)
    }

    func testAttachmentPolicyUsesOneLinePriorityAndTheServerLimit() {
        let candidates = [
            MediaAttachmentCandidate(kind: .file, byteSize: 11),
            .init(kind: .file, byteSize: 0),
            .init(kind: .photo, byteSize: 12)
        ]
        XCTAssertEqual(MediaAttachmentPolicy.decide(stagedCount: 8, candidates: candidates, uploadLimit: 10),
                       .init(acceptedIndices: [], refusal: .tooMany(limit: 10)),
                       "too many wins over too large and unreadable")

        XCTAssertEqual(MediaAttachmentPolicy.decide(stagedCount: 0, candidates: candidates, uploadLimit: 10),
                       .init(acceptedIndices: [], refusal: .tooLargeSome(count: 2)),
                       "too large wins over unreadable")

        let unreadable = MediaAttachmentPolicy.decide(
            stagedCount: 0, candidates: [.init(kind: .file, byteSize: nil), .init(kind: .photo, byteSize: 0)],
            uploadLimit: 10
        )
        XCTAssertEqual(unreadable.refusal, .unreadable)
        XCTAssertEqual(unreadable.refusal?.copyKey, .mediaUnreadable)
    }

    func testAttachmentPolicyStopsAtTenAndKeepsSourceOrder() {
        let candidates = (0 ..< 4).map { _ in MediaAttachmentCandidate(kind: .file, byteSize: 1) }
        let decision = MediaAttachmentPolicy.decide(stagedCount: 8, candidates: candidates, uploadLimit: 1)
        XCTAssertEqual(decision.acceptedIndices, [0, 1])
        XCTAssertEqual(decision.refusal, .tooMany(limit: 10))
        XCTAssertEqual(decision.refusal?.numberArgument, 10)
    }
}
