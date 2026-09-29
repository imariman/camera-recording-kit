// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation
import VideoToolbox

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

    /// Maps an `AVVideoCodecKey` value from writer settings back to a codec.
    init?(avVideoCodecType: AVVideoCodecType) {
      switch avVideoCodecType {
      case .h264: self = .h264
      case .hevc: self = .hevc
      default: return nil
      }
    }

    /// Reads the codec from asset writer video settings, or nil when the settings do not
    /// name one of the supported codecs.
    init?(writerSettings settings: [String: Any]?) {
      guard let raw = settings?[AVVideoCodecKey] else { return nil }
      if let type = raw as? AVVideoCodecType {
        self.init(avVideoCodecType: type)
      } else if let string = raw as? String {
        self.init(avVideoCodecType: AVVideoCodecType(rawValue: string))
      } else {
        return nil
      }
    }
  }

  private struct Profile: Hashable {
    let width: Int32
    let height: Int32
    let framesPerSecond: Int
  }

  private struct SupportedProfile {
    let profile: Profile
    let codecs: [VideoCodec]
  }

  private static let requestedProfiles: [(width: Int32, height: Int32, frameRates: [Int])] = [
    (640, 480, [30]),
    (1280, 720, [30, 60]),
    (1920, 1080, [30, 60]),
    (3840, 2160, [30, 60]),
  ]

  /// Returns the capabilities of the camera named `cameraName`.
  ///
  /// - Parameter activeWriterCodecs: the asset writer codecs reported by the video output of an
  ///   active camera using the same device, if any. When nil, a temporary, never started capture
  ///   session is used to ask a video output connected to the device.
  static func capabilities(
    cameraName: String,
    activeWriterCodecs: [AVVideoCodecType]? = nil
  ) throws -> [String: Any] {
    guard let device = AVCaptureDevice(uniqueID: cameraName) else {
      throw qualityError("Camera '\(cameraName)' is unavailable.")
    }

    let writerCodecs = activeWriterCodecs ?? probeWriterVideoCodecs(for: device)
    return capabilities(
      device: device,
      codecs: availableCodecs(
        writerCodecs: writerCodecs, encoderAvailable: isEncoderAvailable),
      videoDimensionsConverter: { CMVideoFormatDescriptionGetDimensions($0.formatDescription) },
      supportsEncoding: supportsEncoding)
  }

  /// Builds the capability map from the device formats. Kept free of AVFoundation singletons
  /// so it can run against fake devices in tests.
  static func capabilities(
    device: CaptureDevice,
    codecs: [VideoCodec],
    videoDimensionsConverter: VideoDimensionsConverter,
    supportsEncoding: (_ width: Int32, _ height: Int32, _ fps: Int, _ codec: VideoCodec) -> Bool
  ) -> [String: Any] {
    var deviceProfiles = Set<Profile>()
    for format in device.flutterFormats
    where FormatUtils.isSelectable(format, videoDimensionsConverter: videoDimensionsConverter) {
      let dimensions = videoDimensionsConverter(format)
      for requested in requestedProfiles
      where dimensions.width == requested.width && dimensions.height == requested.height
      {
        for fps in requested.frameRates
        where FormatUtils.supports(frameRate: Double(fps), on: format) {
          deviceProfiles.insert(
            Profile(
              width: dimensions.width,
              height: dimensions.height,
              framesPerSecond: fps))
        }
      }
    }

    let supportedProfiles = deviceProfiles.compactMap { profile -> SupportedProfile? in
      let supportedCodecs = codecs.filter {
        supportsEncoding(profile.width, profile.height, profile.framesPerSecond, $0)
      }
      return supportedCodecs.isEmpty
        ? nil : SupportedProfile(profile: profile, codecs: supportedCodecs)
    }.sorted {
      if $0.profile.width != $1.profile.width {
        return $0.profile.width < $1.profile.width
      }
      if $0.profile.height != $1.profile.height {
        return $0.profile.height < $1.profile.height
      }
      return $0.profile.framesPerSecond < $1.profile.framesPerSecond
    }

    return [
      "profiles": supportedProfiles.map { supported in
        return [
          "width": Int(supported.profile.width),
          "height": Int(supported.profile.height),
          "fps": supported.profile.framesPerSecond,
          "codecs": supported.codecs.map(\.rawValue),
        ]
      },
      "supportsFocusLock": device.isFocusModeSupported(.locked),
      "supportsExposureLock": device.isExposureModeSupported(.locked),
    ]
  }

  /// Returns the codecs that may be advertised.
  ///
  /// When the capture output reported its asset writer codecs, only those are used: asking
  /// the output for recommended settings of any other codec raises `NSInvalidArgumentException`.
  /// When the list is unknown (for example before camera permission was granted), H.264 is kept
  /// and HEVC requires a hardware/software encoder that VideoToolbox reports; the recording path
  /// validates the codec against the real output again before writing.
  static func availableCodecs(
    writerCodecs: [AVVideoCodecType]?,
    encoderAvailable: (VideoCodec) -> Bool
  ) -> [VideoCodec] {
    if let writerCodecs, !writerCodecs.isEmpty {
      return VideoCodec.allCases.filter { writerCodecs.contains($0.avVideoCodecType) }
    }
    return VideoCodec.allCases.filter { $0 == .h264 || encoderAvailable($0) }
  }

  /// Asks a video data output connected to `device` which codecs it can feed to an
  /// `AVAssetWriter` writing MP4. The session is never started, and `.inputPriority` keeps it
  /// from changing the device's active format. Returns nil when the answer is unavailable.
  private static func probeWriterVideoCodecs(for device: AVCaptureDevice) -> [AVVideoCodecType]? {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
      let input = try? AVCaptureDeviceInput(device: device)
    else {
      return nil
    }
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    session.beginConfiguration()
    session.sessionPreset = .inputPriority
    guard session.canAddInput(input), session.canAddOutput(output) else {
      session.commitConfiguration()
      return nil
    }
    session.addInput(input)
    session.addOutput(output)
    session.commitConfiguration()
    defer {
      session.beginConfiguration()
      session.removeOutput(output)
      session.removeInput(input)
      session.commitConfiguration()
    }
    let codecs = output.availableVideoCodecTypesForAssetWriter(writingTo: .mp4)
    return codecs.isEmpty ? nil : codecs
  }

  /// Whether VideoToolbox has an encoder for `codec`.
  private static func isEncoderAvailable(_ codec: VideoCodec) -> Bool {
    let codecType: CMVideoCodecType
    switch codec {
    case .h264: codecType = kCMVideoCodecType_H264
    case .hevc: codecType = kCMVideoCodecType_HEVC
    }
    var encoderID: CFString?
    var properties: CFDictionary?
    let status = VTCopySupportedPropertyDictionaryForEncoder(
      width: 1920,
      height: 1080,
      codecType: codecType,
      encoderSpecification: nil,
      encoderIDOut: &encoderID,
      supportedPropertiesOut: &properties)
    return status == noErr
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

  static func supportsEncoding(
    width: Int32,
    height: Int32,
    fps: Int,
    codec: VideoCodec
  ) -> Bool {
    let settings: [String: Any] = [
      AVVideoCodecKey: codec.avVideoCodecType,
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
    defer { try? FileManager.default.removeItem(at: outputURL) }
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
