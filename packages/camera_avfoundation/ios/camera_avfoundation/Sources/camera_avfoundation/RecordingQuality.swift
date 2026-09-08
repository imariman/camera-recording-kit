// Copyright 2026 Teleprompter Studio. All rights reserved.

import AVFoundation

enum RecordingQuality {
  private struct Profile: Hashable {
    let width: Int32
    let height: Int32
    let framesPerSecond: Int
  }

  private static let requestedProfiles: [(width: Int32, height: Int32, frameRates: [Int])] = [
    (640, 480, [30]),
    (1280, 720, [30, 60]),
    (1920, 1080, [30, 60]),
    (3840, 2160, [30, 60]),
  ]

  static func capabilities(cameraName: String) throws -> [String: Any] {
    guard let device = AVCaptureDevice(uniqueID: cameraName) else {
      throw qualityError("Camera '\(cameraName)' is unavailable.")
    }

    var profiles = Set<Profile>()
    for format in device.formats {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      for requested in requestedProfiles
      where dimensions.width == requested.width && dimensions.height == requested.height
      {
        for fps in requested.frameRates
        where supports(frameRate: Double(fps), on: format)
          && supportsEncoding(width: dimensions.width, height: dimensions.height, fps: fps)
        {
          profiles.insert(Profile(width: dimensions.width, height: dimensions.height, framesPerSecond: fps))
        }
      }
    }

    let sortedProfiles = profiles.sorted {
      if $0.width != $1.width { return $0.width < $1.width }
      if $0.height != $1.height { return $0.height < $1.height }
      return $0.framesPerSecond < $1.framesPerSecond
    }

    return [
      "profiles": sortedProfiles.map {
        ["width": Int($0.width), "height": Int($0.height), "fps": $0.framesPerSecond]
      },
      "supportsFocusLock": device.isFocusModeSupported(.locked),
      "supportsExposureLock": device.isExposureModeSupported(.locked),
    ]
  }

  static func inspectMedia(path: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else {
        completion(.failure(qualityError("Recording file does not exist at '\(path)'.")))
        return
      }

      let asset = AVURLAsset(url: url)
      asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
        var error: NSError?
        guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
          asset.statusOfValue(forKey: "duration", error: &error) == .loaded,
          let videoTrack = asset.tracks(withMediaType: .video).first
        else {
          completion(.failure(error ?? qualityError("Recording has no readable video track.")))
          return
        }

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let naturalSize = videoTrack.naturalSize
        var metadata: [String: Any] = [
          "width": Int(abs(naturalSize.width)),
          "height": Int(abs(naturalSize.height)),
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
          let measuredFps = measuredFrameRate(asset: asset, track: videoTrack)
        {
          metadata["fps"] = measuredFps
          metadata["fpsSource"] = "measured"
        }

        if videoTrack.estimatedDataRate > 0 {
          metadata["bitrate"] = Int(videoTrack.estimatedDataRate.rounded())
          metadata["bitrateSource"] = "estimated"
        } else if durationSeconds.isFinite && durationSeconds > 0,
          let fileSize = fileSize(at: url)
        {
          metadata["bitrate"] = Int((Double(fileSize) * 8 / durationSeconds).rounded())
          // A file-size calculation includes the container and optional audio,
          // so it is only an estimate of the video-track bitrate.
          metadata["bitrateSource"] = "estimated"
        }

        if let codec = codec(for: videoTrack) {
          metadata["codec"] = codec
        }
        if let fileSize = fileSize(at: url) {
          metadata["fileSizeBytes"] = fileSize
        }
        completion(.success(metadata))
      }
    }
  }

  private static func supports(frameRate: Double, on format: AVCaptureDevice.Format) -> Bool {
    return format.videoSupportedFrameRateRanges.contains {
      Double($0.minFrameRate) <= frameRate && frameRate <= Double($0.maxFrameRate)
    }
  }

  private static func supportsEncoding(width: Int32, height: Int32, fps: Int) -> Bool {
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(width),
      AVVideoHeightKey: Int(height),
      AVVideoCompressionPropertiesKey: [
        AVVideoExpectedSourceFrameRateKey: fps
      ],
    ]
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("recording-quality-\(UUID().uuidString).mp4")
    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
      return false
    }
    return writer.canApply(outputSettings: settings, forMediaType: .video)
  }

  private static func measuredFrameRate(
    asset: AVAsset,
    track: AVAssetTrack
  ) -> Double? {
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
      let sampleBuffer = output.copyNextSampleBuffer()
    {
      frameCount += 1
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      firstPresentationTime = firstPresentationTime ?? presentationTime
      lastPresentationTime = presentationTime
    }
    reader.cancelReading()
    guard frameCount > 1, let firstPresentationTime, let lastPresentationTime else { return nil }
    let sampledDuration = CMTimeGetSeconds(CMTimeSubtract(lastPresentationTime, firstPresentationTime))
    guard sampledDuration.isFinite && sampledDuration > 0 else { return nil }
    return Double(frameCount - 1) / sampledDuration
  }

  private static func fileSize(at url: URL) -> Int? {
    return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
  }

  private static func codec(for track: AVAssetTrack) -> String? {
    guard let rawDescription = track.formatDescriptions.first,
      CFGetTypeID(rawDescription as CFTypeRef) == CMFormatDescriptionGetTypeID()
    else { return nil }
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
      domain: "dev.teleprompter.recording_quality",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
