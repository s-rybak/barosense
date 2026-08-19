import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Barosense

/// What the picker hands over is never what gets stored: the avatar is written downscaled and
/// re-encoded, and both of those are promises the profile row depends on.
final class ProfileAvatarEncoderTests: XCTestCase {

    func testALargePhotoIsStoredAtTheAvatarSize() async throws {
        let picked = try SampleImage.jpeg(width: 1200, height: 900)

        let stored = try await ProfileAvatarEncoder.encoded(picked)

        // Long edge to `maxPixelSize`, short edge in proportion.
        let size = try SampleImage.pixelSize(of: stored)
        XCTAssertEqual(size.width, ProfileAvatarEncoder.maxPixelSize)
        XCTAssertEqual(size.height, ProfileAvatarEncoder.maxPixelSize * 900 / 1200)
        XCTAssertLessThan(stored.count, picked.count)
    }

    /// A portrait photo keeps its shape — the thumbnail is asked for with the source's
    /// orientation applied, so the stored image is not the sideways one.
    func testAPortraitPhotoIsStoredUpright() async throws {
        let picked = try SampleImage.jpeg(width: 600, height: 900)

        let size = try SampleImage.pixelSize(of: try await ProfileAvatarEncoder.encoded(picked))

        XCTAssertEqual(size.height, ProfileAvatarEncoder.maxPixelSize)
        XCTAssertLessThan(size.width, size.height)
    }

    func testSomethingThatIsNotAnImageThrows() async {
        do {
            _ = try await ProfileAvatarEncoder.encoded(Data("not an image".utf8))
            XCTFail("Expected an unreadable image to throw")
        } catch {
            XCTAssertEqual(error as? ProfileAvatarEncoder.Failure, .unreadableImage)
        }
    }
}

// MARK: - Fixture

/// Real JPEG bytes, so the encoder is exercised against an image rather than a stub.
enum SampleImage {

    enum Failure: Error { case couldNotBuildImage, couldNotReadSize }

    /// A JPEG of exactly `width` × `height`, drawn with enough contrast that it does not
    /// compress to nothing.
    static func jpeg(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.couldNotBuildImage
        }

        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

        guard let image = context.makeImage() else { throw Failure.couldNotBuildImage }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Failure.couldNotBuildImage
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.couldNotBuildImage }
        return data as Data
    }

    /// Pixel dimensions read from the file's own properties, without decoding it.
    static func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure.couldNotReadSize
        }
        return (width, height)
    }
}
