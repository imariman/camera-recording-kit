import AVFoundation
import CoreImage
import Vision

/// The result of checking whether the bounded software stabilizer can run for
/// a capture profile. This is deliberately separate from AVFoundation's
/// hardware stabilization capability: macOS capture devices do not provide a
/// reliable hardware-stabilization contract for this plugin.
public enum MacOSVideoStabilizationAvailability: Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        switch self {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }
}

/// Timing and dimension metadata carried through a stabilization operation.
/// The transformed video sample always has these same values as the source.
public struct MacOSVideoStabilizationMetadata: Equatable {
    public let width: Int
    public let height: Int
    public let presentationTimeStamp: CMTime
    public let duration: CMTime

    public init(
        width: Int,
        height: Int,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        self.width = width
        self.height = height
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
    }
}

/// A video sample produced by ``MacOSVideoStabilizer``.
///
/// `sampleBuffer` is the original capture sample when Core Image cannot obtain
/// a bounded output buffer. Vision-registration failures retain the last safe
/// correction and crop so the visible framing does not jump.
public struct MacOSVideoStabilizationResult {
    public let sampleBuffer: CMSampleBuffer
    public let metadata: MacOSVideoStabilizationMetadata
    public let isStabilized: Bool
    public let fallbackReason: String?

    init(
        sampleBuffer: CMSampleBuffer,
        metadata: MacOSVideoStabilizationMetadata,
        isStabilized: Bool,
        fallbackReason: String?
    ) {
        self.sampleBuffer = sampleBuffer
        self.metadata = metadata
        self.isStabilized = isStabilized
        self.fallbackReason = fallbackReason
    }
}

/// Bounded-cost, translational software stabilization for macOS recording.
///
/// The owner must call this only from its serial video-capture queue. The
/// stabilizer does not retain source capture buffers: Vision operates on a
/// 640-pixel-wide private analysis copy and Core Image renders into a bounded
/// private output pool. It declines 4K and 60 FPS profiles rather than
/// claiming support that would compete with capture and encoding for memory or
/// GPU time on the supported 16 GB machines.
public final class MacOSVideoStabilizer {
    public static let maximumWidth = 1920
    public static let maximumHeight = 1080
    public static let maximumFramesPerSecond = 30
    public static let cropInsetFraction: CGFloat = 0.06

    private static let analysisMaximumDimension = 640
    private static let analysisFrameInterval = 2
    private static let maximumOutputBuffers = 3

    private let ciContext: CIContext
    private let motionFilter = MacOSVideoStabilizationMotionFilter()

    private var expectedWidth = 0
    private var expectedHeight = 0
    private var expectedFramesPerSecond = 0
    private(set) var outputPool: CVPixelBufferPool?
    private(set) var analysisPool: CVPixelBufferPool?
    private var referenceAnalysisBuffer: CVPixelBuffer?
    private var frameIndex = 0
    private var lastRenderedCorrection = CGPoint.zero
    private var lastOutputIsCropped = false

    /// The reason the most recent frame used the unmodified source sample.
    /// This is diagnostic state for a truthful recording-quality readback; it
    /// does not turn a configured mode into a falsely unsupported capability.
    public private(set) var lastFrameFallbackReason: String?

