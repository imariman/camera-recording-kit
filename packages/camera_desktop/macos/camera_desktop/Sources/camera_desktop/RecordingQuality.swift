// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation

/// AVFoundation format discovery and finalized-file inspection for macOS.
enum RecordingQuality {
    enum VideoCodec: String, CaseIterable {
        case h264
        case hevc

        var avVideoCodecType: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            }
        }

        var displayName: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC/H.265"
            }
        }
    }

    struct Profile: Hashable {
        let width: Int32
        let height: Int32
        let framesPerSecond: Int
    }

    struct SelectedFormat {
        let format: AVCaptureDevice.Format
        let profile: Profile
    }

    private struct SupportedProfile {
        let profile: Profile
        let codecs: [VideoCodec]
    }

    static let errorDomain = "dev.teleprompter.camera_desktop.recording_quality"

    /// The app intentionally exposes only SDR profiles through 4K. 640x480p30
    /// is retained as a safe fallback for older built-in and USB cameras.
    static let requestedProfiles: [Profile] = [
        Profile(width: 640, height: 480, framesPerSecond: 30),
        Profile(width: 1280, height: 720, framesPerSecond: 30),
        Profile(width: 1280, height: 720, framesPerSecond: 60),
        Profile(width: 1920, height: 1080, framesPerSecond: 30),
        Profile(width: 1920, height: 1080, framesPerSecond: 60),
        Profile(width: 3840, height: 2160, framesPerSecond: 30),
        Profile(width: 3840, height: 2160, framesPerSecond: 60),
    ]

    static func capabilities(cameraName: String) throws -> [String: Any] {
        let device = try resolveDevice(cameraName: cameraName)
        let supportedProfiles = supportedProfilesWithCodecs(for: device)
        return [
            "cameraUniqueId": device.uniqueID,
            "cameraType": deviceKind(for: device),
            "profiles": supportedProfiles.map {
                [
                    "width": Int($0.profile.width),
                    "height": Int($0.profile.height),
                    "fps": $0.profile.framesPerSecond,
                    "codecs": $0.codecs.map { $0.rawValue },
                ]
            },
            "supportsFocusLock": device.isFocusModeSupported(.locked),
            "supportsExposureLock": device.isExposureModeSupported(.locked),
            "supportsFocusPoint": device.isFocusPointOfInterestSupported,
            "supportsExposurePoint": device.isExposurePointOfInterestSupported,
            "supportsVideoStabilization": supportedProfiles.contains {
                MacOSVideoStabilizer.availability(
                    width: Int($0.profile.width), height: Int($0.profile.height),
                    framesPerSecond: $0.profile.framesPerSecond
                ).isAvailable
            },
            "supportsRecordingPause": true,
        ]
    }

    static func resolveDevice(cameraName: String) throws -> AVCaptureDevice {
        let requestedId = DeviceEnumerator.extractDeviceId(from: cameraName) ?? cameraName
        guard let device = AVCaptureDevice.captureDevices(mediaType: .video).first(where: {
            $0.uniqueID == requestedId
        }) else {
            throw qualityError("Camera '\(cameraName)' is unavailable.")
        }
        return device
    }

    static func supportedProfiles(for device: AVCaptureDevice) -> [Profile] {
        supportedProfilesWithCodecs(for: device).map { $0.profile }
    }

    private static func supportedProfilesWithCodecs(
        for device: AVCaptureDevice
    ) -> [SupportedProfile] {
        var deviceProfiles = Set<Profile>()
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            for profile in requestedProfiles where
                profile.width == dimensions.width && profile.height == dimensions.height &&
                supports(frameRate: Double(profile.framesPerSecond), on: format)
            {
                deviceProfiles.insert(profile)
            }
        }
        return deviceProfiles.compactMap { profile -> SupportedProfile? in
            let codecs = supportedCodecs(for: profile)
            return codecs.isEmpty ? nil : SupportedProfile(profile: profile, codecs: codecs)
        }.sorted { profileSort($0.profile, $1.profile) }
    }

    static func supportedCodecs(for profile: Profile) -> [VideoCodec] {
        VideoCodec.allCases.filter { supportsEncoding(profile: profile, codec: $0) }
    }

    /// Selects an exact device format for the Flutter ResolutionPreset index.
    /// `max` selects the highest advertised app profile at the requested FPS;
    /// every other supported preset maps to one exact size.
    static func selectFormat(
        for device: AVCaptureDevice,
        resolutionPreset: Int,
        framesPerSecond: Int,
        codec: VideoCodec = .h264
    ) throws -> SelectedFormat {
        guard framesPerSecond == 30 || framesPerSecond == 60 else {
            throw unsupportedProfileError(
                "Only explicit 30 or 60 FPS recording profiles are supported; requested \(framesPerSecond) FPS."
            )
        }

        let targetProfiles: [Profile]
        if resolutionPreset == 5 {
            targetProfiles = requestedProfiles
                .filter { $0.framesPerSecond == framesPerSecond }
                .sorted(by: { lhs, rhs in
                    let lhsPixels = Int64(lhs.width) * Int64(lhs.height)
                    let rhsPixels = Int64(rhs.width) * Int64(rhs.height)
                    return lhsPixels > rhsPixels
                })
        } else {
            guard let dimensions = requestedDimensions(for: resolutionPreset) else {
                throw unsupportedProfileError(
                    "Resolution preset \(resolutionPreset) is not supported for strict recording."
                )
            }
            targetProfiles = [
                Profile(
                    width: dimensions.width,
                    height: dimensions.height,
                    framesPerSecond: framesPerSecond
                )
            ]
        }

        for target in targetProfiles where supportsEncoding(profile: target, codec: codec) {
            if let format = device.formats.first(where: { candidate in
                let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
                return dimensions.width == target.width &&
                    dimensions.height == target.height &&
                    supports(frameRate: Double(framesPerSecond), on: candidate)
            }) {
                return SelectedFormat(format: format, profile: target)
            }
        }

        let requestedDescription: String
        if let first = targetProfiles.first, resolutionPreset != 5 {
            requestedDescription = "\(first.width)x\(first.height) at \(framesPerSecond) FPS"
        } else {
            requestedDescription = "the highest profile at \(framesPerSecond) FPS"
        }
        throw unsupportedProfileError(
            "Camera '\(device.localizedName)' cannot record \(requestedDescription) with the \(codec.displayName) MP4 encoder."
        )
    }

    static func requestedDimensions(for resolutionPreset: Int) -> (width: Int32, height: Int32)? {
        switch resolutionPreset {
        case 0, 1:
            return (640, 480)
        case 2:
            return (1280, 720)
        case 3:
            return (1920, 1080)
        case 4:
            return (3840, 2160)
        default:
            return nil
        }
    }

    static func framesPerSecond(for duration: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite && seconds > 0 else { return nil }
        return 1.0 / seconds
    }

    static func inspectMedia(
        path: String,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                completion(.failure(qualityError("Recording file does not exist at '\(path)'.")))
                return
            }

            let asset = AVURLAsset(url: url)
            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                var loadingError: NSError?
                guard asset.statusOfValue(forKey: "tracks", error: &loadingError) == .loaded,
                      asset.statusOfValue(forKey: "duration", error: &loadingError) == .loaded,
                      let videoTrack = asset.tracks(withMediaType: .video).first else {
                    completion(.failure(
                        loadingError ?? qualityError("Recording has no readable video track.")
                    ))
                    return
                }

                let durationSeconds = CMTimeGetSeconds(asset.duration)
                let naturalSize = videoTrack.naturalSize
                var metadata: [String: Any] = [
                    "width": Int(abs(naturalSize.width).rounded()),
                    "height": Int(abs(naturalSize.height).rounded()),
                    "dimensionsSource": "trackNaturalSize",
                    "rotationDegrees": rotationDegrees(for: videoTrack.preferredTransform),
                    "mimeType": mimeType(for: url),
                ]

                if durationSeconds.isFinite && durationSeconds >= 0 {
                    metadata["durationMilliseconds"] = Int((durationSeconds * 1000).rounded())
                }

                if videoTrack.nominalFrameRate > 0 {
                    metadata["fps"] = Double(videoTrack.nominalFrameRate)
                    metadata["fpsSource"] = "nominal"
                } else if durationSeconds.isFinite && durationSeconds > 0,
                          let measuredFps = measuredFrameRate(asset: asset, track: videoTrack) {
                    metadata["fps"] = measuredFps
                    metadata["fpsSource"] = "measured"
                }

                if videoTrack.estimatedDataRate > 0 {
                    metadata["bitrate"] = Int(videoTrack.estimatedDataRate.rounded())
                    metadata["bitrateSource"] = "estimated"
                } else if durationSeconds.isFinite && durationSeconds > 0,
                          let fileSize = fileSize(at: url) {
                    metadata["bitrate"] = Int((Double(fileSize) * 8 / durationSeconds).rounded())
                    metadata["bitrateSource"] = "estimated"
                }

                if let codec = codec(for: videoTrack) {
                    metadata["codec"] = codec
                    metadata["codecSource"] = "formatDescription"
                }
                if let fileSize = fileSize(at: url) {
                    metadata["fileSizeBytes"] = fileSize
                }
                completion(.success(metadata))
            }
        }
    }

    /// UVC cameras often report NTSC-style or rounded rates (29.97, 30.00003,
    /// 59.94) for what is a 30 or 60 FPS mode. Rates this close to the
    /// requested one count as that profile. 0.1 FPS covers 60000/1001.
    static let frameRateTolerance = 0.1

    static func supports(frameRate: Double, on format: AVCaptureDevice.Format) -> Bool {
        return format.videoSupportedFrameRateRanges.contains {
            supports(
                frameRate: frameRate,
                minFrameRate: Double($0.minFrameRate),
                maxFrameRate: Double($0.maxFrameRate)
            )
        }
    }

    static func supports(frameRate: Double, minFrameRate: Double, maxFrameRate: Double) -> Bool {
        return minFrameRate - frameRateTolerance <= frameRate
            && frameRate <= maxFrameRate + frameRateTolerance
    }

    /// Whether a measured or applied rate matches the requested one.
    static func matches(frameRate: Double, requested: Int) -> Bool {
        return abs(frameRate - Double(requested)) <= frameRateTolerance
    }

    /// The frame duration to apply for `framesPerSecond` on `format`.
    /// AVFoundation raises an exception for a duration outside every
    /// supported range, so a rate accepted only within the tolerance is
    /// clamped to the nearest bound of its range.
    static func frameDuration(framesPerSecond: Int, on format: AVCaptureDevice.Format) -> CMTime {
        let requested = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        let ranges = format.videoSupportedFrameRateRanges
        let fps = Double(framesPerSecond)
        if ranges.contains(where: { Double($0.minFrameRate) <= fps && fps <= Double($0.maxFrameRate) }) {
            return requested
        }
        guard let range = ranges.first(where: {
            supports(frameRate: fps, minFrameRate: Double($0.minFrameRate), maxFrameRate: Double($0.maxFrameRate))
        }) else {
            return requested
        }
        return clamp(requested, minimum: range.minFrameDuration, maximum: range.maxFrameDuration)
    }

    static func clamp(_ duration: CMTime, minimum: CMTime, maximum: CMTime) -> CMTime {
        if CMTimeCompare(duration, minimum) < 0 { return minimum }
        if CMTimeCompare(duration, maximum) > 0 { return maximum }
        return duration
    }

    static func supportsEncoding(profile: Profile, codec: VideoCodec = .h264) -> Bool {
        let settings: [String: Any] = [
            AVVideoCodecKey: codec.avVideoCodecType,
            AVVideoWidthKey: Int(profile.width),
            AVVideoHeightKey: Int(profile.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: profile.framesPerSecond,
            ],
        ]
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-desktop-quality-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return false
        }
        return writer.canApply(outputSettings: settings, forMediaType: .video)
    }

    static func deviceKind(for device: AVCaptureDevice) -> String {
        if #available(macOS 14.0, *), device.deviceType == .continuityCamera {
            return "continuity"
        }
        let modelId = device.modelID.lowercased()
        let name = device.localizedName.lowercased()
        if modelId.contains("iphone") || modelId.contains("ipad") ||
            name.contains("iphone") || name.contains("continuity") {
            return "continuity"
        }
        if device.position == .front || device.position == .back ||
            device.deviceType == .builtInWideAngleCamera {
            return "internal"
        }
        return "external"
    }

    private static func profileSort(_ lhs: Profile, _ rhs: Profile) -> Bool {
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        return lhs.framesPerSecond < rhs.framesPerSecond
    }

    private static func measuredFrameRate(asset: AVAsset, track: AVAssetTrack) -> Double? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let deadline = DispatchTime.now() + .seconds(2)
        var frameCount = 0
        var firstPresentationTime: CMTime?
        var lastPresentationTime: CMTime?
        while DispatchTime.now() < deadline && frameCount < 300,
              let sampleBuffer = output.copyNextSampleBuffer() {
            frameCount += 1
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            firstPresentationTime = firstPresentationTime ?? presentationTime
            lastPresentationTime = presentationTime
        }
        reader.cancelReading()
        guard frameCount > 1,
              let firstPresentationTime = firstPresentationTime,
              let lastPresentationTime = lastPresentationTime else {
            return nil
        }
        let sampledDuration = CMTimeGetSeconds(
            CMTimeSubtract(lastPresentationTime, firstPresentationTime)
        )
        guard sampledDuration.isFinite && sampledDuration > 0 else { return nil }
        return Double(frameCount - 1) / sampledDuration
    }

    private static func fileSize(at url: URL) -> Int? {
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private static func codec(for track: AVAssetTrack) -> String? {
        guard let rawDescription = track.formatDescriptions.first,
              CFGetTypeID(rawDescription as CFTypeRef) == CMFormatDescriptionGetTypeID() else {
            return nil
        }
        let description = rawDescription as! CMFormatDescription
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let characters = [
            Character(UnicodeScalar((subtype >> 24) & 0xff)!),
            Character(UnicodeScalar((subtype >> 16) & 0xff)!),
            Character(UnicodeScalar((subtype >> 8) & 0xff)!),
            Character(UnicodeScalar(subtype & 0xff)!),
        ]
        return String(characters).trimmingCharacters(in: .whitespaces)
    }

    private static func rotationDegrees(for transform: CGAffineTransform) -> Int {
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        let normalized = Int(angle.rounded()) % 360
        return normalized >= 0 ? normalized : normalized + 360
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        default: return "video/mp4"
        }
    }

    static func qualityError(_ message: String) -> NSError {
        return NSError(
            domain: errorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func unsupportedProfileError(_ message: String) -> NSError {
        return NSError(
            domain: errorDomain,
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
