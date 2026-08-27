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

    /// The GIF carries its own matte, so it is the one copy of this colour the asset
    /// catalogue cannot own. Asserted against the catalogue rather than against a hex
    /// restated here, so the two cannot drift behind a test that still passes.
    func testAnimationFramesUseTheExactLaunchBackground() throws {
        let expected = try launchBackground()
        let url = try XCTUnwrap(LaunchLoadingView.animationURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let frameCount = CGImageSourceGetCount(source)

        XCTAssertEqual(frameCount, 97)
        for index in [0, frameCount - 1] {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            let corner = try XCTUnwrap(UIImage(cgImage: frame).pixelRGBA(x: 2, y: 2))
            XCTAssertEqual(corner.red, expected.red)
            XCTAssertEqual(corner.green, expected.green)
            XCTAssertEqual(corner.blue, expected.blue)
            XCTAssertEqual(corner.alpha, 0xFF)
        }
    }

    /// The display link must not be left at the panel's maximum: on ProMotion that is 120 Hz
    /// of main-actor callbacks for an animation whose fastest frame is 40 ms, spent during
    /// the one moment the store is being opened on that same actor.
    func testDisplayLinkAsksForTheAnimationsOwnFrameRate() throws {
        let range: CAFrameRateRange = try XCTUnwrap(LaunchLoadingView.animationFrameRateRange)

        // `preferred` is refined to an optional in Swift: 0 means "no preference", which is
        // precisely the value this test exists to rule out.
        XCTAssertEqual(try XCTUnwrap(range.preferred), Float(25), accuracy: 0.01)
        XCTAssertEqual(range.minimum, Float(20), accuracy: 0.01)
        XCTAssertEqual(range.maximum, Float(30), accuracy: 0.01)
    }

    /// Reduce Motion must not leave a still frame standing in for an animation: the loader
    /// is the whole of the opening phase, and a frozen picture there reads as a hang.
    func testReduceMotionReplacesTheAnimationRatherThanFreezingIt() {
        let loader = hostedLoader(canvas: CGSize(width: 390, height: 844), reduceMotion: true)

        XCTAssertNil(loader.view.descendant(withAccessibilityIdentifier: "launch-loading-animation"))
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

    /// Hosts the loader in a real window: the animation is a `UIViewRepresentable`, so it
    /// exists only once UIKit has laid it out. The window comes back with the view rather
    /// than staying local — dropping it would tear the hierarchy down before the caller
    /// reads anything off it.
    private func hostedLoader(
        canvas: CGSize,
        reduceMotion: Bool = false,
        horizontalSizeClass: UserInterfaceSizeClass = .compact,
        verticalSizeClass: UserInterfaceSizeClass = .regular
    ) -> (window: UIWindow, view: UIView) {
        let view = LaunchLoadingView(reduceMotionOverride: reduceMotion)
            .environment(\.horizontalSizeClass, horizontalSizeClass)
            .environment(\.verticalSizeClass, verticalSizeClass)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        return (window, host.view)
    }

    private func assertLoaderLayout(
        canvas: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass,
        verticalSizeClass: UserInterfaceSizeClass
    ) throws {
        let loader = hostedLoader(canvas: canvas,
                                  horizontalSizeClass: horizontalSizeClass,
                                  verticalSizeClass: verticalSizeClass)

        let imageView = try XCTUnwrap(
            loader.view.descendant(withAccessibilityIdentifier: "launch-loading-animation")
                as? UIImageView
        )
        let imageFrame = imageView.convert(imageView.bounds, to: loader.view)
        XCTAssertEqual(imageView.frame.width, LaunchLoadingView.animationSize, accuracy: 0.5)
        XCTAssertEqual(imageView.frame.height, LaunchLoadingView.animationSize, accuracy: 0.5)
        XCTAssertEqual(imageFrame.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(imageFrame.midY, canvas.height / 2, accuracy: 0.5)

        let snapshot = UIGraphicsImageRenderer(size: canvas).image { _ in
            loader.view.drawHierarchy(in: loader.window.bounds, afterScreenUpdates: true)
        }
        let expected = try launchBackground()
        let corner = try XCTUnwrap(snapshot.pixelRGBA(x: 2, y: 2))
        XCTAssertEqual(corner.red, expected.red, accuracy: 2)
        XCTAssertEqual(corner.green, expected.green, accuracy: 2)
        XCTAssertEqual(corner.blue, expected.blue, accuracy: 2)
        XCTAssertEqual(corner.alpha, 0xFF, accuracy: 1)
    }

    /// The launch background as the asset catalogue resolves it — the same entry
    /// `UILaunchScreen` reads before any Swift runs, and the only copy of this value the
    /// app owns.
    private func launchBackground() throws -> UIImage.RGBA {
        let color = try XCTUnwrap(UIColor(named: Palette.launchBackgroundAssetName))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))

        return UIImage.RGBA(red: UInt8((red * 255).rounded()),
                            green: UInt8((green * 255).rounded()),
                            blue: UInt8((blue * 255).rounded()),
                            alpha: UInt8((alpha * 255).rounded()))
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