    public init() {
        ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ])
    }

    /// Returns the profiles for which the helper has an explicit performance
    /// budget. Callers must expose support only when this returns `.available`.
    public static func availability(
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) -> MacOSVideoStabilizationAvailability {
        guard width > 0, height > 0, framesPerSecond > 0 else {
            return .unavailable(reason: "A positive capture size and frame rate are required.")
        }
        guard width <= maximumWidth, height <= maximumHeight else {
            return .unavailable(
                reason: "Software stabilization is bounded to 1920x1080; higher resolutions use the unmodified sensor stream."
            )
        }
        guard framesPerSecond <= maximumFramesPerSecond else {
            return .unavailable(
                reason: "Software stabilization is bounded to 30 FPS; higher frame rates use the unmodified sensor stream."
            )
        }
        return .available
    }

    /// Configures private pools for one verified capture profile.
    @discardableResult
    public func configure(
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) -> MacOSVideoStabilizationAvailability {
        let availability = Self.availability(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond
        )
        guard availability.isAvailable else {
            reset()
            return availability
        }

        expectedWidth = width
        expectedHeight = height
        expectedFramesPerSecond = framesPerSecond
        outputPool = Self.makePixelBufferPool(
            width: width,
            height: height,
            bufferCount: Self.maximumOutputBuffers
        )
        let analysisSize = Self.analysisSize(width: width, height: height)
        analysisPool = Self.makePixelBufferPool(
            width: analysisSize.width,
            height: analysisSize.height,
            bufferCount: 2
        )
        guard outputPool != nil, analysisPool != nil else {
            reset()
            return .unavailable(
                reason: "macOS could not allocate the bounded software-stabilization buffers."
            )
        }
        resetMotion()
        return availability
    }

    /// Drops accumulated motion and the Vision reference frame while keeping
    /// the configured profile and its private buffer pools. Call this when
    /// capture continues with the same profile after a discontinuity, such as
    /// resuming a paused recording, so the next frame is not registered
    /// against stale content.
    public func resetMotion() {
        referenceAnalysisBuffer = nil
        frameIndex = 0
        lastFrameFallbackReason = nil
        lastRenderedCorrection = .zero
        lastOutputIsCropped = false
        motionFilter.reset()
    }

    /// Drops all accumulated motion, private frame references and buffer
    /// pools. Call this before changing camera, while pausing capture, and
    /// when recording ends.
    public func reset() {
        expectedWidth = 0
        expectedHeight = 0
        expectedFramesPerSecond = 0
        outputPool = nil
        analysisPool = nil
        resetMotion()
    }

    /// Produces an identically timed, identically sized stabilized sample when
    /// possible. Allocation and render failures return the original sample.
    public func process(sampleBuffer: CMSampleBuffer) -> MacOSVideoStabilizationResult {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return fallback(sampleBuffer: sampleBuffer, reason: "The capture sample has no image buffer.")
        }

        let metadata = Self.metadata(for: sampleBuffer, pixelBuffer: sourceBuffer)
        guard metadata.width == expectedWidth,
              metadata.height == expectedHeight,
              expectedFramesPerSecond > 0,
              outputPool != nil,
              analysisPool != nil else {
            return fallback(sampleBuffer: sampleBuffer, metadata: metadata, reason: "The source sample does not match a configured stabilization profile.")
        }

        frameIndex += 1
        if frameIndex % Self.analysisFrameInterval == 1 {
            guard let analysisBuffer = makeAnalysisBuffer(from: sourceBuffer) else {
                return fallback(sampleBuffer: sampleBuffer, metadata: metadata, reason: "Could not allocate the bounded analysis buffer.")
            }
            defer { referenceAnalysisBuffer = analysisBuffer }

            if let referenceAnalysisBuffer {
                guard let alignment = alignment(from: analysisBuffer, to: referenceAnalysisBuffer) else {
                    return renderWithLastSafeCorrection(
                        sourceBuffer: sourceBuffer,
                        sourceSample: sampleBuffer,
                        metadata: metadata,
                        fallbackReason: "Vision could not register this frame."
                    )
                }

                let analysisScale = CGFloat(metadata.width) / CGFloat(CVPixelBufferGetWidth(analysisBuffer))
                let sourceTranslation = CGPoint(
                    x: -alignment.tx * analysisScale,
                    y: -alignment.ty * analysisScale
                )
                let accepted = motionFilter.ingest(
                    positionDelta: sourceTranslation,
                    maximumStepX: CGFloat(metadata.width) * 0.025,
                    maximumStepY: CGFloat(metadata.height) * 0.025
                )
                if !accepted {
                    return renderWithLastSafeCorrection(
                        sourceBuffer: sourceBuffer,
                        sourceSample: sampleBuffer,
                        metadata: metadata,
                        fallbackReason: "Vision reported a discontinuous translation."
                    )
                }
            }
        }

        return renderWithLastSafeCorrection(
            sourceBuffer: sourceBuffer,
            sourceSample: sampleBuffer,
            metadata: metadata,
            fallbackReason: nil
        )
    }

    /// Converts a normalized point in the stabilized output into the matching
    /// normalized sensor point. Use this for focus and exposure controls so a
    /// tap follows the visible, cropped preview instead of the raw sensor.
    public func sensorPoint(fromOutputNormalized outputPoint: CGPoint) -> CGPoint {
        guard expectedWidth > 0, expectedHeight > 0 else {
            return Self.clampedNormalizedPoint(outputPoint)
        }
        let scale = 1 / (1 - (2 * Self.cropInsetFraction))
        guard lastOutputIsCropped else {
            return Self.clampedNormalizedPoint(outputPoint)
        }
        let outputX = outputPoint.x * CGFloat(expectedWidth)
        let outputY = outputPoint.y * CGFloat(expectedHeight)
        let sensorX = (outputX - lastRenderedCorrection.x - (CGFloat(expectedWidth) * (1 - scale) / 2)) / scale
        // Core Image's positive y direction is up, while AVCapture focus and
        // exposure points use the output pixel buffer's top-left origin.
        let sensorY = (outputY + lastRenderedCorrection.y - (CGFloat(expectedHeight) * (1 - scale) / 2)) / scale
        return Self.clampedNormalizedPoint(
            CGPoint(
                x: sensorX / CGFloat(expectedWidth),
                y: sensorY / CGFloat(expectedHeight)
            )
        )
    }

    private func renderWithLastSafeCorrection(
        sourceBuffer: CVPixelBuffer,
        sourceSample: CMSampleBuffer,
        metadata: MacOSVideoStabilizationMetadata,
        fallbackReason: String?
    ) -> MacOSVideoStabilizationResult {
        let correction = motionFilter.correction(
            maximumX: CGFloat(metadata.width) * Self.cropInsetFraction,
            maximumY: CGFloat(metadata.height) * Self.cropInsetFraction
        )
        guard let outputBuffer = makeTransformedBuffer(from: sourceBuffer, correction: correction),
              let transformedSample = makeSampleBuffer(
                  imageBuffer: outputBuffer,
                  sourceSample: sourceSample
              ) else {
            return fallback(
                sampleBuffer: sourceSample,
                metadata: metadata,
                reason: "Core Image could not produce a bounded stabilized frame."
            )
        }
        lastFrameFallbackReason = fallbackReason
        lastRenderedCorrection = correction
        lastOutputIsCropped = true
        return MacOSVideoStabilizationResult(
            sampleBuffer: transformedSample,
            metadata: metadata,
            isStabilized: true,
            fallbackReason: fallbackReason
        )
    }

    private func fallback(
        sampleBuffer: CMSampleBuffer,
        metadata: MacOSVideoStabilizationMetadata? = nil,
        reason: String?
    ) -> MacOSVideoStabilizationResult {
        let resolvedMetadata: MacOSVideoStabilizationMetadata
        if let metadata {
            resolvedMetadata = metadata
        } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            resolvedMetadata = Self.metadata(for: sampleBuffer, pixelBuffer: pixelBuffer)
        } else {
            resolvedMetadata = MacOSVideoStabilizationMetadata(
                width: 0,
                height: 0,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                duration: CMSampleBufferGetDuration(sampleBuffer)
            )
        }
        lastFrameFallbackReason = reason
        lastRenderedCorrection = .zero
        lastOutputIsCropped = false
        return MacOSVideoStabilizationResult(
            sampleBuffer: sampleBuffer,
            metadata: resolvedMetadata,
            isStabilized: false,
            fallbackReason: reason
        )
    }

    private func makeAnalysisBuffer(from sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let analysisPool,
              let analysisBuffer = Self.makeBuffer(from: analysisPool) else {
            return nil
        }
        let destinationExtent = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(analysisBuffer),
            height: CVPixelBufferGetHeight(analysisBuffer)
        )
        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let scaleX = destinationExtent.width / sourceImage.extent.width
        let scaleY = destinationExtent.height / sourceImage.extent.height
        ciContext.render(
            sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)),
            to: analysisBuffer,
            bounds: destinationExtent,
            colorSpace: sourceColorSpace(for: sourceBuffer)
        )
        return analysisBuffer
    }

    private func alignment(
        from current: CVPixelBuffer,
        to reference: CVPixelBuffer
    ) -> CGAffineTransform? {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCVPixelBuffer: current,
            options: [:]
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: reference, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first?.alignmentTransform
        } catch {
            return nil
        }
    }

    private func makeTransformedBuffer(
        from sourceBuffer: CVPixelBuffer,
        correction: CGPoint
    ) -> CVPixelBuffer? {
        guard let outputPool,
              let outputBuffer = Self.makeBuffer(from: outputPool) else {
            return nil
        }
        let width = CGFloat(CVPixelBufferGetWidth(sourceBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(sourceBuffer))
        let scale = 1 / (1 - (2 * Self.cropInsetFraction))
        let centeredScale = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: (width - (width * scale)) / 2,
            ty: (height - (height * scale)) / 2
        )
        let translation = CGAffineTransform(
            translationX: correction.x,
            y: correction.y
        )
        let image = CIImage(cvPixelBuffer: sourceBuffer)
            .transformed(by: centeredScale.concatenating(translation))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        ciContext.render(
            image,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: sourceColorSpace(for: sourceBuffer)
        )
        if let attachments = CVBufferGetAttachments(sourceBuffer, .shouldPropagate) {
            CVBufferSetAttachments(outputBuffer, attachments, .shouldPropagate)
        }
        return outputBuffer
    }

    private func makeSampleBuffer(
        imageBuffer: CVPixelBuffer,
        sourceSample: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sourceSample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sourceSample),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sourceSample)
        )
        var stabilizedSample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &stabilizedSample
        ) == noErr else {
            return nil
        }
        if let stabilizedSample {
            CMPropagateAttachments(sourceSample, destination: stabilizedSample)
        }
        return stabilizedSample
    }

    private static func metadata(
        for sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer
    ) -> MacOSVideoStabilizationMetadata {
        MacOSVideoStabilizationMetadata(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer)
        )
    }

    private static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, CGFloat(analysisMaximumDimension) / CGFloat(max(width, height)))
        return (
            width: max(1, Int((CGFloat(width) * scale).rounded(.down))),
            height: max(1, Int((CGFloat(height) * scale).rounded(.down)))
        )
    }

    private static func makePixelBufferPool(
        width: Int,
        height: Int,
        bufferCount: Int
    ) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: bufferCount,
            kCVPixelBufferPoolMaximumBufferAgeKey: 1,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }

    private static func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let auxAttributes: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: maximumOutputBuffers,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private static func clampedNormalizedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(1, point.x)),
            y: max(0, min(1, point.y))
        )
    }

    private func sourceColorSpace(for pixelBuffer: CVPixelBuffer) -> CGColorSpace? {
        CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
    }
}

