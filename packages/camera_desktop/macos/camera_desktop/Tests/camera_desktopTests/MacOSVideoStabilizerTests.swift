import AVFoundation
import CoreVideo
import XCTest
@testable import camera_desktop

final class MacOSVideoStabilizerTests: XCTestCase {
    func testAvailabilityAcceptsOnlyProfileWithExplicitPerformanceBudget() {
        XCTAssertEqual(
            MacOSVideoStabilizer.availability(
                width: 1920,
                height: 1080,
                framesPerSecond: 30
            ),
            .available
        )
        XCTAssertFalse(
            MacOSVideoStabilizer.availability(
                width: 3840,
                height: 2160,
                framesPerSecond: 30
            ).isAvailable
        )
        XCTAssertFalse(
            MacOSVideoStabilizer.availability(
                width: 1920,
                height: 1080,
                framesPerSecond: 60
            ).isAvailable
        )
    }

    func testSyntheticTranslatedFramesReduceHighFrequencyJitter() {
        let rawPositions: [CGFloat] = [0, 8, -7, 9, -8, 7, -6, 8, -7, 6, -5]
        let filter = MacOSVideoStabilizationMotionFilter()
        var previousRawPosition: CGFloat = 0
        var stabilizedPositions: [CGFloat] = []

        for rawPosition in rawPositions {
            filter.ingest(positionDelta: CGPoint(x: rawPosition - previousRawPosition, y: 0))
            let correction = filter.correction(maximumX: 120, maximumY: 120)
            stabilizedPositions.append(rawPosition + correction.x)
            previousRawPosition = rawPosition
        }

        let rawJitter = meanSquaredAdjacentDifference(rawPositions)
        let stabilizedJitter = meanSquaredAdjacentDifference(stabilizedPositions)
        XCTAssertLessThan(
            stabilizedJitter,
            rawJitter * 0.25,
            "The filtered synthetic translation should have substantially less frame-to-frame jitter."
        )
    }

    func testDiscontinuousForegroundTranslationDoesNotPanEntireOutput() {
        let filter = MacOSVideoStabilizationMotionFilter()
        XCTAssertTrue(filter.ingest(positionDelta: CGPoint(x: 4, y: -3)))
        let correctionBeforeOutlier = filter.correction(maximumX: 120, maximumY: 120)

        XCTAssertFalse(
            filter.ingest(
                positionDelta: CGPoint(x: 400, y: 0),
                maximumStepX: 48,
                maximumStepY: 27
            )
        )

        XCTAssertEqual(
            filter.correction(maximumX: 120, maximumY: 120),
            correctionBeforeOutlier,
            "A moving foreground or bad registration must not drag the entire frame."
        )
    }

