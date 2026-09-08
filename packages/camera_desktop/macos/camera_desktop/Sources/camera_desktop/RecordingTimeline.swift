import AVFoundation

/// Removes time spent paused from capture sample timestamps.
///
/// The timeline must use the capture session's synchronization clock. Measuring
/// each pause against that clock gives both tracks one shared offset, regardless
/// of which track delivers its first sample after resume.
final class RecordingTimeline {
    enum Track: Hashable {
        case video
        case audio
    }

    typealias Clock = () -> CMTime

    private let defaultClock: Clock
    private var clock: Clock
    private var pauseStartedAt: CMTime?
    private var pausedDuration = CMTime.zero
    private var hasAcceptedSample = false
    private var lastPresentationTime: [Track: CMTime] = [:]
    private var lastDecodeTime: [Track: CMTime] = [:]
    private var resumeCutoff: [Track: CMTime] = [:]

    private(set) var isPaused = false

    init(clock: @escaping Clock = {
        CMClockGetTime(CMClockGetHostTimeClock())
    }) {
        defaultClock = clock
        self.clock = clock
    }

    /// Starts a pause. Repeated calls are no-ops.
    @discardableResult
    func pause() -> Bool {
        guard !isPaused else { return false }

        isPaused = true
        // Before the writer accepts its first sample there is no recorded
        // timeline from which a pause needs to be removed.
        pauseStartedAt = hasAcceptedSample ? clock() : nil
        return true
    }

    /// Ends a pause. Repeated calls are no-ops.
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }

        let resumedAt = clock()
        if let pauseStartedAt = pauseStartedAt {
            if isNumeric(resumedAt),
               isNumeric(pauseStartedAt),
               CMTimeCompare(resumedAt, pauseStartedAt) > 0 {
                pausedDuration = CMTimeAdd(
                    pausedDuration,
                    CMTimeSubtract(resumedAt, pauseStartedAt)
                )
            }
        }
        if isNumeric(resumedAt) {
            resumeCutoff[.video] = resumedAt
            resumeCutoff[.audio] = resumedAt
        }

        pauseStartedAt = nil
        isPaused = false
        return true
    }

    /// Returns a retimed copy suitable for the asset writer.
    ///
    /// Samples received while paused are dropped. A sample that would move a
    /// track's presentation or decode timestamp backwards is also dropped;
    /// this can happen when an in-flight capture callback reaches the handler
    /// immediately after resume.
    func adjustedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        track: Track
    ) -> CMSampleBuffer? {
        guard !isPaused else { return nil }

        var timingCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard countStatus == noErr, timingCount > 0 else { return nil }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        let timingStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard timingStatus == noErr else { return nil }

        if let cutoff = resumeCutoff[track],
           timing.contains(where: {
               isNumeric($0.presentationTimeStamp) &&
                   CMTimeCompare($0.presentationTimeStamp, cutoff) < 0
           }) {
            return nil
        }

        for index in timing.indices {
            timing[index].presentationTimeStamp = subtractPausedDuration(
                from: timing[index].presentationTimeStamp
            )
            timing[index].decodeTimeStamp = subtractPausedDuration(
                from: timing[index].decodeTimeStamp
            )
        }

        guard timestampsAreMonotonic(timing, track: track) else { return nil }

        var adjustedBuffer: CMSampleBuffer?
        let copyStatus = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &adjustedBuffer
            )
        }
        guard copyStatus == noErr, let adjustedBuffer = adjustedBuffer else {
            return nil
        }

        rememberLastTimestamps(timing, track: track)
        resumeCutoff[track] = nil
        hasAcceptedSample = true
        return adjustedBuffer
    }

    /// Clears all state before a new recording or after finalization.
    func reset(clock: Clock? = nil) {
        self.clock = clock ?? defaultClock
        pauseStartedAt = nil
        pausedDuration = .zero
        hasAcceptedSample = false
        lastPresentationTime.removeAll(keepingCapacity: true)
        lastDecodeTime.removeAll(keepingCapacity: true)
        resumeCutoff.removeAll(keepingCapacity: true)
        isPaused = false
    }

    private func subtractPausedDuration(from timestamp: CMTime) -> CMTime {
        guard isNumeric(timestamp) else { return timestamp }
        return CMTimeSubtract(timestamp, pausedDuration)
    }

    private func timestampsAreMonotonic(
        _ timing: [CMSampleTimingInfo],
        track: Track
    ) -> Bool {
        var presentationTime = lastPresentationTime[track]
        var decodeTime = lastDecodeTime[track]

        for entry in timing {
            if isNumeric(entry.presentationTimeStamp) {
                if let previous = presentationTime,
                   CMTimeCompare(entry.presentationTimeStamp, previous) <= 0 {
                    return false
                }
                presentationTime = entry.presentationTimeStamp
            }
            if isNumeric(entry.decodeTimeStamp) {
                if let previous = decodeTime,
                   CMTimeCompare(entry.decodeTimeStamp, previous) <= 0 {
                    return false
                }
                decodeTime = entry.decodeTimeStamp
            }
        }
        return true
    }

    private func rememberLastTimestamps(
        _ timing: [CMSampleTimingInfo],
        track: Track
    ) {
        for entry in timing {
            if isNumeric(entry.presentationTimeStamp) {
                lastPresentationTime[track] = entry.presentationTimeStamp
            }
            if isNumeric(entry.decodeTimeStamp) {
                lastDecodeTime[track] = entry.decodeTimeStamp
            }
        }
    }

    private func isNumeric(_ time: CMTime) -> Bool {
        return time.isValid && !time.isIndefinite &&
            !time.isPositiveInfinity && !time.isNegativeInfinity
    }
}
