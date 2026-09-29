// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation
import XCTest
@testable import camera_desktop

final class RecordHandlerTests: XCTestCase {
    func testPauseResumeProducesReadableSynchronizedMP4AndStopsWhilePaused() throws {
        let profile = RecordingQuality.Profile(
            width: 640,
            height: 480,
            framesPerSecond: 30
        )
        try XCTSkipUnless(
            RecordingQuality.supportsEncoding(profile: profile),
            "This Mac has no H.264 encoder for the fallback recording profile."
        )

        var now = time(10)
        let handler = RecordHandler(
            timeline: RecordingTimeline(clock: { now })
        )
        let outputPath = try handler.startRecording(
            width: Int(profile.width),
            height: Int(profile.height),
            targetFps: profile.framesPerSecond,
            targetBitrate: 1_000_000,
            audioBitrate: 128_000,
            enableAudio: true
        )
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        for frame in 0..<3 {
            XCTAssertTrue(
                handler.appendVideoBuffer(
                    try videoSample(
                        presentation: 10 + Double(frame) / 30,
                        width: Int(profile.width),
                        height: Int(profile.height)
                    )
                )
            )
        }
        XCTAssertTrue(
            handler.appendAudioBuffer(
                try audioSample(presentation: 10, duration: 0.1)
            )
        )

        now = time(10.1)
        XCTAssertTrue(handler.pause())
        XCTAssertTrue(handler.isPaused)
        XCTAssertFalse(handler.pause())
        XCTAssertFalse(
            handler.appendVideoBuffer(
                try videoSample(
                    presentation: 11,
                    width: Int(profile.width),
                    height: Int(profile.height)
                )
            )
        )
        XCTAssertFalse(
            handler.appendAudioBuffer(
                try audioSample(presentation: 11, duration: 0.1)
            )
        )

        now = time(12.1)
        XCTAssertTrue(handler.resume())
        XCTAssertFalse(handler.isPaused)
        XCTAssertFalse(handler.resume())

        // Audio deliberately resumes before video. Both inputs must use the
        // same two-second offset, independent of callback arrival order.
        XCTAssertTrue(
            handler.appendAudioBuffer(
                try audioSample(presentation: 12.1, duration: 0.1)
            )
        )
        for frame in 0..<4 {
            XCTAssertTrue(
                handler.appendVideoBuffer(
                    try videoSample(
                        presentation: 12.1 + Double(frame) / 30,
                        width: Int(profile.width),
                        height: Int(profile.height)
                    )
                )
            )
        }

        now = time(12.25)
        XCTAssertTrue(handler.pause())

        let finalized = expectation(description: "AVAssetWriter finalizes while paused")
        var finalizedPath: String?
        handler.stopRecording { path in
            finalizedPath = path
            finalized.fulfill()
        }

        XCTAssertFalse(handler.isRecording)
        XCTAssertFalse(handler.isPaused)
        XCTAssertFalse(handler.pause())
        XCTAssertFalse(handler.resume())
        wait(for: [finalized], timeout: 10)
        XCTAssertEqual(finalizedPath, outputPath)

        let asset = AVURLAsset(url: URL(fileURLWithPath: outputPath))
        let videoTrack = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let audioTrack = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        XCTAssertEqual(abs(videoTrack.naturalSize.width), 640, accuracy: 0.5)
        XCTAssertEqual(abs(videoTrack.naturalSize.height), 480, accuracy: 0.5)

        let videoTimes = try presentationTimes(asset: asset, track: videoTrack)
        let audioTimes = try presentationTimes(asset: asset, track: audioTrack)
        XCTAssertGreaterThanOrEqual(videoTimes.count, 6)
        XCTAssertGreaterThanOrEqual(audioTimes.count, 2)

        // The source buffers contain a two-second pause. A playable finalized
        // file should contain only the active ~0.2 seconds on both tracks.
        XCTAssertLessThan(maximumGap(videoTimes), 0.25)
        XCTAssertLessThan(maximumGap(audioTimes), 0.25)
        let finalVideoTime = try XCTUnwrap(videoTimes.last)
        let finalAudioTime = try XCTUnwrap(audioTimes.last)
        XCTAssertLessThan(
            abs(finalVideoTime - finalAudioTime),
            0.15
        )

        let duration = CMTimeGetSeconds(asset.duration)
        XCTAssertGreaterThan(duration, 0.1)
        XCTAssertLessThan(duration, 0.5)
    }