    func testFirstFrameCropPreservesDimensionsAndTimingMetadata() throws {
        let sample = try makeSampleBuffer(
            width: 1920,
            height: 1080,
            presentationTimeStamp: CMTime(value: 1800, timescale: 600),
            duration: CMTime(value: 20, timescale: 600)
        )
        let stabilizer = MacOSVideoStabilizer()
        XCTAssertEqual(
            stabilizer.configure(width: 1920, height: 1080, framesPerSecond: 30),
            .available
        )

        let result = stabilizer.process(sampleBuffer: sample)

        XCTAssertTrue(result.isStabilized)
        XCTAssertNil(result.fallbackReason)
        XCTAssertEqual(result.metadata.width, 1920)
        XCTAssertEqual(result.metadata.height, 1080)
        XCTAssertEqual(result.metadata.presentationTimeStamp, CMTime(value: 1800, timescale: 600))
        XCTAssertEqual(result.metadata.duration, CMTime(value: 20, timescale: 600))
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(result.sampleBuffer),
            CMTime(value: 1800, timescale: 600)
        )
        XCTAssertEqual(CMSampleBufferGetDuration(result.sampleBuffer), CMTime(value: 20, timescale: 600))
        XCTAssertEqual(CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(result.sampleBuffer)!), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(CMSampleBufferGetImageBuffer(result.sampleBuffer)!), 1080)
    }

    func testTexturedTranslatedFramesReduceMeasuredTwoAxisJitterAtRealAnalysisCadence() throws {
        let width = 320
        let height = 240
        let sourceTranslations = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0),
            CGPoint(x: 3, y: 2), CGPoint(x: 3, y: 2),
            CGPoint(x: -3, y: -2), CGPoint(x: -3, y: -2),
            CGPoint(x: 3, y: 2), CGPoint(x: 3, y: 2),
            CGPoint(x: -3, y: -2), CGPoint(x: -3, y: -2),
        ]
        let stabilizer = MacOSVideoStabilizer()
        XCTAssertEqual(
            stabilizer.configure(width: width, height: height, framesPerSecond: 30),
            .available
        )
        var rawLandmarks: [CGPoint] = []
        var stabilizedLandmarks: [CGPoint] = []

        for (index, translation) in sourceTranslations.enumerated() {
            let sample = try makeTexturedSampleBuffer(
                width: width,
                height: height,
                translation: translation,
                presentationTimeStamp: CMTime(value: Int64(index * 20), timescale: 600)
            )
            let rawLandmark = try landmarkCentroid(in: sample)
            rawLandmarks.append(rawLandmark)
            let result = stabilizer.process(sampleBuffer: sample)
            XCTAssertTrue(result.isStabilized, "The bounded output pool should render this serial test sequence.")
            let stabilizedLandmark = try landmarkCentroid(in: result.sampleBuffer)
            stabilizedLandmarks.append(stabilizedLandmark)
            let sensorPoint = stabilizer.sensorPoint(
                fromOutputNormalized: CGPoint(
                    x: stabilizedLandmark.x / CGFloat(width),
                    y: stabilizedLandmark.y / CGFloat(height)
                )
            )
            XCTAssertEqual(sensorPoint.x, rawLandmark.x / CGFloat(width), accuracy: 1.25 / CGFloat(width))
            XCTAssertEqual(sensorPoint.y, rawLandmark.y / CGFloat(height), accuracy: 1.25 / CGFloat(height))
        }

        XCTAssertLessThan(
            meanSquaredAdjacentDifference(stabilizedLandmarks.map(\.x)),
            meanSquaredAdjacentDifference(rawLandmarks.map(\.x)) * 0.34,
            "The independent landmark oracle should measure less x-axis output jitter."
        )
        XCTAssertLessThan(
            meanSquaredAdjacentDifference(stabilizedLandmarks.map(\.y)),
            meanSquaredAdjacentDifference(rawLandmarks.map(\.y)) * 0.34,
            "The independent landmark oracle should measure less y-axis output jitter."
        )
    }

    func testCropPointInverseMatchesRenderedCenteredCropAndOriginalFallback() throws {
        let stabilizer = MacOSVideoStabilizer()
        XCTAssertEqual(stabilizer.configure(width: 320, height: 240, framesPerSecond: 30), .available)
        let croppedSample = try makeTexturedSampleBuffer(
            width: 320,
            height: 240,
            translation: .zero,
            presentationTimeStamp: .zero
        )
        XCTAssertTrue(stabilizer.process(sampleBuffer: croppedSample).isStabilized)

        let cropScale = 1 / (1 - (2 * MacOSVideoStabilizer.cropInsetFraction))
        let expectedInset = (1 - (1 / cropScale)) / 2
        let topLeftSensorPoint = stabilizer.sensorPoint(fromOutputNormalized: .zero)
        XCTAssertEqual(topLeftSensorPoint.x, expectedInset, accuracy: 0.0001)
        XCTAssertEqual(topLeftSensorPoint.y, expectedInset, accuracy: 0.0001)
        XCTAssertEqual(
            stabilizer.sensorPoint(fromOutputNormalized: CGPoint(x: 0.5, y: 0.5)),
            CGPoint(x: 0.5, y: 0.5)
        )

        let mismatchedSample = try makeTexturedSampleBuffer(
            width: 640,
            height: 480,
            translation: .zero,
            presentationTimeStamp: CMTime(value: 20, timescale: 600)
        )
        XCTAssertFalse(stabilizer.process(sampleBuffer: mismatchedSample).isStabilized)
        XCTAssertEqual(stabilizer.sensorPoint(fromOutputNormalized: .zero), .zero)
    }

    func testResetMotionClearsMotionStateButKeepsConfiguredPools() throws {
        let width = 320
        let height = 240
        let stabilizer = MacOSVideoStabilizer()
        XCTAssertEqual(
            stabilizer.configure(width: width, height: height, framesPerSecond: 30),
            .available
        )
        let outputPool = try XCTUnwrap(stabilizer.outputPool)
        let analysisPool = try XCTUnwrap(stabilizer.analysisPool)
        let center = CGPoint(x: 0.5, y: 0.5)

        let translations = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0),
            CGPoint(x: 3, y: 2), CGPoint(x: 3, y: 2),
        ]
        for (index, translation) in translations.enumerated() {
            let sample = try makeTexturedSampleBuffer(
                width: width,
                height: height,
                translation: translation,
                presentationTimeStamp: CMTime(value: Int64(index * 20), timescale: 600)
            )
            XCTAssertTrue(stabilizer.process(sampleBuffer: sample).isStabilized)
        }
        let correctedCenter = stabilizer.sensorPoint(fromOutputNormalized: center)
        XCTAssertGreaterThan(
            abs(correctedCenter.x - center.x) + abs(correctedCenter.y - center.y),
            0.001,
            "The translated sequence should accumulate a non-zero correction."
        )

        stabilizer.resetMotion()

        XCTAssertTrue(stabilizer.outputPool === outputPool, "resetMotion must not reallocate the output pool.")
        XCTAssertTrue(stabilizer.analysisPool === analysisPool, "resetMotion must not reallocate the analysis pool.")
        XCTAssertNil(stabilizer.lastFrameFallbackReason)
        XCTAssertEqual(
            stabilizer.sensorPoint(fromOutputNormalized: .zero),
            .zero,
            "No cropped frame has been rendered since the reset."
        )

        // A different translation than the last pre-reset frame: registering
        // against a stale reference frame would produce a new correction.
        let resumedSample = try makeTexturedSampleBuffer(
            width: width,
            height: height,
            translation: CGPoint(x: -3, y: -2),
            presentationTimeStamp: CMTime(value: 200, timescale: 600)
        )
        let resumed = stabilizer.process(sampleBuffer: resumedSample)
        XCTAssertTrue(resumed.isStabilized, "The configured profile must survive resetMotion.")
        XCTAssertNil(resumed.fallbackReason)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(CMSampleBufferGetImageBuffer(resumed.sampleBuffer))), width)
        XCTAssertEqual(CVPixelBufferGetHeight(try XCTUnwrap(CMSampleBufferGetImageBuffer(resumed.sampleBuffer))), height)
        let resumedCenter = stabilizer.sensorPoint(fromOutputNormalized: center)
        XCTAssertEqual(resumedCenter.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(resumedCenter.y, center.y, accuracy: 0.0001)
        XCTAssertTrue(stabilizer.outputPool === outputPool)
        XCTAssertTrue(stabilizer.analysisPool === analysisPool)
    }

    func testHeldOutputBuffersDoNotFallBackToRawFrames() throws {
        let width = 320
        let height = 240
        let stabilizer = MacOSVideoStabilizer()
        XCTAssertEqual(
            stabilizer.configure(width: width, height: height, framesPerSecond: 30),
            .available
        )
        // Downstream consumers keep several output frames alive at once: the
        // session's latest frame, the preview texture, Flutter's previous
        // frame and frames queued in the encoder.
        let heldFrameCount = 6
        XCTAssertLessThan(heldFrameCount, MacOSVideoStabilizer.maximumOutputBuffers)
        var held: [CMSampleBuffer] = []
        for index in 0..<24 {
            let sample = try makeTexturedSampleBuffer(
                width: width,
                height: height,
                translation: .zero,
                presentationTimeStamp: CMTime(value: Int64(index * 20), timescale: 600)
            )
            let result = stabilizer.process(sampleBuffer: sample)
            XCTAssertTrue(
                result.isStabilized,
                "Frame \(index) fell back to the raw frame: \(result.fallbackReason ?? "no reason")"
            )
            XCTAssertFalse(
                CMSampleBufferGetImageBuffer(result.sampleBuffer)! === CMSampleBufferGetImageBuffer(sample)!,
                "Frame \(index) returned the uncropped source buffer."
            )
            held.append(result.sampleBuffer)
            if held.count > heldFrameCount { held.removeFirst() }
        }
        XCTAssertEqual(held.count, heldFrameCount)
    }

    private func meanSquaredAdjacentDifference(_ values: [CGFloat]) -> CGFloat {
        let differences = zip(values.dropFirst(), values).map { current, previous in
            let difference = current - previous
            return difference * difference
        }
        return differences.reduce(0, +) / CGFloat(differences.count)
    }

    private func makeSampleBuffer(
        width: Int,
        height: Int,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        guard let pixelBuffer else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 1)
        }

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        guard let formatDescription else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 2)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        guard let sampleBuffer else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 3)
        }
        return sampleBuffer
    }

    private func makeTexturedSampleBuffer(
        width: Int,
        height: Int,
        translation: CGPoint,
        presentationTimeStamp: CMTime
    ) throws -> CMSampleBuffer {
        let sampleBuffer = try makeSampleBuffer(
            width: width,
            height: height,
            presentationTimeStamp: presentationTimeStamp,
            duration: CMTime(value: 20, timescale: 600)
        )
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 4)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 5)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let markerCenter = CGPoint(x: CGFloat(width / 2), y: CGFloat(height / 2))
        for y in 0 ..< height {
            for x in 0 ..< width {
                let sourceX = x - Int(translation.x)
                let sourceY = y - Int(translation.y)
                let pixel = baseAddress.advanced(by: (y * bytesPerRow) + (x * 4))
                    .assumingMemoryBound(to: UInt8.self)
                let isMarker = abs(CGFloat(sourceX) - markerCenter.x) <= 3
                    && abs(CGFloat(sourceY) - markerCenter.y) <= 3
                if isMarker {
                    pixel[0] = 255
                    pixel[1] = 255
                    pixel[2] = 255
                    pixel[3] = 255
                } else if sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height {
                    let texture = UInt8((sourceX * 37 + sourceY * 17 + (sourceX * sourceY)) % 96)
                    pixel[0] = texture
                    pixel[1] = texture &+ 32
                    pixel[2] = texture &+ 64
                    pixel[3] = 255
                } else {
                    pixel[0] = 0
                    pixel[1] = 0
                    pixel[2] = 0
                    pixel[3] = 255
                }
            }
        }
        return sampleBuffer
    }

    private func landmarkCentroid(in sampleBuffer: CMSampleBuffer) throws -> CGPoint {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 6)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 7)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var totalX: CGFloat = 0
        var totalY: CGFloat = 0
        var markerPixels = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = baseAddress.advanced(by: (y * bytesPerRow) + (x * 4))
                    .assumingMemoryBound(to: UInt8.self)
                if pixel[0] > 220, pixel[1] > 220, pixel[2] > 220 {
                    totalX += CGFloat(x)
                    totalY += CGFloat(y)
                    markerPixels += 1
                }
            }
        }
        guard markerPixels > 0 else {
            throw NSError(domain: "MacOSVideoStabilizerTests", code: 8)
        }
        return CGPoint(
            x: totalX / CGFloat(markerPixels),
            y: totalY / CGFloat(markerPixels)
        )
    }
}
