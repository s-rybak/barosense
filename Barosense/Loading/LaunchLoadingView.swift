import ImageIO
import SwiftUI
import UIKit

/// The app-owned part of a cold launch, shown while the durable store opens.
///
/// iOS keeps the preceding system launch screen static. Its background uses the same named
/// colour, so the hand-off into this animated view is visually continuous.
struct LaunchLoadingView: View {

    static let animationSize: CGFloat = 150
    private static let animationResource = LaunchLoadingAnimationResource.load()

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Overrides the system setting. `nil` — the shipping case — follows it.
    ///
    /// Present because `accessibilityReduceMotion` is a read-only environment value: a
    /// preview or a test cannot reach the reduced-motion surface any other way.
    private let reduceMotionOverride: Bool?

    private let onAnimationReady: @MainActor () async -> Void

    init(reduceMotionOverride: Bool? = nil,
         onAnimationReady: @escaping @MainActor () async -> Void = {}) {
        self.reduceMotionOverride = reduceMotionOverride
        self.onAnimationReady = onAnimationReady
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    var body: some View {
        ZStack {
            Palette.launchBackground.ignoresSafeArea()

            // Reduce Motion takes the same branch as a missing resource. Freezing the GIF
            // on its first frame would leave the surface with no sign of progress at all for
            // the whole of the opening phase, which reads as a hang rather than as a launch.
            if let animationResource = Self.animationResource, !reduceMotion {
                AnimatedGIFView(resource: animationResource)
                    .frame(width: Self.animationSize, height: Self.animationSize)
                    .clipped()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading Barosense"))
        .accessibilityIdentifier("launch-loading-screen")
        .task {
            // Yield once before store creation can occupy the main actor, so the first frame
            // is on screen rather than queued behind it. `AppServices` starts its hold clock
            // when the work begins, which is this yield plus a layout pass after the
            // animation itself started — close enough that no first frame is skipped, not
            // close enough to claim the two are in step. See `minimumLoadingDuration`.
            try? await Task.sleep(for: .milliseconds(20))
            await onAnimationReady()
        }
    }

    /// Resolved through the type's bundle so the app and its hosted tests find the same file.
    static var animationURL: URL? {
        animationResource?.url
    }

    /// The rate the loader asks `CADisplayLink` for. Exposed for the reason `animationURL`
    /// is: it is a property of the shipped file, and a test is the only thing that reads it
    /// back.
    static var animationFrameRateRange: CAFrameRateRange? {
        animationResource?.preferredFrameRateRange
    }

    /// Forces the compressed source, frame timing, and first frame into memory before the
    /// composition root opens any stores.
    static func preloadAnimation() {
        _ = animationResource
    }
}

private final class LaunchLoadingBundleMarker: NSObject {}

/// The startup-priority portion of the GIF. Later frames remain streaming to keep launch
/// memory bounded, while the compressed source and first frame are ready before first paint.
@MainActor
private final class LaunchLoadingAnimationResource {

    let url: URL
    let imageSource: CGImageSource
    let frameDurations: [TimeInterval]
    let firstFrame: CGImage

    private init(url: URL,
                 imageSource: CGImageSource,
                 frameDurations: [TimeInterval],
                 firstFrame: CGImage) {
        self.url = url
        self.imageSource = imageSource
        self.frameDurations = frameDurations
        self.firstFrame = firstFrame
    }

    static func load() -> LaunchLoadingAnimationResource? {
        guard let url = Bundle(for: LaunchLoadingBundleMarker.self)
                .url(forResource: "LaunchLoading", withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0,
              let firstFrame = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { return nil }

        let frameDurations = (0..<frameCount).map { frameDuration(at: $0, in: source) }
        return LaunchLoadingAnimationResource(
            url: url,
            imageSource: source,
            frameDurations: frameDurations,
            firstFrame: firstFrame
        )
    }

    /// The animation's own rate, taken from its fastest frame.
    ///
    /// Left unset, `CADisplayLink` fires at the display's maximum — 120 Hz on ProMotion —
    /// which is roughly five times the main-actor callbacks a 25 fps GIF can use, during the
    /// one moment the SwiftData container is being opened on that same actor. The window
    /// around the preferred rate lets the system pick something that divides evenly into the
    /// panel's refresh rate instead of forcing a rate that does not.
    var preferredFrameRateRange: CAFrameRateRange {
        let preferred = max(Float(1 / (frameDurations.min() ?? 0.1)), 1)
        return CAFrameRateRange(minimum: max(preferred - 5, 1),
                                maximum: preferred + 5,
                                preferred: preferred)
    }

    private static func frameDuration(at index: Int,
                                      in source: CGImageSource) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? NSNumber
        return max(unclamped?.doubleValue ?? clamped?.doubleValue ?? 0.1, 0.02)
    }
}

/// Keeps the source bitmap's 960 px dimensions from becoming SwiftUI layout dimensions.
private final class GIFImageView: UIImageView {
    override var intrinsicContentSize: CGSize { .zero }
}

/// A native, streaming GIF surface.
///
/// Frames are decoded as the display link reaches them. Unlike `UIImage.animatedImage`, this
/// does not inflate all 97 source frames into one in-memory array during launch.
private struct AnimatedGIFView: UIViewRepresentable {

    let resource: LaunchLoadingAnimationResource

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GIFImageView {
        let imageView = GIFImageView()
        imageView.backgroundColor = UIColor(named: Palette.launchBackgroundAssetName)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isOpaque = true
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityIdentifier = "launch-loading-animation"
        context.coordinator.display(resource: resource, in: imageView)
        return imageView
    }

    func updateUIView(_ imageView: GIFImageView, context: Context) {
        context.coordinator.display(resource: resource, in: imageView)
    }

    static func dismantleUIView(_ imageView: GIFImageView, coordinator: Coordinator) {
        coordinator.stop()
        imageView.image = nil
    }

    @MainActor
    final class Coordinator: NSObject {

        private weak var imageView: GIFImageView?
        private var resource: LaunchLoadingAnimationResource?
        private var frameIndex = 0
        private var elapsed: TimeInterval = 0
        private var lastTimestamp: CFTimeInterval?
        private var displayLink: CADisplayLink?

        func display(resource: LaunchLoadingAnimationResource, in imageView: GIFImageView) {
            guard self.imageView !== imageView || self.resource !== resource else { return }

            stop()
            self.imageView = imageView
            self.resource = resource
            frameIndex = 0
            imageView.image = UIImage(cgImage: resource.firstFrame)

            guard resource.frameDurations.count > 1 else { return }

            let displayLink = CADisplayLink(target: self, selector: #selector(advanceFrame(_:)))
            displayLink.preferredFrameRateRange = resource.preferredFrameRateRange
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            resource = nil
            frameIndex = 0
            elapsed = 0
            lastTimestamp = nil
            imageView = nil
        }

        @objc
        private func advanceFrame(_ displayLink: CADisplayLink) {
            guard let previousTimestamp = lastTimestamp,
                  let resource,
                  !resource.frameDurations.isEmpty
            else {
                lastTimestamp = displayLink.timestamp
                return
            }

            elapsed += displayLink.timestamp - previousTimestamp
            lastTimestamp = displayLink.timestamp

            var didAdvance = false
            while elapsed >= resource.frameDurations[frameIndex] {
                elapsed -= resource.frameDurations[frameIndex]
                frameIndex = (frameIndex + 1) % resource.frameDurations.count
                didAdvance = true
            }

            if didAdvance { displayFrame(at: frameIndex) }
        }

        private func displayFrame(at index: Int) {
            guard let resource,
                  let imageView,
                  let image = CGImageSourceCreateImageAtIndex(
                    resource.imageSource,
                    index,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  )
            else { return }

            imageView.image = UIImage(cgImage: image)
        }
    }
}

#Preview("Launch loading") {
    LaunchLoadingView()
}

#Preview("Launch loading — Reduce Motion") {
    LaunchLoadingView(reduceMotionOverride: true)
}
