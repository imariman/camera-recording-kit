import AVFoundation

/// Manages video recording via AVAssetWriter.
class RecordHandler: NSObject {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputPath: String?
    private var sessionStarted = false
    private let lock = UnfairLock()
    private let timeline: RecordingTimeline
    private var recording = false
    private(set) var selectedVideoCodec: RecordingQuality.VideoCodec?

    var isRecording: Bool {
        lock.lock()
        let value = recording
        lock.unlock()
        return value
    }

    var isPaused: Bool {
        lock.lock()
        let value = recording && timeline.isPaused
        lock.unlock()
        return value
    }

    override convenience init() {
        self.init(timeline: RecordingTimeline())
    }

    init(timeline: RecordingTimeline) {
        self.timeline = timeline
        super.init()
    }

    /// Starts recording to a temporary file.
    /// - Parameters:
    ///   - width: Video frame width.
    ///   - height: Video frame height.
    ///   - targetFps: Target frame rate for encoder hints.
    ///   - targetBitrate: Target average bitrate in bits per second (0 = default).
    ///   - videoCodec: The AVAssetWriter video codec, already verified during
    ///     controller creation.
    ///   - enableAudio: Whether to record audio.
    ///   - captureClock: The capture session clock used by sample timestamps.
    /// - Returns: The output file path on success.
    /// - Throws: If the asset writer cannot be created.
    func startRecording(width: Int,
                        height: Int,
                        targetFps: Int,
                        targetBitrate: Int,
                        audioBitrate: Int = 0,
                        videoCodec: RecordingQuality.VideoCodec = .h264,
                        enableAudio: Bool,
                        captureClock: CMClock? = nil) throws -> String {
        lock.lock()
        if recording {
            lock.unlock()
            throw NSError(domain: "camera_desktop", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Already recording"])
        }
        lock.unlock()

        let path = RecordHandler.generatePath()
        let url = URL(fileURLWithPath: path)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let profile = RecordingQuality.Profile(
            width: Int32(width),
            height: Int32(height),
            framesPerSecond: targetFps
        )
        guard RecordingQuality.requestedProfiles.contains(profile) else {
            throw RecordingQuality.unsupportedProfileError(
                "Refusing to encode an unadvertised profile: \(width)x\(height) at \(targetFps) FPS."
            )
        }

        // Video input. Keep the codec explicit: AVAssetWriter must never
        // substitute HEVC for H.264 (or vice versa) behind the Dart contract.
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: targetFps,
            AVVideoMaxKeyFrameIntervalKey: max(targetFps, 1),
        ]
        if targetBitrate > 0 {
            compression[AVVideoAverageBitRateKey] = targetBitrate
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec.avVideoCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecordingQuality.unsupportedProfileError(
                "The \(videoCodec.displayName) encoder rejected \(width)x\(height) at \(targetFps) FPS."
            )
        }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else {
            throw RecordingQuality.unsupportedProfileError(
                "The \(videoCodec.displayName) encoder input rejected the requested recording profile."
            )
        }
        writer.add(vInput)

        // Audio input, AAC encoding.
        var aInput: AVAssetWriterInput?
        if enableAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate > 0 ? audioBitrate : 128000,
            ]
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw NSError(
                    domain: "camera_desktop",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "The AAC encoder rejected the requested audio settings."]
                )
            }
            let audioWriterInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings
            )
            audioWriterInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioWriterInput) else {
                throw NSError(
                    domain: "camera_desktop",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "The AAC encoder input is unavailable."]
                )
            }
            writer.add(audioWriterInput)
            aInput = audioWriterInput
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "camera_desktop",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter could not start."]
            )
        }

        lock.lock()
        assetWriter = writer
        videoInput = vInput
        audioInput = aInput
        outputPath = path
        sessionStarted = false
        let timelineClock = captureClock.map { clock in
            { CMClockGetTime(clock) }
        }
        timeline.reset(clock: timelineClock)
        recording = true
        selectedVideoCodec = videoCodec
        lock.unlock()

        return path
    }

    /// Appends a video sample buffer to the recording.
    @discardableResult
    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        guard recording else {
            lock.unlock()
            return false
        }
        guard let writer = assetWriter else {
            lock.unlock()
            return false
        }
        guard writer.status == .writing else {
            lock.unlock()
            return false
        }
        guard let input = videoInput else {
            lock.unlock()
            return false
        }
        guard input.isReadyForMoreMediaData else {
            lock.unlock()
            return false
        }
        guard let adjustedBuffer = timeline.adjustedSampleBuffer(
            sampleBuffer,
            track: .video
        ) else {
            lock.unlock()
            return false
        }

        if !sessionStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }
        let appended = input.append(adjustedBuffer)
        lock.unlock()
        return appended
    }

    /// Appends an audio sample buffer to the recording.
    @discardableResult
    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        guard recording else {
            lock.unlock()
            return false
        }
        guard let writer = assetWriter else {
            lock.unlock()
            return false
        }
        guard writer.status == .writing else {
            lock.unlock()
            return false
        }
        guard let input = audioInput else {
            lock.unlock()
            return false
        }
        guard input.isReadyForMoreMediaData else {
            lock.unlock()
            return false
        }
        guard sessionStarted else {
            lock.unlock()
            return false
        }
        guard let adjustedBuffer = timeline.adjustedSampleBuffer(
            sampleBuffer,
            track: .audio
        ) else {
            lock.unlock()
            return false
        }
        let appended = input.append(adjustedBuffer)
        lock.unlock()
        return appended
    }

    /// Pauses timestamp advancement and drops incoming capture samples.
    /// - Returns: `true` when this call entered the paused state.
    @discardableResult
    func pause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return false }
        return timeline.pause()
    }

    /// Resumes appending samples with time spent paused removed.
    /// - Returns: `true` when this call left the paused state.
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return false }
        return timeline.resume()
    }

    /// Stops recording and finalizes the file.
    ///
    /// When no file can be produced, the partially written temporary file is
    /// deleted before `completion` receives `nil`.
    /// - Parameter completion: Called with the output file path on success, or nil on failure.
    func stopRecording(completion: @escaping (String?) -> Void) {
        lock.lock()
        guard recording, let writer = assetWriter else {
            lock.unlock()
            completion(nil)
            return
        }

        recording = false
        let vInput = videoInput
        let aInput = audioInput
        let path = outputPath
        let didStartSession = sessionStarted

        assetWriter = nil
        videoInput = nil
        audioInput = nil
        outputPath = nil
        sessionStarted = false
        timeline.reset()
        lock.unlock()

        // Without an appended video sample the writer never started a
        // session, so finishWriting cannot produce a file. A writer that has
        // already failed cannot finalize either.
        guard didStartSession, writer.status == .writing else {
            writer.cancelWriting()
            RecordHandler.removeFile(atPath: path)
            completion(nil)
            return
        }

        vInput?.markAsFinished()
        aInput?.markAsFinished()

        writer.finishWriting {
            if writer.status == .completed {
                completion(path)
            } else {
                RecordHandler.removeFile(atPath: path)
                completion(nil)
            }
        }
    }

    /// Best-effort removal of an unfinalized recording file.
    private static func removeFile(atPath path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Generates a unique temporary file path for a video recording.
    static func generatePath() -> String {
        return NSTemporaryDirectory() + "camera_desktop_video_\(UUID().uuidString).mp4"
    }
}
