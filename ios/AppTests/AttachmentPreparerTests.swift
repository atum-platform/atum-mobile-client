@testable import AtumMobile
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class AttachmentPreparerTests: XCTestCase {
    func testPreparePhotoBakesEXIFOrientationIntoJPEGPixels() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-preparer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preparer = AttachmentPreparer(folder: folder)

        let input = try orientationSixJPEG()
        let prepared = try await preparer.preparePhoto(
            data: input, suggestedFilename: "source.jpg", type: .jpeg,
            uploadLimit: AttachmentPreparer.fallbackUploadLimit
        )

        XCTAssertEqual(prepared.kind, .image(width: 90, height: 60, isAnimated: false))
        let output = try XCTUnwrap(Data(contentsOf: URL(fileURLWithPath: prepared.filePath)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 90)
        XCTAssertEqual(image.height, 60)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let outputOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        XCTAssertTrue(outputOrientation == nil || outputOrientation == 1,
                      "re-encoded pixels must not retain a non-upright orientation")

        let rawSource = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData, nil))
        let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(rawSource, 0, nil))
        // EXIF 6 rotates the raw two-column image 90° clockwise:
        // [bottom-left, middle-left, top-left] / [bottom-right, middle-right, top-right].
        XCTAssertColor(pixel(image, x: 15, y: 15), near: pixel(raw, x: 15, y: 75))
        XCTAssertColor(pixel(image, x: 45, y: 15), near: pixel(raw, x: 15, y: 45))
        XCTAssertColor(pixel(image, x: 75, y: 15), near: pixel(raw, x: 15, y: 15))
        XCTAssertColor(pixel(image, x: 15, y: 45), near: pixel(raw, x: 45, y: 75))
        XCTAssertColor(pixel(image, x: 45, y: 45), near: pixel(raw, x: 45, y: 45))
        XCTAssertColor(pixel(image, x: 75, y: 45), near: pixel(raw, x: 45, y: 15))
    }

    func testPreparePhotoRejectsOversizedGIFBeforeReencodingFrames() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-preparer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preparer = AttachmentPreparer(folder: folder)
        let gif = try animatedGIF()

        do {
            _ = try await preparer.preparePhoto(data: gif, suggestedFilename: "loop.gif", type: .gif,
                                                 uploadLimit: UInt64(gif.count - 1))
            XCTFail("Expected an over-limit GIF to be rejected before frame re-encoding")
        } catch {
            XCTAssertEqual(error as? AttachmentPreparationFailure, .tooLargePhoto)
        }
    }

    func testPreparePhotoKeepsAProposedNameInsideItsStagingDirectory() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-preparer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preparer = AttachmentPreparer(folder: folder)

        let prepared = try await preparer.preparePhoto(
            data: orientationSixJPEG(), suggestedFilename: "../../private/portrait.jpg", type: .jpeg,
            uploadLimit: AttachmentPreparer.fallbackUploadLimit
        )

        XCTAssertEqual((prepared.filename as NSString).lastPathComponent, prepared.filename)
        XCTAssertTrue(prepared.filename.hasPrefix("portrait."))
        XCTAssertEqual(URL(fileURLWithPath: prepared.filePath).deletingLastPathComponent(), folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.filePath))
    }

    private func orientationSixJPEG() throws -> Data {
        let image = try colorGridImage()
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func animatedGIF() throws -> Data {
        let image = try colorGridImage()
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, 2, nil
        ))
        for _ in 0..<2 {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func colorGridImage() throws -> CGImage {
        let width = 60
        let height = 90
        let colors: [CGColor] = [
            .init(red: 1, green: 0, blue: 0, alpha: 1), .init(red: 0, green: 1, blue: 0, alpha: 1),
            .init(red: 0, green: 0, blue: 1, alpha: 1), .init(red: 1, green: 1, blue: 0, alpha: 1),
            .init(red: 0, green: 1, blue: 1, alpha: 1), .init(red: 1, green: 0, blue: 1, alpha: 1),
        ]
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for row in 0..<3 {
            for column in 0..<2 {
                context.setFillColor(colors[row * 2 + column])
                context.fill(CGRect(x: column * 30, y: (2 - row) * 30, width: 30, height: 30))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        let data = NSMutableData(length: 4)!
        let context = CGContext(
            data: data.mutableBytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: -CGFloat(x), y: CGFloat(y) - CGFloat(image.height) + 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func XCTAssertColor(_ actual: (Int, Int, Int), near expected: (Int, Int, Int),
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(actual.0 - expected.0), 40, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.1 - expected.1), 40, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.2 - expected.2), 40, file: file, line: line)
    }
}
