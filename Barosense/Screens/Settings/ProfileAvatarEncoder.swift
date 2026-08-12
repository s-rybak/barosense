import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever the photo picker hands back into the small JPEG stored on the profile.
///
/// Two jobs, both of which have to happen before the bytes reach the store:
///
/// - **Downscale.** A picked photo is routinely 12 MP / several MB. The avatar is drawn at
///   76 pt, so 256 px on the long edge covers a 3× screen with room to spare, and the
///   result lands in the low tens of kB. Storing the original would put megabytes into a
///   row that is read on every launch.
/// - **Re-encode.** Going through `CGImageDestination` writes a plain JPEG and carries
///   none of the source's metadata across — no GPS, no capture timestamp, no device
///   identifiers. The user asked for a picture of themselves, not for the place it was
///   taken to be filed with their health records.
///
/// `ImageIO` rather than `UIImage`: `CGImageSourceCreateThumbnailAtIndex` decodes straight
/// to the target size instead of materialising the full image first, and it applies the
/// EXIF orientation while doing it, so a photo taken in portrait is not stored on its side.
enum ProfileAvatarEncoder {

    /// Longest edge of the stored image, in pixels.
    static let maxPixelSize = 256

    /// 0.8 is the usual knee for photographic content: visually indistinguishable at this
    /// size, and roughly half the bytes of 1.0.
    private static let compressionQuality = 0.8

    enum Failure: Error {
        /// The picked item was not an image this device can decode.
        case unreadableImage
        /// The re-encode failed. No useful sub-cases — the only next step is to pick again.
        case encodingFailed
    }

    /// Downscaled, re-encoded JPEG for `data`, which is the raw file the picker produced.
    static func encode(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unreadableImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw Failure.unreadableImage
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Failure.encodingFailed
        }

        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw Failure.encodingFailed
        }
        return encoded as Data
    }
}
