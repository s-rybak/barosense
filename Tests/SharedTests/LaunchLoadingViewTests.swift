import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import Barosense

/// The launch loader stays a fixed, crisp square while its background fills every device.
@MainActor
final class LaunchLoadingViewTests: XCTestCase {

    func testCompactWidthLoaderLayout() throws {
        try assertLoaderLayout(
            canvas: CGSize(width: 390, height: 844),
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular
        )
    }

    func testRegularWidthLoaderLayout() throws {
        try assertLoaderLayout(
            canvas: CGSize(width: 1_024, height: 1_366),
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular
        )
    }

    func testAnimationResourceIsBundled() throws {
        let url = try XCTUnwrap(LaunchLoadingView.animationURL)

        XCTAssertEqual(url.pathExtension, "gif")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
    }

    func testAnimationFramesUseTheExactLaunchBackground() throws {
        let url = try XCTUnwrap(LaunchLoadingView.animationURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let frameCount = CGImageSourceGetCount(source)

        XCTAssertEqual(frameCount, 97)
        for index in [0, frameCount - 1] {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            let corner = try XCTUnwrap(UIImage(cgImage: frame).pixelRGBA(x: 2, y: 2))
            XCTAssertEqual(corner.red, 0x27)
            XCTAssertEqual(corner.green, 0x29)
            XCTAssertEqual(corner.blue, 0x1F)
            XCTAssertEqual(corner.alpha, 0xFF)
        }
    }

    func testFastOpeningAlwaysShowsOneCompleteLoop() {
        XCTAssertEqual(
            AppServices.loadingSurfaceHoldDuration(after: .zero),
            .milliseconds(4_040)
        )
        XCTAssertEqual(
            AppServices.loadingSurfaceHoldDuration(after: .milliseconds(400)),
            .milliseconds(3_640)
        )
        XCTAssertEqual(
            AppServices.loadingSurfaceHoldDuration(after: .milliseconds(999)),
            .milliseconds(3_041)
        )
        XCTAssertEqual(
            AppServices.loadingSurfaceHoldDuration(after: .seconds(1)),
            .milliseconds(3_040)
        )
        XCTAssertEqual(
            AppServices.loadingSurfaceHoldDuration(after: .milliseconds(1_500)),
            .milliseconds(2_540)
        )
    }

    func testOpeningPastFirstLoopIsNotDelayedAgain() {
        XCTAssertEqual(
            AppServices.loadingSurfaceHoldDuration(after: .seconds(4)),
            .milliseconds(40)
        )
        XCTAssertNil(AppServices.loadingSurfaceHoldDuration(after: .milliseconds(4_040)))
        XCTAssertNil(AppServices.loadingSurfaceHoldDuration(after: .seconds(5)))
    }

    private func assertLoaderLayout(
        canvas: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass,
        verticalSizeClass: UserInterfaceSizeClass
    ) throws {
        let view = LaunchLoadingView()
            .environment(\.horizontalSizeClass, horizontalSizeClass)
            .environment(\.verticalSizeClass, verticalSizeClass)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let imageView = try XCTUnwrap(
            host.view.descendant(withAccessibilityIdentifier: "launch-loading-animation")
                as? UIImageView
        )
        let imageFrame = imageView.convert(imageView.bounds, to: host.view)
        XCTAssertEqual(imageView.frame.width, LaunchLoadingView.animationSize, accuracy: 0.5)
        XCTAssertEqual(imageView.frame.height, LaunchLoadingView.animationSize, accuracy: 0.5)
        XCTAssertEqual(imageFrame.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(imageFrame.midY, canvas.height / 2, accuracy: 0.5)

        let snapshot = UIGraphicsImageRenderer(size: canvas).image { _ in
            host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let corner = try XCTUnwrap(snapshot.pixelRGBA(x: 2, y: 2))
        XCTAssertEqual(corner.red, 0x27, accuracy: 2)
        XCTAssertEqual(corner.green, 0x29, accuracy: 2)
        XCTAssertEqual(corner.blue, 0x1F, accuracy: 2)
        XCTAssertEqual(corner.alpha, 0xFF, accuracy: 1)
    }
}

private extension UIView {
    func descendant(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }

        for subview in subviews {
            if let match = subview.descendant(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

private extension UIImage {
    struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    func pixelRGBA(x: Int, y: Int) -> RGBA? {
        guard let cgImage,
              x >= 0, y >= 0,
              x < cgImage.width, y < cgImage.height
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: -CGFloat(x), y: CGFloat(y - cgImage.height + 1))
        context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                        width: cgImage.width, height: cgImage.height))
        return RGBA(red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
    }
}