    func testStopWithoutVideoSampleFailsAndDeletesTemporaryFile() throws {
        let profile = RecordingQuality.Profile(
            width: 640,
            height: 480,
            framesPerSecond: 30
        )
        try XCTSkipUnless(
            RecordingQuality.supportsEncoding(profile: profile),
            "This Mac has no H.264 encoder for the fallback recording profile."
        )

        let now = time(10)
        let handler = RecordHandler(
            timeline: RecordingTimeline(clock: { now })
        )
        let outputPath = try handler.startRecording(
            width: Int(profile.width),
            height: Int(profile.height),
            targetFps: profile.framesPerSecond,
            targetBitrate: 1_000_000,
            audioBitrate: 128_000,
            enableAudio: true
        )
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputPath),
            "AVAssetWriter should create the temporary file when writing starts."
        )

        // Audio alone never starts the writer session.
        XCTAssertFalse(
            handler.appendAudioBuffer(
                try audioSample(presentation: 10, duration: 0.1)
            )
        )

        let stopped = expectation(description: "An empty recording stops")
        var finalizedPath: String? = outputPath
        handler.stopRecording { path in
            finalizedPath = path
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 10)

        XCTAssertNil(finalizedPath)
        XCTAssertFalse(handler.isRecording)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputPath),
            "A recording that could not be finalized must not leave its temporary file behind."
        )
    }

    func testTerminationStopFinalizesSynchronouslyOnMainThreadIntoReadableFile() throws {
        let profile = try fallbackProfile()
        let handler = RecordHandler(timeline: RecordingTimeline(clock: { self.time(10) }))
        let outputPath = try handler.startRecording(
            width: Int(profile.width),
            height: Int(profile.height),
            targetFps: profile.framesPerSecond,
            targetBitrate: 1_000_000,
            audioBitrate: 128_000,
            enableAudio: true
        )
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        XCTAssertEqual(
            handler.assetWriterForTesting?.movieFragmentInterval,
            RecordHandler.movieFragmentInterval,
            "The writer must emit movie fragments so an interrupted file stays recoverable."
        )
        for frame in 0..<10 {
            XCTAssertTrue(appendWhenReady(handler, try videoSample(
                presentation: 10 + Double(frame) / 30,
                width: Int(profile.width),
                height: Int(profile.height)
            )))
        }
        XCTAssertTrue(handler.appendAudioBuffer(try audioSample(presentation: 10, duration: 0.2)))

        // applicationWillTerminate blocks the main thread; the finalize must
        // complete without the main queue or run loop turning.
        XCTAssertTrue(Thread.isMainThread)
        let outcome = try XCTUnwrap(handler.stopRecordingAndWait(deadline: .now() + 10))
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.path, outputPath)
        XCTAssertFalse(handler.isRecording)
        XCTAssertNil(
            handler.stopRecordingAndWait(deadline: .now() + 1),
            "A second terminate-style stop has nothing to finalize."
        )

        let asset = AVURLAsset(url: URL(fileURLWithPath: outputPath))
        let videoTrack = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertNotNil(asset.tracks(withMediaType: .audio).first)
        XCTAssertGreaterThan(CMTimeGetSeconds(asset.duration), 0)
        XCTAssertGreaterThanOrEqual(try presentationTimes(asset: asset, track: videoTrack).count, 10)
    }

    func testUnfinalizedFragmentedRecordingIsReadable() throws {
        let profile = try fallbackProfile()
        let handler = RecordHandler(timeline: RecordingTimeline(clock: { self.time(10) }))
        let outputPath = try handler.startRecording(
            width: Int(profile.width),
            height: Int(profile.height),
            targetFps: profile.framesPerSecond,
            targetBitrate: 1_000_000,
            enableAudio: false
        )
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        // Three seconds of media crosses at least two fragment boundaries.
        var appended = 0
        for frame in 0..<90 {
            if appendWhenReady(handler, try videoSample(
                presentation: 10 + Double(frame) / 30,
                width: Int(profile.width),
                height: Int(profile.height)
            )) {
                appended += 1
            }
        }
        XCTAssertEqual(appended, 90)

        // Snapshot the file while the writer is still open, as a crash or a
        // kill would leave it: no finishWriting, no trailing moov update.
        let snapshotPath = NSTemporaryDirectory() + "camera_desktop_fragment_\(UUID().uuidString).mp4"
        defer { try? FileManager.default.removeItem(atPath: snapshotPath) }
        let deadline = Date().addingTimeInterval(5)
        var readable = false
        while !readable && Date() < deadline {
            try? FileManager.default.removeItem(atPath: snapshotPath)
            try FileManager.default.copyItem(atPath: outputPath, toPath: snapshotPath)
            readable = RecordHandler.isReadableRecording(atPath: snapshotPath)
            if !readable { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertTrue(readable, "An unfinalized fragmented MP4 should keep its written fragments.")

        let stopped = expectation(description: "Recording finalizes")
        handler.stopRecording { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 10)
    }

    func testWriterFailureIsReportedOnceAndStopsAppending() throws {
        let profile = try fallbackProfile()
        let handler = RecordHandler(timeline: RecordingTimeline(clock: { self.time(10) }))
        var failures: [String] = []
        handler.onWriterFailure = { failures.append($0) }
        let outputPath = try handler.startRecording(
            width: Int(profile.width),
            height: Int(profile.height),
            targetFps: profile.framesPerSecond,
            targetBitrate: 1_000_000,
            enableAudio: true
        )
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        for frame in 0..<3 {
            XCTAssertTrue(handler.appendVideoBuffer(try videoSample(
                presentation: 10 + Double(frame) / 30,
                width: Int(profile.width),
                height: Int(profile.height)
            )))
        }
        XCTAssertTrue(failures.isEmpty)

        // Make the writer leave `.writing` underneath the active recording.
        try XCTUnwrap(handler.assetWriterForTesting).cancelWriting()

        XCTAssertFalse(handler.appendVideoBuffer(try videoSample(
            presentation: 10.2,
            width: Int(profile.width),
            height: Int(profile.height)
        )))
        XCTAssertFalse(handler.appendAudioBuffer(try audioSample(presentation: 10.2, duration: 0.1)))
        XCTAssertFalse(handler.appendVideoBuffer(try videoSample(
            presentation: 10.3,
            width: Int(profile.width),
            height: Int(profile.height)
        )))
        XCTAssertEqual(failures.count, 1, "A writer failure must be reported exactly once.")
        XCTAssertTrue(handler.isRecording, "Dart still owns the stop call after a failure.")

        let stopped = expectation(description: "A failed recording stops")
        var stoppedPath: String?
        XCTAssertTrue(handler.stopRecording { path in
            stoppedPath = path
            stopped.fulfill()
        })
        wait(for: [stopped], timeout: 10)
        XCTAssertFalse(handler.isRecording)
        if let stoppedPath {
            XCTAssertTrue(
                RecordHandler.isReadableRecording(atPath: stoppedPath),
                "A salvaged partial recording must be readable."
            )
        }
    }

    func testSalvageKeepsReadablePartialFileAndDeletesUnreadableOne() throws {
        let garbagePath = NSTemporaryDirectory() + "camera_desktop_garbage_\(UUID().uuidString).mp4"
        try Data(repeating: 0x42, count: 4096).write(to: URL(fileURLWithPath: garbagePath))
        defer { try? FileManager.default.removeItem(atPath: garbagePath) }

        let salvaged = expectation(description: "Salvage decides")
        var salvagedPath: String? = garbagePath
        RecordHandler.salvagePartialRecording(atPath: garbagePath) { path in
            salvagedPath = path
            salvaged.fulfill()
        }
        wait(for: [salvaged], timeout: 10)
        XCTAssertNil(salvagedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: garbagePath))
    }

    /// Real-time writer inputs briefly report not ready when samples arrive
    /// faster than capture would deliver them; retry like a camera would.
    private func appendWhenReady(_ handler: RecordHandler, _ sample: CMSampleBuffer) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if handler.appendVideoBuffer(sample) { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return false
    }

    private func fallbackProfile() throws -> RecordingQuality.Profile {
        let profile = RecordingQuality.Profile(width: 640, height: 480, framesPerSecond: 30)
        try XCTSkipUnless(
            RecordingQuality.supportsEncoding(profile: profile),
            "This Mac has no H.264 encoder for the fallback recording profile."
        )
        return profile
    }

    private func videoSample(
        presentation: Double,
        width: Int,
        height: Int
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(imageBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) {
            memset(baseAddress, 0x20, CVPixelBufferGetDataSize(imageBuffer))
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var timing = CMSampleTimingInfo(
            duration: time(1.0 / 30),
            presentationTimeStamp: time(presentation),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func audioSample(
        presentation: Double,
        duration: Double
    ) throws -> CMSampleBuffer {
        let sampleRate = 44_100.0
        let frameCount = Int((sampleRate * duration).rounded())
        let bytesPerFrame = 4
        let byteCount = frameCount * bytesPerFrame

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let audioData = try XCTUnwrap(blockBuffer)
        XCTAssertEqual(
            CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: audioData,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ),
            kCMBlockBufferNoErr
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: time(presentation),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: audioData,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func presentationTimes(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: decodingSettings(for: track.mediaType)
        )
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var values: [Double] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if track.mediaType == .video {
                XCTAssertNotNil(
                    CMSampleBufferGetImageBuffer(sampleBuffer),
                    "The H.264 sample was not decoded to a pixel buffer."
                )
            } else if track.mediaType == .audio {
                XCTAssertNotNil(
                    CMSampleBufferGetDataBuffer(sampleBuffer),
                    "The AAC sample was not decoded to PCM data."
                )
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = CMTimeGetSeconds(timestamp)
            guard timestamp.isValid,
                  !timestamp.isIndefinite,
                  !timestamp.isPositiveInfinity,
                  !timestamp.isNegativeInfinity,
                  seconds.isFinite else {
                throw NSError(
                    domain: "RecordHandlerTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Decoded \(track.mediaType.rawValue) sample has an invalid PTS."
                    ]
                )
            }
            if let previous = values.last, seconds <= previous {
                throw NSError(
                    domain: "RecordHandlerTests",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Decoded \(track.mediaType.rawValue) PTS is not strictly monotonic."
                    ]
                )
            }
            values.append(seconds)
        }
        XCTAssertEqual(
            reader.status,
            .completed,
            reader.error?.localizedDescription ?? "AVAssetReader did not complete."
        )
        return values
    }

    private func decodingSettings(for mediaType: AVMediaType) -> [String: Any] {
        if mediaType == .video {
            return [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private func maximumGap(_ values: [Double]) -> Double {
        return zip(values, values.dropFirst())
            .map { current, next in next - current }
            .max() ?? 0
    }

    private func time(_ seconds: Double) -> CMTime {
        return CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
