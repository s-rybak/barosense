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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onAnimationReady: @MainActor () async -> Void

    init(onAnimationReady: @escaping @MainActor () async -> Void = {}) {
        self.onAnimationReady = onAnimationReady
    }

    var body: some View {
        ZStack {
            Palette.launchBackground.ignoresSafeArea()

            if let animationResource = Self.animationResource {
                AnimatedGIFView(resource: animationResource, animates: !reduceMotion)
                    .frame(width: Self.animationSize, height: Self.animationSize)
                    .clipped()
                    .accessibilityHidden(true)
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
            // Give the decoded first frame one display cycle before store creation can occupy
            // the main actor. The loading-duration clock therefore starts from visible motion.
            try? await Task.sleep(for: .milliseconds(20))
            await onAnimationReady()
        }
    }

    /// Resolved through the type's bundle so the app and its hosted tests find the same file.
    static var animationURL: URL? {
        animationResource?.url
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
    let animates: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GIFImageView {
        let imageView = GIFImageView()
        imageView.backgroundColor = UIColor(named: "LaunchBackground")
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isOpaque = true
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityIdentifier = "launch-loading-animation"
        context.coordinator.display(resource: resource, animates: animates, in: imageView)
        return imageView
    }

    func updateUIView(_ imageView: GIFImageView, context: Context) {
        context.coordinator.display(resource: resource, animates: animates, in: imageView)
    }

    static func dismantleUIView(_ imageView: GIFImageView, coordinator: Coordinator) {
        coordinator.stop()
        imageView.image = nil
    }

    @MainActor
    final class Coordinator: NSObject {

        private weak var imageView: GIFImageView?
        private var resource: LaunchLoadingAnimationResource?
        private var currentlyAnimates: Bool?
        private var frameIndex = 0
        private var elapsed: TimeInterval = 0
        private var lastTimestamp: CFTimeInterval?
        private var displayLink: CADisplayLink?

        func display(resource: LaunchLoadingAnimationResource,
                     animates: Bool,
                     in imageView: GIFImageView) {
            guard self.imageView !== imageView
                    || self.resource !== resource
                    || currentlyAnimates != animates
            else { return }

            stop()
            self.imageView = imageView
            self.resource = resource
            currentlyAnimates = animates
            frameIndex = 0
            imageView.image = UIImage(cgImage: resource.firstFrame)

            guard animates, resource.frameDurations.count > 1 else { return }

            let displayLink = CADisplayLink(target: self, selector: #selector(advanceFrame(_:)))
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
            currentlyAnimates = nil
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
