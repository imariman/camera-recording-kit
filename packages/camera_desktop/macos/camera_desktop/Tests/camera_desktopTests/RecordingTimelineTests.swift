// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation
import XCTest
@testable import camera_desktop

final class RecordingTimelineTests: XCTestCase {
    func testPauseBeforeFirstSampleDoesNotCreatePhantomOffset() throws {
        var now = time(20)
        let timeline = RecordingTimeline(clock: { now })

        XCTAssertTrue(timeline.pause())
        XCTAssertFalse(timeline.pause())
        XCTAssertTrue(timeline.isPaused)
        XCTAssertNil(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 25, decode: 24.5),
                track: .video
            )
        )

        now = time(25)
        XCTAssertTrue(timeline.resume())
        XCTAssertFalse(timeline.resume())

        let adjusted = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 25, decode: 24.5),
                track: .video
            )
        )
        XCTAssertEqual(presentationSeconds(adjusted), 25, accuracy: 0.000_001)
        XCTAssertEqual(decodeSeconds(adjusted), 24.5, accuracy: 0.000_001)
    }

    func testInterleavedAudioAndVideoUseOneSharedPauseOffset() throws {
        var now = time(10.02)
        let timeline = RecordingTimeline(clock: { now })

        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 10, decode: 9.98),
                track: .video
            )
        )
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 10.01),
                track: .audio
            )
        )

        XCTAssertTrue(timeline.pause())
        now = time(14.02)
        XCTAssertTrue(timeline.resume())

        // Audio deliberately arrives first after resume. Its arrival order
        // must not choose a different offset for the video track.
        let audio = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 14.04),
                track: .audio
            )
        )
        let video = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 14.033, decode: 14.013),
                track: .video
            )
        )

        XCTAssertEqual(presentationSeconds(audio), 10.04, accuracy: 0.000_001)
        XCTAssertEqual(presentationSeconds(video), 10.033, accuracy: 0.000_001)
        XCTAssertEqual(decodeSeconds(video), 10.013, accuracy: 0.000_001)
        XCTAssertEqual(
            presentationSeconds(audio) - presentationSeconds(video),
            0.007,
            accuracy: 0.000_001
        )
    }

    func testRepeatedTransitionsAccumulateEachPauseExactlyOnce() throws {
        var now = time(1.1)
        let timeline = RecordingTimeline(clock: { now })
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 1),
                track: .video
            )
        )

        XCTAssertTrue(timeline.pause())
        now = time(2.1)
        XCTAssertFalse(timeline.pause())
        now = time(3.1)
        XCTAssertTrue(timeline.resume())
        XCTAssertFalse(timeline.resume())

        let afterFirstPause = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 3.2),
                track: .video
            )
        )
        XCTAssertEqual(
            presentationSeconds(afterFirstPause),
            1.2,
            accuracy: 0.000_001
        )

        now = time(3.3)
        XCTAssertTrue(timeline.pause())
        now = time(4.3)
        XCTAssertTrue(timeline.resume())

        let afterSecondPause = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 4.5),
                track: .video
            )
        )
        XCTAssertEqual(
            presentationSeconds(afterSecondPause),
            1.5,
            accuracy: 0.000_001
        )
    }

    func testPausedAndStaleQueuedSamplesAreRejectedPerTrack() throws {
        var now = time(10.1)
        let timeline = RecordingTimeline(clock: { now })
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 10),
                track: .video
            )
        )

        XCTAssertTrue(timeline.pause())
        XCTAssertNil(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 11),
                track: .video
            )
        )

        now = time(12.1)
        XCTAssertTrue(timeline.resume())
        XCTAssertNil(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 11.5),
                track: .video
            )
        )

        let currentVideo = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 12.2),
                track: .video
            )
        )
        XCTAssertNil(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 12.05),
                track: .audio
            )
        )
        let currentAudio = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 12.15),
                track: .audio
            )
        )
        XCTAssertEqual(presentationSeconds(currentVideo), 10.2, accuracy: 0.000_001)
        XCTAssertEqual(presentationSeconds(currentAudio), 10.15, accuracy: 0.000_001)
    }

    func testEveryTimingEntryIsShiftedAndInvalidDecodeTimeIsPreserved() throws {
        var now = time(5)
        let timeline = RecordingTimeline(clock: { now })
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 4.9),
                track: .audio
            )
        )
        XCTAssertTrue(timeline.pause())
        now = time(7)
        XCTAssertTrue(timeline.resume())

        let adjusted = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(
                    timing: [
                        timing(presentation: 7, decode: nil),
                        timing(presentation: 7.01, decode: nil),
                    ]
                ),
                track: .audio
            )
        )
        let adjustedTiming = try timingInfo(adjusted)

        XCTAssertEqual(seconds(adjustedTiming[0].presentationTimeStamp), 5, accuracy: 0.000_001)
        XCTAssertEqual(seconds(adjustedTiming[1].presentationTimeStamp), 5.01, accuracy: 0.000_001)
        XCTAssertFalse(adjustedTiming[0].decodeTimeStamp.isValid)
        XCTAssertFalse(adjustedTiming[1].decodeTimeStamp.isValid)
    }

    func testResetClearsPauseAndMonotonicityState() throws {
        var now = time(1)
        let timeline = RecordingTimeline(clock: { now })
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 10),
                track: .video
            )
        )
        XCTAssertTrue(timeline.pause())

        timeline.reset()
        now = time(20)

        XCTAssertFalse(timeline.isPaused)
        XCTAssertFalse(timeline.resume())
        let earlierTimestamp = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 1),
                track: .video
            )
        )
        XCTAssertEqual(presentationSeconds(earlierTimestamp), 1, accuracy: 0.000_001)
    }

    func testResetWithoutClockRestoresInitializerClock() throws {
        var defaultNow = time(20.1)
        var sessionNow = time(100.1)
        let timeline = RecordingTimeline(clock: { defaultNow })
        timeline.reset(clock: { sessionNow })
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 100),
                track: .video
            )
        )
        XCTAssertTrue(timeline.pause())
        sessionNow = time(102.1)
        XCTAssertTrue(timeline.resume())

        timeline.reset()
        _ = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 20),
                track: .video
            )
        )
        XCTAssertTrue(timeline.pause())
        defaultNow = time(22.1)
        XCTAssertTrue(timeline.resume())

        let adjusted = try XCTUnwrap(
            timeline.adjustedSampleBuffer(
                try sample(presentation: 22.2),
                track: .video
            )
        )
        XCTAssertEqual(presentationSeconds(adjusted), 20.2, accuracy: 0.000_001)
    }

    private func sample(
        presentation: Double,
        decode: Double? = nil
    ) throws -> CMSampleBuffer {
        return try sample(timing: [timing(presentation: presentation, decode: decode)])
    }

    private func sample(timing: [CMSampleTimingInfo]) throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var sizes = Array(repeating: 0, count: timing.count)
        let status = timing.withUnsafeBufferPointer { timingBuffer in
            sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: nil,
                    formatDescription: nil,
                    sampleCount: timing.count,
                    sampleTimingEntryCount: timing.count,
                    sampleTimingArray: timingBuffer.baseAddress,
                    sampleSizeEntryCount: sizeBuffer.count,
                    sampleSizeArray: sizeBuffer.baseAddress,
                    sampleBufferOut: &sampleBuffer
                )
            }
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func timing(
        presentation: Double,
        decode: Double?
    ) -> CMSampleTimingInfo {
        return CMSampleTimingInfo(
            duration: time(0.01),
            presentationTimeStamp: time(presentation),
            decodeTimeStamp: decode.map(time) ?? .invalid
        )
    }

    private func timingInfo(_ sampleBuffer: CMSampleBuffer) throws -> [CMSampleTimingInfo] {
        var count = 0
        XCTAssertEqual(
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: 0,
                arrayToFill: nil,
                entriesNeededOut: &count
            ),
            noErr
        )
        var values = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: count
        )
        let status = values.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: count,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        XCTAssertEqual(status, noErr)
        return values
    }

    private func presentationSeconds(_ sampleBuffer: CMSampleBuffer) -> Double {
        return seconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func decodeSeconds(_ sampleBuffer: CMSampleBuffer) -> Double {
        return seconds(CMSampleBufferGetDecodeTimeStamp(sampleBuffer))
    }

    private func seconds(_ value: CMTime) -> Double {
        return CMTimeGetSeconds(value)
    }

    private func time(_ seconds: Double) -> CMTime {
        return CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