/// Stateful low-pass filter for the cumulative camera translation. Kept free
/// of Vision and Core Image so the jitter-reduction contract is testable with
/// deterministic synthetic motion sequences.
final class MacOSVideoStabilizationMotionFilter {
    private static let smoothingFactor: CGFloat = 0.15

    private var position = CGPoint.zero
    private var smoothedPosition = CGPoint.zero

    func reset() {
        position = .zero
        smoothedPosition = .zero
    }

    @discardableResult
    func ingest(
        positionDelta: CGPoint,
        maximumStepX: CGFloat = .greatestFiniteMagnitude,
        maximumStepY: CGFloat = .greatestFiniteMagnitude
    ) -> Bool {
        guard abs(positionDelta.x) <= maximumStepX,
              abs(positionDelta.y) <= maximumStepY else {
            return false
        }
        position.x += positionDelta.x
        position.y += positionDelta.y
        smoothedPosition.x += (position.x - smoothedPosition.x) * Self.smoothingFactor
        smoothedPosition.y += (position.y - smoothedPosition.y) * Self.smoothingFactor
        return true
    }

    func correction(maximumX: CGFloat, maximumY: CGFloat) -> CGPoint {
        CGPoint(
            x: max(-maximumX, min(maximumX, smoothedPosition.x - position.x)),
            y: max(-maximumY, min(maximumY, smoothedPosition.y - position.y))
        )
    }
}
