// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreMotion
import Flutter

final class DefaultCamera: NSObject, Camera {
  var dartAPI: CameraEventApi?
  var onFrameAvailable: (() -> Void)?

  var videoFormat: FourCharCode = kCVPixelFormatType_32BGRA {
    didSet {
      captureVideoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: videoFormat
      ]
    }
  }

  private(set) var isPreviewPaused = false

  var minimumExposureOffset: CGFloat { CGFloat(captureDevice.minExposureTargetBias) }
  var maximumExposureOffset: CGFloat { CGFloat(captureDevice.maxExposureTargetBias) }
  var minimumAvailableZoomFactor: CGFloat { captureDevice.minAvailableVideoZoomFactor }
  var maximumAvailableZoomFactor: CGFloat { captureDevice.maxAvailableVideoZoomFactor }

  /// The queue on which `latestPixelBuffer` property is accessed.
  /// To avoid unnecessary contention, do not access `latestPixelBuffer` on the `captureSessionQueue`.
  private let pixelBufferSynchronizationQueue = DispatchQueue(
    label: "io.flutter.camera.pixelBufferSynchronizationQueue")

  /// The queue on which captured photos (not videos) are written to disk.
  /// Videos are written to disk by `videoAdaptor` on an internal queue managed by AVFoundation.
  private let photoIOQueue = DispatchQueue(label: "io.flutter.camera.photoIOQueue")

  /// All DefaultCamera's state access and capture session related operations should be run on this queue.
  private let captureSessionQueue: DispatchQueue

  private let mediaSettings: PlatformMediaSettings
  private let recordingVideoCodec: RecordingQuality.VideoCodec
  private var framesPerSecond: Double?
  private let mediaSettingsAVWrapper: FLTCamMediaSettingsAVWrapper

  let videoCaptureSession: CaptureSession
  let audioCaptureSession: CaptureSession

  /// A wrapper for AVCaptureDevice creation to allow for dependency injection in tests.
  private let videoCaptureDeviceFactory: VideoCaptureDeviceFactory
  private let audioCaptureDeviceFactory: AudioCaptureDeviceFactory
  private let captureDeviceInputFactory: CaptureDeviceInputFactory
  private let assetWriterFactory: AssetWriterFactory
  private let inputPixelBufferAdaptorFactory: InputPixelBufferAdaptorFactory

  /// A wrapper for CMVideoFormatDescriptionGetDimensions.
  /// Allows for alternate implementations in tests.
  private let videoDimensionsConverter: VideoDimensionsConverter

  private let deviceOrientationProvider: DeviceOrientationProvider
  private let motionManager = CMMotionManager()

  private(set) var captureDevice: CaptureDevice
  // Setter exposed for tests.
  var captureVideoOutput: CaptureVideoDataOutput
  // Setter exposed for tests.
  var capturePhotoOutput: CapturePhotoOutput
  private var captureVideoInput: CaptureInput

  private var videoWriter: AssetWriter?
  private var videoWriterInput: AssetWriterInput?
  /// The video settings the current (or last) asset writer input was created with.
  private var writerVideoSettings: [String: Any]?
  private var audioWriterInput: AssetWriterInput?
  private var assetWriterPixelBufferAdaptor: AssetWriterInputPixelBufferAdaptor?
  private var videoAdaptor: AssetWriterInputPixelBufferAdaptor?

  /// A dictionary to retain all in-progress SavePhotoDelegates. The key of the dictionary is the
  /// AVCapturePhotoSettings's uniqueID for each photo capture operation, and the value is the
  /// SavePhotoDelegate that handles the result of each photo capture operation. Note that photo
  /// capture operations may overlap, so FLTCam has to keep track of multiple delegates in progress,
  /// instead of just a single delegate reference.
  private(set) var inProgressSavePhotoDelegates = [Int64: SavePhotoDelegate]()

  private var imageStreamHandler: ImageStreamHandler?

  private var previewSize: CGSize?
  var deviceOrientation: UIDeviceOrientation {
    didSet {
      if deviceOrientation.isValidInterfaceOrientation {
        lastValidOrientation = deviceOrientation
      }
      guard deviceOrientation != oldValue else { return }
      updateOrientation()
    }
  }
  /// The last interface-valid orientation seen, used when the device lies flat.
  private var lastValidOrientation: UIDeviceOrientation

  /// Tracks the latest pixel buffer sent from AVFoundation's sample buffer delegate callback.
  /// Used to deliver the latest pixel buffer to the flutter engine via the `copyPixelBuffer` API.
  private var latestPixelBuffer: CVPixelBuffer?

  private var videoRecordingPath: String?
  private(set) var isRecording = false
  /// True while `finishWriting` runs for the last recording. Accessed on `captureSessionQueue`.
  private var isFinishingWriting = false
  /// Receivers of the outcome of the writer that is finishing. Accessed on `captureSessionQueue`.
  private var finishWritingWaiters: [(Result<String, any Error>) -> Void] = []
  /// Outcome of a recording finalized because the app went to the background, kept until the
  /// next `stopVideoRecording`. Accessed on `captureSessionQueue`.
  private var backgroundFinalizedRecording: Result<String, any Error>?
  /// Keeps the app alive while a recording is finalized in the background.
  private let backgroundTask = RecordingBackgroundTask()
  private var isRecordingPaused = false
  private var isFirstVideoSample = false
  private var isAudioSetup = false
  /// Time of the end of the last sample.
  private var lastSampleEndTime = CMTime.invalid
  /// Whether the recording is disconnected.
  private var isRecordingDisconnected = false
  /// Represents sum of all pauses/interruptions during recording.
  private var recordingTimeOffset = CMTime.invalid
  /// Output to use for adjusting of recording time offset.
  private var outputForOffsetAdjusting: AVCaptureOutput?
  /// Time of the last appended video sample.
  private var lastAppendedVideoSampleTime = CMTime.invalid

  /// True when images from the camera are being streamed.
  private(set) var isStreamingImages = false

  /// Number of frames currently pending processing.
  private var streamingPendingFramesCount = 0

  /// Maximum number of frames pending processing.
  /// To limit memory consumption, limit the number of frames pending processing.
  /// After some testing, 4 was determined to be the best maximum value.
  /// https://github.com/flutter/plugins/pull/4520#discussion_r766335637
  private var maxStreamingPendingFramesCount = 4

  private var fileFormat = PlatformImageFileFormat.jpeg
  private var imageQuality: Int64 = 100
  private var lockedCaptureOrientation = UIDeviceOrientation.unknown
  private var exposureMode = PlatformExposureMode.auto
  private var focusMode = PlatformFocusMode.auto
  private var flashMode: PlatformFlashMode
  /// When a focus/exposure point or mode change last restarted metering.
  /// AVFoundation raises `isAdjustingFocus`/`isAdjustingExposure` asynchronously
  /// after such a change, so an idle reading right after it is not convergence.
  /// Accessed only on `captureSessionQueue`.
  private var lastMeteringChange: DispatchTime?
  /// Upper bound for waiting until `activeVideoStabilizationMode` reflects a new preference.
  private static let stabilizationReadbackTimeout = DispatchTimeInterval.seconds(1)

  static let cameraErrorDomain = "dev.teleprompter.camera"
  static let cameraNotFoundErrorCode = 1

  static func cameraNotFoundError(_ cameraName: String) -> NSError {
    return NSError(
      domain: cameraErrorDomain,
      code: cameraNotFoundErrorCode,
      userInfo: [NSLocalizedDescriptionKey: "Camera '\(cameraName)' is unavailable."])
  }

  private static func pigeonErrorFromNSError(_ error: NSError) -> PigeonError {
    return PigeonError(
      code: "Error \(error.code)",
      message: error.localizedDescription,
      details: error.domain)
  }

  private static func createConnection(
    captureDevice: CaptureDevice,
    videoFormat: FourCharCode,
    captureDeviceInputFactory: CaptureDeviceInputFactory
  ) throws -> (CaptureInput, CaptureVideoDataOutput, AVCaptureConnection) {
    // Setup video capture input.
    let captureVideoInput = try captureDeviceInputFactory.deviceInput(with: captureDevice)

    // Setup video capture output.
    let captureVideoOutput = AVCaptureVideoDataOutput()
    captureVideoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: videoFormat
    ]
    captureVideoOutput.alwaysDiscardsLateVideoFrames = true

    let connection = makeVideoConnection(
      input: captureVideoInput,
      output: captureVideoOutput,
      position: captureDevice.position)

    return (captureVideoInput, captureVideoOutput, connection)
  }

  /// Creates the video connection between `input` and `output`.
  ///
  /// Front camera frames are mirrored, like the system camera preview. The mirroring applies to
  /// the connection feeding both the preview and the `AVAssetWriter`, so front camera recordings
  /// are mirrored in the file as well (see the package README).
  private static func makeVideoConnection(
    input: CaptureInput,
    output: CaptureVideoDataOutput,
    position: AVCaptureDevice.Position
  ) -> AVCaptureConnection {
    let connection = AVCaptureConnection(inputPorts: input.ports, output: output.avOutput)
    if position == .front {
      connection.isVideoMirrored = true
    }
    return connection
  }

  init(configuration: CameraConfiguration) throws {
    captureSessionQueue = configuration.captureSessionQueue
    mediaSettings = configuration.mediaSettings
    recordingVideoCodec = configuration.recordingVideoCodec
    mediaSettingsAVWrapper = configuration.mediaSettingsWrapper
    videoCaptureSession = configuration.videoCaptureSession
    audioCaptureSession = configuration.audioCaptureSession
    videoCaptureDeviceFactory = configuration.videoCaptureDeviceFactory
    audioCaptureDeviceFactory = configuration.audioCaptureDeviceFactory
    captureDeviceInputFactory = configuration.captureDeviceInputFactory
    assetWriterFactory = configuration.assetWriterFactory
    inputPixelBufferAdaptorFactory = configuration.inputPixelBufferAdaptorFactory
    videoDimensionsConverter = configuration.videoDimensionsConverter
    deviceOrientationProvider = configuration.deviceOrientationProvider

    guard let initialDevice = videoCaptureDeviceFactory(configuration.initialCameraName) else {
      throw DefaultCamera.cameraNotFoundError(configuration.initialCameraName)
    }
    captureDevice = initialDevice
    flashMode = captureDevice.hasFlash ? .auto : .off

    capturePhotoOutput = AVCapturePhotoOutput()
    capturePhotoOutput.isHighResolutionCaptureEnabled = true

    videoCaptureSession.automaticallyConfiguresApplicationAudioSession = false
    audioCaptureSession.automaticallyConfiguresApplicationAudioSession = false

    lastValidOrientation =
      configuration.orientation.isValidInterfaceOrientation
      ? configuration.orientation : configuration.fallbackOrientation
    deviceOrientation = configuration.orientation

    let connection: AVCaptureConnection
    (captureVideoInput, captureVideoOutput, connection) = try DefaultCamera.createConnection(
      captureDevice: captureDevice,
      videoFormat: videoFormat,
      captureDeviceInputFactory: configuration.captureDeviceInputFactory)

    super.init()

    captureVideoOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)

    videoCaptureSession.addInputWithNoConnections(captureVideoInput)
    videoCaptureSession.addOutputWithNoConnections(captureVideoOutput.avOutput)
    videoCaptureSession.addConnection(connection)

    videoCaptureSession.addOutput(capturePhotoOutput.avOutput)

    motionManager.startAccelerometerUpdates()

    if let requestedFrameRate = configuration.mediaSettings.framesPerSecond {
      // The frame rate can be changed only on a locked for configuration device.
      try mediaSettingsAVWrapper.lockDevice(captureDevice)
      defer { mediaSettingsAVWrapper.unlockDevice(captureDevice) }

      mediaSettingsAVWrapper.beginConfiguration(for: videoCaptureSession)
      defer { mediaSettingsAVWrapper.commitConfiguration(for: videoCaptureSession) }

      let targetResolution = try exactRecordingResolution(for: mediaSettings.resolutionPreset)
      try setCaptureSessionPreset(mediaSettings.resolutionPreset, requiresExactResolution: true)

      let requestedFramesPerSecond = Double(requestedFrameRate)
      guard let exactFormat = FormatUtils.findExactFormat(
        for: captureDevice,
        targetResolution: targetResolution,
        targetFrameRate: requestedFramesPerSecond,
        videoDimensionsConverter: videoDimensionsConverter)
      else {
        throw recordingProfileError(
          width: targetResolution.width,
          height: targetResolution.height,
          framesPerSecond: requestedFrameRate)
      }

      captureDevice.flutterActiveFormat = exactFormat
      // `setCaptureSessionPreset` derived the preview size from the previous active format: the
      // preset change is deferred until commit. Use the format that is actually applied.
      let exactDimensions = videoDimensionsConverter(exactFormat)
      previewSize = CGSize(
        width: CGFloat(exactDimensions.width), height: CGFloat(exactDimensions.height))
      framesPerSecond = requestedFramesPerSecond
      let duration = CMTimeMakeWithSeconds(1.0 / requestedFramesPerSecond, preferredTimescale: 60_000)
      mediaSettingsAVWrapper.setMinFrameDuration(duration, on: captureDevice)
      mediaSettingsAVWrapper.setMaxFrameDuration(duration, on: captureDevice)
    } else {
      // If the frame rate is not important fall to a less restrictive
      // behavior (no configuration locking).
      try setCaptureSessionPreset(mediaSettings.resolutionPreset)
    }

    try validateRecordingCodec()

    updateOrientation()

    // Handle video and audio interruptions and errors. Interruption can happen for example by
    // an incoming call during video recording. Error can happen for example when recording starts
    // during an incoming call.
    // https://github.com/flutter/flutter/issues/151253
    for session in [videoCaptureSession, audioCaptureSession] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(captureSessionWasInterrupted),
        name: AVCaptureSession.wasInterruptedNotification,
        object: session)

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(captureSessionRuntimeError),
        name: AVCaptureSession.runtimeErrorNotification,
        object: session)
    }

    // A writer that is still writing when the app is suspended fails, so a background task is
    // held from `willResignActive` and a running recording is finalized once the app is in the
    // background. https://github.com/imariman/camera-recording-kit/issues/30
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil)
  }

  @objc private func captureSessionWasInterrupted(notification: NSNotification) {
    let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)
      .flatMap { AVCaptureSession.InterruptionReason(rawValue: $0.intValue) }
    let isBackgroundInterruption = reason == .videoDeviceNotAvailableInBackground
    if isBackgroundInterruption {
      backgroundTask.begin()
    }
    // Notifications arrive on an arbitrary thread; recording state lives on the session queue.
    captureSessionQueue.async { [weak self] in
      guard let self else { return }
      self.isRecordingDisconnected = true
      if isBackgroundInterruption {
        self.finalizeRecordingForBackground()
      }
    }
  }

  @objc private func applicationWillResignActive(notification: NSNotification) {
    // Begin on the main thread right away; it is dropped again when nothing is recording.
    backgroundTask.begin()
    captureSessionQueue.async { [weak self] in
      self?.endBackgroundTaskIfIdle()
    }
  }

  @objc private func applicationDidEnterBackground(notification: NSNotification) {
    captureSessionQueue.async { [weak self] in
      self?.finalizeRecordingForBackground()
    }
  }

  @objc private func applicationDidBecomeActive(notification: NSNotification) {
    captureSessionQueue.async { [weak self] in
      guard let self, !self.isFinishingWriting else { return }
      self.backgroundTask.end()
    }
  }

  /// Ends the background task unless a recording is running or finishing.
  /// Must be called on `captureSessionQueue`.
  private func endBackgroundTaskIfIdle() {
    if !isRecording && !isFinishingWriting {
      backgroundTask.end()
    }
  }

  /// Finalizes a running recording because the app is (going) in the background, where the writer
  /// would otherwise fail. The outcome goes to a pending or the next `stopVideoRecording`.
  /// Must be called on `captureSessionQueue`.
  private func finalizeRecordingForBackground() {
    guard isRecording else {
      endBackgroundTaskIfIdle()
      return
    }
    finishWriting(completion: nil)
  }

  @objc private func captureSessionRuntimeError(notification: NSNotification) {
    reportErrorMessage(
      "\(String(describing: notification.userInfo?[AVCaptureSessionErrorKey] as? Error))")
  }

  // Possible values for presets are hard-coded in FLT interface having
  // corresponding AVCaptureSessionPreset counterparts.
  // If _resolutionPreset is not supported by camera there is
  // fallback to lower resolution presets.
  // If none can be selected there is error condition.
  private func setCaptureSessionPreset(
    _ resolutionPreset: PlatformResolutionPreset,
    requiresExactResolution: Bool = false
  ) throws {
    switch resolutionPreset {
    case .max:
      if let bestFormat = highestResolutionFormat(forCaptureDevice: captureDevice) {
        videoCaptureSession.sessionPreset = .inputPriority
        // A lock failure propagates to the caller; the format is only written while locked.
        try captureDevice.lockForConfiguration()
        defer { captureDevice.unlockForConfiguration() }
        // Set the best device format found and finish the device configuration.
        captureDevice.flutterActiveFormat = bestFormat
        break
      }
      fallthrough
    case .ultraHigh:
      if videoCaptureSession.canSetSessionPreset(.hd4K3840x2160) {
        videoCaptureSession.sessionPreset = .hd4K3840x2160
        break
      }
      if requiresExactResolution { throw unsupportedPresetError(resolutionPreset) }
      if videoCaptureSession.canSetSessionPreset(.high) {
        videoCaptureSession.sessionPreset = .high
        break
      }
      fallthrough
    case .veryHigh:
      if videoCaptureSession.canSetSessionPreset(.hd1920x1080) {
        videoCaptureSession.sessionPreset = .hd1920x1080
        break
      }
      if requiresExactResolution { throw unsupportedPresetError(resolutionPreset) }
      fallthrough
    case .high:
      if videoCaptureSession.canSetSessionPreset(.hd1280x720) {
        videoCaptureSession.sessionPreset = .hd1280x720
        break
      }
      if requiresExactResolution { throw unsupportedPresetError(resolutionPreset) }
      fallthrough
    case .medium:
      if videoCaptureSession.canSetSessionPreset(.vga640x480) {
        videoCaptureSession.sessionPreset = .vga640x480
        break
      }
      if requiresExactResolution { throw unsupportedPresetError(resolutionPreset) }
      fallthrough
    case .low:
      if videoCaptureSession.canSetSessionPreset(.cif352x288) {
        videoCaptureSession.sessionPreset = .cif352x288
        break
      }
      fallthrough
    default:
      if videoCaptureSession.canSetSessionPreset(.low) {
        videoCaptureSession.sessionPreset = .low
      } else {
        throw NSError(
          domain: NSCocoaErrorDomain,
          code: URLError.unknown.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey: "No capture session available for current capture session."
          ])
      }
    }

    let size = videoDimensionsConverter(captureDevice.flutterActiveFormat)
    previewSize = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    audioCaptureSession.sessionPreset = videoCaptureSession.sessionPreset
  }

  /// Fails camera creation with `unsupportedRecordingProfile` when the video output reports its
  /// asset writer codecs and the requested one is not among them. An empty list means the output
  /// cannot tell yet; `setupWriter` checks again once the session runs.
  private func validateRecordingCodec() throws {
    let available = captureVideoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mp4)
    guard available.isEmpty || available.contains(recordingVideoCodec.avVideoCodecType) else {
      throw unsupportedCodecError()
    }
  }

  private func unsupportedCodecError() -> NSError {
    return NSError(
      domain: "dev.teleprompter.recording_quality",
      code: 5,
      userInfo: [
        NSLocalizedDescriptionKey:
          "The \(recordingVideoCodec.rawValue) video codec is unavailable for recording on this camera."
      ])
  }

  private func exactRecordingResolution(
    for preset: PlatformResolutionPreset
  ) throws -> CMVideoDimensions {
    switch preset {
    case .medium: return CMVideoDimensions(width: 640, height: 480)
    case .high: return CMVideoDimensions(width: 1280, height: 720)
    case .veryHigh: return CMVideoDimensions(width: 1920, height: 1080)
    case .ultraHigh: return CMVideoDimensions(width: 3840, height: 2160)
    case .low, .max:
      throw NSError(
        domain: "dev.teleprompter.recording_quality",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "An explicit recording frame rate requires SD, HD, FHD, or UHD resolution."
        ])
    }
  }

  private func unsupportedPresetError(_ preset: PlatformResolutionPreset) -> NSError {
    return NSError(
      domain: "dev.teleprompter.recording_quality",
      code: 3,
      userInfo: [
        NSLocalizedDescriptionKey:
          "The requested \(preset) recording resolution is unsupported by this camera."
      ])
  }

  private func recordingProfileError(
    width: Int32,
    height: Int32,
    framesPerSecond: Int64
  ) -> NSError {
    return NSError(
      domain: "dev.teleprompter.recording_quality",
      code: 4,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Requested recording profile \(width)x\(height) at \(framesPerSecond) fps is unsupported by this camera."
      ])
  }

  /// Finds the highest available non-square resolution in terms of pixel count for the given device.
  /// Preferred are formats with the same subtype as current activeFormat.
  private func highestResolutionFormat(forCaptureDevice captureDevice: CaptureDevice)
    -> CaptureDeviceFormat?
  {
    let preferredSubType = CMFormatDescriptionGetMediaSubType(
      captureDevice.flutterActiveFormat.formatDescription)
    var bestFormat: CaptureDeviceFormat? = nil
    var maxPixelCount: UInt = 0
    var isBestSubTypePreferred = false

    for format in captureDevice.flutterFormats {
      // Skip formats that crash the Flutter engine (btp2) and 1:1 centre stage formats.
      guard FormatUtils.isSelectable(format, videoDimensionsConverter: videoDimensionsConverter)
      else {
        continue
      }

      let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      let resolution = videoDimensionsConverter(format)
      let height = UInt(resolution.height)
      let width = UInt(resolution.width)

      let pixelCount = height * width
      let isSubTypePreferred = subType == preferredSubType

      if pixelCount > maxPixelCount
        || (pixelCount == maxPixelCount && isSubTypePreferred && !isBestSubTypePreferred)
      {
        bestFormat = format
        maxPixelCount = pixelCount
        isBestSubTypePreferred = isSubTypePreferred
      }
    }
    return bestFormat
  }

  func setUpCaptureSessionForAudioIfNeeded() {
    // Don't setup audio twice or we will lose the audio.
    guard mediaSettings.enableAudio && !isAudioSetup else { return }

    guard let audioDevice = audioCaptureDeviceFactory() else {
      reportErrorMessage("No audio capture device is available")
      return
    }
    do {
      // Create a device input with the device and add it to the session.
      // Setup the audio input.
      let audioInput = try captureDeviceInputFactory.deviceInput(with: audioDevice)

      // Setup the audio output.
      let audioOutput = AVCaptureAudioDataOutput()

      let block = {
        // Set up options implicit to AVAudioSessionCategoryPlayback to avoid conflicts with other
        // plugins like video_player.
        DefaultCamera.upgradeAudioSessionCategory(
          requestedCategory: .playAndRecord,
          options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
        )
      }

      if !Thread.isMainThread {
        DispatchQueue.main.sync(execute: block)
      } else {
        block()
      }

      if audioCaptureSession.canAddInput(audioInput) {
        audioCaptureSession.addInput(audioInput)

        if audioCaptureSession.canAddOutput(audioOutput) {
          audioCaptureSession.addOutput(audioOutput)
          audioOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)
          isAudioSetup = true
        } else {
          reportErrorMessage("Unable to add Audio input/output to session capture")
          isAudioSetup = false
        }
      }
    } catch let error as NSError {
      reportErrorMessage(error.description)
    }
  }

  // This function, although slightly modified, is also in video_player_avfoundation (in ObjC).
  // Both need to do the same thing and run on the same thread (for example main thread).
  // Configure application wide audio session manually to prevent overwriting flag
  // MixWithOthers by capture session.
  // Only change category if it is considered an upgrade which means it can only enable
  // ability to play in silent mode or ability to record audio but never disables it,
  // that could affect other plugins which depend on this global state. Only change
  // category or options if there is change to prevent unnecessary lags and silence.
  private static func upgradeAudioSessionCategory(
    requestedCategory: AVAudioSession.Category,
    options: AVAudioSession.CategoryOptions
  ) {
    let playCategories: Set<AVAudioSession.Category> = [.playback, .playAndRecord]
    let recordCategories: Set<AVAudioSession.Category> = [.record, .playAndRecord]
    let requiredCategories: Set<AVAudioSession.Category> = [
      requestedCategory, AVAudioSession.sharedInstance().category,
    ]

    let requiresPlay = !requiredCategories.isDisjoint(with: playCategories)
    let requiresRecord = !requiredCategories.isDisjoint(with: recordCategories)

    var finalCategory = requestedCategory
    if requiresPlay && requiresRecord {
      finalCategory = .playAndRecord
    } else if requiresPlay {
      finalCategory = .playback
    } else if requiresRecord {
      finalCategory = .record
    }

    let finalOptions = AVAudioSession.sharedInstance().categoryOptions.union(options)

    if finalCategory == AVAudioSession.sharedInstance().category
      && finalOptions == AVAudioSession.sharedInstance().categoryOptions
    {
      return
    }

    try? AVAudioSession.sharedInstance().setCategory(finalCategory, options: finalOptions)
  }

  func reportInitializationState() {
    // Get all the state on the current thread, not the main thread.
    let state = PlatformCameraState(
      previewSize: PlatformSize(
        // previewSize is set during init, so it will never be nil.
        width: previewSize!.width,
        height: previewSize!.height
      ),
      exposureMode: exposureMode,
      focusMode: focusMode,
      exposurePointSupported: captureDevice.isExposurePointOfInterestSupported,
      focusPointSupported: captureDevice.isFocusPointOfInterestSupported
    )

    ensureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.initialized(initialState: state) { _ in
        // Ignore any errors, as this is just an event broadcast.
      }
    }
  }

  func receivedImageStreamData() {
    streamingPendingFramesCount -= 1
  }

  func start() {
    videoCaptureSession.startRunning()
    audioCaptureSession.startRunning()
  }

  func stop() {
    videoCaptureSession.stopRunning()
    audioCaptureSession.stopRunning()
  }

  func startVideoRecording(
    completion: @escaping (Result<Void, any Error>) -> Void,
    messengerForStreaming messenger: FlutterBinaryMessenger?
  ) {
    guard !isRecording else {
      completion(
        .failure(
          PigeonError(
            code: "Error",
            message: "Video is already recording",
            details: nil)))
      return
    }

    guard !isFinishingWriting else {
      completion(
        .failure(
          PigeonError(
            code: "Error",
            message: "The previous recording is still being finalized",
            details: nil)))
      return
    }

    if case .success(let path)? = backgroundFinalizedRecording {
      // The file finalized in the background was never collected; keep it on disk.
      NSLog("camera_avfoundation: recording finalized in background was not collected: %@", path)
    }
    backgroundFinalizedRecording = nil

    if let messenger = messenger {
      startImageStream(with: messenger) { [weak self] error in
        guard let self else {
          completion(
            .failure(
              PigeonError(code: "cameraNotFound", message: "Camera was closed", details: nil)))
          return
        }
        self.setUpVideoRecording(completion: completion)
      }
      return
    }

    setUpVideoRecording(completion: completion)
  }

  /// Main logic to setup the video recording.
  private func setUpVideoRecording(completion: @escaping (Result<Void, any Error>) -> Void) {
    let videoRecordingPath: String
    do {
      videoRecordingPath = try getTemporaryFilePath(
        withExtension: "mp4",
        subfolder: "videos",
        prefix: "REC_")
      self.videoRecordingPath = videoRecordingPath
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    do {
      try setupWriter(forPath: videoRecordingPath)
    } catch {
      completion(.failure(error))
      return
    }

    // startWriting should not be called in didOutputSampleBuffer where it can cause state
    // in which isRecording is true but videoWriter.status is .unknown
    // in stopVideoRecording if it is called after startVideoRecording but before
    // didOutputSampleBuffer had chance to call startWriting and lag at start of video
    // https://github.com/flutter/flutter/issues/132016
    // https://github.com/flutter/flutter/issues/151319
    guard let videoWriter = videoWriter, videoWriter.startWriting() else {
      completion(
        .failure(
          PigeonError(
            code: "IOError",
            message: "AVAssetWriter failed to start writing",
            details: videoWriter?.error?.localizedDescription)))
      return
    }
    isFirstVideoSample = true
    isRecording = true
    isRecordingPaused = false
    isRecordingDisconnected = false
    recordingTimeOffset = CMTime.zero
    outputForOffsetAdjusting = captureVideoOutput.avOutput
    lastAppendedVideoSampleTime = CMTime.negativeInfinity
    completion(.success(()))
  }

  /// Recommended writer settings for the configured codec, or nil when the video output does not
  /// offer that codec for MP4.
  private func recommendedWriterVideoSettings() -> [String: Any]? {
    return mediaSettingsAVWrapper.recommendedVideoSettingsForAssetWriter(
      withVideoCodecType: recordingVideoCodec.avVideoCodecType,
      fileType: AVFileType.mp4,
      for: captureVideoOutput)
  }

  private static let setupWriterFailed = PigeonError(
    code: "IOError",
    message: "Setup Writer Failed",
    details: nil)

  /// Creates the asset writer and its inputs. Throws a `PigeonError` describing the failure.
  private func setupWriter(forPath path: String) throws {
    setUpCaptureSessionForAudioIfNeeded()

    let videoWriter: AssetWriter

    do {
      videoWriter = try assetWriterFactory(URL(fileURLWithPath: path), .mp4)
      self.videoWriter = videoWriter
    } catch let error as NSError {
      reportErrorMessage(error.description)
      throw DefaultCamera.setupWriterFailed
    }

    // `recommendedVideoSettings` raises NSInvalidArgumentException for a codec the output does not
    // list, so the codec is validated against the output before asking for settings.
    let availableCodecs = captureVideoOutput.availableVideoCodecTypesForAssetWriter(
      writingTo: .mp4)
    guard availableCodecs.contains(recordingVideoCodec.avVideoCodecType) else {
      throw PigeonError(
        code: "unsupportedRecordingProfile",
        message: unsupportedCodecError().localizedDescription,
        details: availableCodecs.map(\.rawValue))
    }

    guard var videoSettings = recommendedWriterVideoSettings() else {
      throw DefaultCamera.setupWriterFailed
    }

    if mediaSettings.videoBitrate != nil || framesPerSecond != nil {
      var compressionProperties = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any]
        ?? [:]

      if let videoBitrate = mediaSettings.videoBitrate {
        compressionProperties[AVVideoAverageBitRateKey] = Int(videoBitrate)
      }

      if let framesPerSecond = framesPerSecond {
        compressionProperties[AVVideoExpectedSourceFrameRateKey] = framesPerSecond
      }

      videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
    }

    guard videoWriter.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      throw DefaultCamera.setupWriterFailed
    }

    let videoWriterInput = mediaSettingsAVWrapper.assetWriterVideoInput(
      withOutputSettings: videoSettings)
    self.videoWriterInput = videoWriterInput
    writerVideoSettings = videoSettings

    let sourcePixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: videoFormat
    ]

    videoAdaptor = inputPixelBufferAdaptorFactory(videoWriterInput, sourcePixelBufferAttributes)

    videoWriterInput.expectsMediaDataInRealTime = true

    // Add the audio input
    if mediaSettings.enableAudio {
      var audioChannelLayout = AudioChannelLayout()
      audioChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono

      let audioChannelLayoutData = withUnsafeBytes(of: &audioChannelLayout) { Data($0) }

      var audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 1,
        AVChannelLayoutKey: audioChannelLayoutData,
      ]

      if let audioBitrate = mediaSettings.audioBitrate {
        audioSettings[AVEncoderBitRateKey] = Int(audioBitrate)
      }

      let newAudioWriterInput = mediaSettingsAVWrapper.assetWriterAudioInput(
        withOutputSettings: audioSettings)
      newAudioWriterInput.expectsMediaDataInRealTime = true
      mediaSettingsAVWrapper.addInput(newAudioWriterInput, to: videoWriter)
      self.audioWriterInput = newAudioWriterInput
    }

    if flashMode == .torch {
      // A torch failure must not abort the recording; report it and record without the torch.
      do {
        try captureDevice.lockForConfiguration()
        defer { captureDevice.unlockForConfiguration() }
        captureDevice.torchMode = .on
      } catch {
        reportErrorMessage("Unable to turn on the torch: \(error.localizedDescription)")
      }
    }

    mediaSettingsAVWrapper.addInput(videoWriterInput, to: videoWriter)

    captureVideoOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)
  }

  func pauseVideoRecording() {
    isRecordingPaused = true
    isRecordingDisconnected = true
  }

  func resumeVideoRecording() {
    isRecordingPaused = false
  }

  func stopVideoRecording(completion: @escaping (Result<String, any Error>) -> Void) {
    if isRecording {
      finishWriting(completion: completion)
      return
    }
    if isFinishingWriting {
      // A background finalization or `close` is already finishing this recording.
      finishWritingWaiters.append(completion)
      return
    }
    if let finalized = backgroundFinalizedRecording {
      backgroundFinalizedRecording = nil
      completion(finalized)
      return
    }

    let error = NSError(
      domain: NSCocoaErrorDomain,
      code: URLError.resourceUnavailable.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "Video is not recording!"]
    )
    completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
  }

  /// Finishes the running writer exactly once.
  ///
  /// `completion` and every stop request that arrives while the writer finishes receive the
  /// outcome. Without any receiver (a background finalization) the outcome is kept for the next
  /// `stopVideoRecording`. A writer that cannot produce a playable file is cancelled and its
  /// temporary file removed, since Dart never learns its path. Must be called on
  /// `captureSessionQueue` while `isRecording` is true.
  private func finishWriting(completion: ((Result<String, any Error>) -> Void)?) {
    isRecording = false
    isFinishingWriting = true
    if let completion {
      finishWritingWaiters.append(completion)
    }

    guard let writer = videoWriter, let path = videoRecordingPath else {
      didFinishWriting(
        .failure(
          PigeonError(
            code: "IOError", message: "No video writer is recording", details: nil)))
      return
    }

    // `startWriting` succeeded before `isRecording` was set, so the status is `.writing` unless
    // the writer failed meanwhile (for example after the app was suspended). Without a started
    // session (no frame arrived yet) there is nothing to finalize either.
    guard writer.status == .writing, !isFirstVideoSample else {
      let error = writer.error
      writer.cancelWriting()
      DefaultCamera.removeFile(atPath: path)
      didFinishWriting(
        .failure(DefaultCamera.finishWritingError(writerError: error, noFrames: isFirstVideoSample)))
      return
    }

    // The camera is retained strongly until the writer finished: the waiters must always be
    // completed, even when the camera is closed meanwhile. The completion hops back to
    // `captureSessionQueue`, which owns all recording state.
    let camera = UncheckedSendableBox(self)
    writer.finishWriting {
      let result: Result<String, any Error>
      if writer.status == .completed {
        result = .success(path)
      } else {
        DefaultCamera.removeFile(atPath: path)
        result = .failure(DefaultCamera.finishWritingError(writerError: writer.error, noFrames: false))
      }
      camera.value.captureSessionQueue.async {
        camera.value.didFinishWriting(result)
      }
    }
  }

  /// Delivers the outcome of `finishWriting`. Must be called on `captureSessionQueue`.
  private func didFinishWriting(_ result: Result<String, any Error>) {
    isFinishingWriting = false
    updateOrientation()
    let waiters = finishWritingWaiters
    finishWritingWaiters = []
    if waiters.isEmpty {
      backgroundFinalizedRecording = result
    } else {
      waiters.forEach { $0(result) }
    }
    endBackgroundTaskIfIdle()
  }

  private static func finishWritingError(writerError: Error?, noFrames: Bool) -> PigeonError {
    var message = "AVAssetWriter could not finish writing!"
    if noFrames {
      message += " No video frame was recorded."
    }
    if let writerError {
      message += " \(writerError.localizedDescription)"
    }
    return PigeonError(
      code: "IOError",
      message: message,
      details: (writerError as NSError?).map { "\($0.domain) \($0.code): \($0.localizedDescription)" })
  }

  private static func removeFile(atPath path: String) {
    try? FileManager.default.removeItem(atPath: path)
  }

  func captureToFile(completion: @escaping (Result<String, any Error>) -> Void) {
    var settings = AVCapturePhotoSettings()

    if mediaSettings.resolutionPreset == .max {
      settings.isHighResolutionPhotoEnabled = true
    }

    let fileExtension: String

    let isHEVCCodecAvailable = capturePhotoOutput.availablePhotoCodecTypes.contains(
      .hevc)

    if fileFormat == .heif, isHEVCCodecAvailable {
      settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
      fileExtension = "heif"
    } else {
      fileExtension = "jpg"
      if imageQuality < 100 {
        settings = AVCapturePhotoSettings(format: [
          AVVideoCodecKey: AVVideoCodecType.jpeg,
          AVVideoCompressionPropertiesKey: [
            AVVideoQualityKey: CGFloat(imageQuality) / 100.0
          ],
        ])
        if mediaSettings.resolutionPreset == .max {
          settings.isHighResolutionPhotoEnabled = true
        }
      }
    }

    if flashMode != .torch {
      settings.flashMode = getAVCaptureFlashMode(for: flashMode)
    }

    let path: String
    do {
      path = try getTemporaryFilePath(
        withExtension: fileExtension,
        subfolder: "pictures",
        prefix: "CAP_")
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    let savePhotoDelegate = SavePhotoDelegate(
      path: path,
      ioQueue: photoIOQueue,
      completionHandler: { [weak self] path, error in
        if let strongSelf = self {
          strongSelf.captureSessionQueue.async { [weak self] in
            self?.inProgressSavePhotoDelegates.removeValue(forKey: settings.uniqueID)
          }
        }

        if let error = error {
          completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
        } else {
          assert(path != nil, "Path must not be nil if no error.")
          completion(.success(path!))
        }
      }
    )

    assert(
      DispatchQueue.getSpecific(key: captureSessionQueueSpecificKey)
        == captureSessionQueueSpecificValue,
      "save photo delegate references must be updated on the capture session queue")
    inProgressSavePhotoDelegates[settings.uniqueID] = savePhotoDelegate
    capturePhotoOutput.capturePhoto(with: settings, delegate: savePhotoDelegate)
  }

  private func getTemporaryFilePath(
    withExtension ext: String,
    subfolder: String,
    prefix: String
  ) throws -> String {
    let temporaryDirectory = FileManager.default.temporaryDirectory

    let fileDirectory = temporaryDirectory.appendingPathComponent("camera").appendingPathComponent(
      subfolder)
    let fileName = prefix + UUID().uuidString
    let file = fileDirectory.appendingPathComponent(fileName).appendingPathExtension(ext).path

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: fileDirectory.path) {
      try fileManager.createDirectory(
        at: fileDirectory,
        withIntermediateDirectories: true,
        attributes: nil)
    }

    return file
  }

  private func updateOrientation() {
    guard !isRecording else { return }

    let orientation =
      (lockedCaptureOrientation != .unknown)
      ? lockedCaptureOrientation
      : deviceOrientation

    updateOrientation(orientation, forCaptureOutput: capturePhotoOutput)
    updateOrientation(orientation, forCaptureOutput: captureVideoOutput)
  }

  private func updateOrientation(
    _ orientation: UIDeviceOrientation, forCaptureOutput captureOutput: CaptureOutput
  ) {
    if let connection = captureOutput.connection(with: .video),
      connection.isVideoOrientationSupported
    {
      connection.videoOrientation = videoOrientation(forDeviceOrientation: orientation)
    }
  }

  private func videoOrientation(forDeviceOrientation deviceOrientation: UIDeviceOrientation)
    -> AVCaptureVideoOrientation
  {
    switch deviceOrientation {
    case .portrait:
      return .portrait
    case .landscapeLeft:
      return .landscapeRight
    case .landscapeRight:
      return .landscapeLeft
    case .portraitUpsideDown:
      return .portraitUpsideDown
    default:
      return .portrait
    }
  }

  func lockCaptureOrientation(_ pigeonOrientation: PlatformDeviceOrientation) {
    let orientation = getUIDeviceOrientation(for: pigeonOrientation)
    if lockedCaptureOrientation != orientation {
      lockedCaptureOrientation = orientation
      updateOrientation()
    }
  }

  func unlockCaptureOrientation() {
    lockedCaptureOrientation = .unknown
    updateOrientation()
  }

  func setImageFileFormat(_ fileFormat: PlatformImageFileFormat) {
    self.fileFormat = fileFormat
  }

  func setJpegImageQuality(_ quality: Int64) {
    self.imageQuality = quality
  }

  func setExposureMode(
    _ mode: PlatformExposureMode,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    do {
      try captureDevice.lockForConfiguration()
    } catch {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
      return
    }
    defer { captureDevice.unlockForConfiguration() }

    exposureMode = mode
    writeExposureMode()
    completion(.success(()))
  }

  /// Writes `exposureMode` to the device and restarts metering.
  ///
  /// The caller must hold the device configuration lock.
  private func writeExposureMode() {
    switch exposureMode {
    case .locked:
      // AVCaptureExposureMode.autoExpose automatically adjusts the exposure one time, and then locks exposure for the device
      if captureDevice.isExposureModeSupported(.autoExpose) {
        captureDevice.exposureMode = .autoExpose
      }
    case .auto:
      if captureDevice.isExposureModeSupported(.continuousAutoExposure) {
        captureDevice.exposureMode = .continuousAutoExposure
      } else if captureDevice.isExposureModeSupported(.autoExpose) {
        captureDevice.exposureMode = .autoExpose
      }
    @unknown default:
      assertionFailure("Unknown exposure mode")
    }
    lastMeteringChange = DispatchTime.now()
  }

  func setExposureOffset(
    _ offset: Double,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    do {
      try captureDevice.lockForConfiguration()
    } catch {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
      return
    }
    defer { captureDevice.unlockForConfiguration() }

    captureDevice.setExposureTargetBias(Float(offset), completionHandler: nil)
    completion(.success(()))
  }

  func setExposurePoint(
    _ point: PlatformPoint?, withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    guard captureDevice.isExposurePointOfInterestSupported else {
      completion(
        .failure(
          PigeonError(
            code: "setExposurePointFailed",
            message: "Device does not have exposure point capabilities",
            details: nil)))
      return
    }

    let orientation = pointOfInterestOrientation()
    do {
      try captureDevice.lockForConfiguration()
    } catch {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
      return
    }
    defer { captureDevice.unlockForConfiguration() }

    // A nil point resets to the center.
    let exposurePoint = cgPoint(
      for: point ?? PlatformPoint(x: 0.5, y: 0.5), withOrientation: orientation)
    captureDevice.exposurePointOfInterest = exposurePoint
    // Retrigger auto exposure
    writeExposureMode()
    completion(.success(()))
  }

  func setFocusMode(
    _ mode: PlatformFocusMode,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    do {
      try captureDevice.lockForConfiguration()
    } catch {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
      return
    }
    defer { captureDevice.unlockForConfiguration() }

    focusMode = mode
    writeFocusMode()
    completion(.success(()))
  }

  func setFocusPoint(
    _ point: PlatformPoint?, completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    guard captureDevice.isFocusPointOfInterestSupported else {
      completion(
        .failure(
          PigeonError(
            code: "setFocusPointFailed",
            message: "Device does not have focus point capabilities",
            details: nil)))
      return
    }

    let orientation = pointOfInterestOrientation()
    do {
      try captureDevice.lockForConfiguration()
    } catch {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
      return
    }
    defer { captureDevice.unlockForConfiguration() }

    // A nil point resets to the center.
    captureDevice.focusPointOfInterest =
      cgPoint(
        for: point ?? PlatformPoint(x: 0.5, y: 0.5),
        withOrientation: orientation)
    // Retrigger auto focus
    writeFocusMode()
    completion(.success(()))
  }

  /// Writes `focusMode` to the device and restarts metering.
  ///
  /// The caller must hold the device configuration lock.
  private func writeFocusMode() {
    switch focusMode {
    case .locked:
      // AVCaptureFocusMode.autoFocus automatically adjusts the focus one time, and then locks focus
      if captureDevice.isFocusModeSupported(.autoFocus) {
        captureDevice.focusMode = .autoFocus
      }
    case .auto:
      if captureDevice.isFocusModeSupported(.continuousAutoFocus) {
        captureDevice.focusMode = .continuousAutoFocus
      } else if captureDevice.isFocusModeSupported(.autoFocus) {
        captureDevice.focusMode = .autoFocus
      }
    @unknown default:
      assertionFailure("Unknown focus mode")
    }
    lastMeteringChange = DispatchTime.now()
  }

  /// The orientation the Dart preview is shown in, see
  /// `CaptureMetering.pointOfInterestOrientation`.
  private func pointOfInterestOrientation() -> UIDeviceOrientation {
    return CaptureMetering.pointOfInterestOrientation(
      locked: lockedCaptureOrientation,
      stored: deviceOrientation,
      provided: deviceOrientationProvider.orientation,
      fallback: lastValidOrientation)
  }

  private func cgPoint(
    for point: PlatformPoint, withOrientation orientation: UIDeviceOrientation
  ) -> CGPoint {
    return CaptureMetering.pointOfInterest(x: point.x, y: point.y, orientation: orientation)
  }

  func setZoomLevel(
    _ zoom: CGFloat, withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    if zoom < captureDevice.minAvailableVideoZoomFactor
      || zoom > captureDevice.maxAvailableVideoZoomFactor
    {
      completion(
        .failure(
          PigeonError(
            code: "ZOOM_ERROR",
            message:
              "Zoom level out of bounds (zoom level should be between \(captureDevice.minAvailableVideoZoomFactor) and \(captureDevice.maxAvailableVideoZoomFactor).",
            details: nil)))
      return
    }

    do {
      try captureDevice.lockForConfiguration()
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }
    defer { captureDevice.unlockForConfiguration() }

    captureDevice.videoZoomFactor = zoom
    completion(.success(()))
  }

  func setVideoStabilizationMode(
    _ mode: PlatformVideoStabilizationMode,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    let stabilizationMode = getAvCaptureVideoStabilizationMode(mode)

    guard captureDevice.isVideoStabilizationModeSupported(stabilizationMode) else {
      completion(
        .failure(
          PigeonError(
            code: "VIDEO_STABILIZATION_ERROR",
            message: "Unavailable video stabilization mode.",
            details: [
              "requested_mode": stabilizationMode.rawValue
            ]
          ))
      )
      return
    }
    guard let connection = captureVideoOutput.connection(with: .video) else {
      completion(.success(()))
      return
    }
    connection.preferredVideoStabilizationMode = stabilizationMode

    // `activeVideoStabilizationMode` follows the preference asynchronously, and callers read it
    // back through `recordingQualityApplied` right after this completes. Complete once it
    // reflects the preference, or after a bounded wait (it can legitimately stay `.off`).
    guard videoCaptureSession.isRunning else {
      completion(.success(()))
      return
    }
    waitForStabilizationReadback(
      connection: connection,
      preferred: stabilizationMode,
      deadline: .now() + DefaultCamera.stabilizationReadbackTimeout,
      completion: completion)
  }

  private func waitForStabilizationReadback(
    connection: CaptureConnection,
    preferred: AVCaptureVideoStabilizationMode,
    deadline: DispatchTime,
    completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    if CaptureMetering.isStabilizationSettled(
      preferred: preferred, active: connection.activeVideoStabilizationMode)
      || DispatchTime.now() >= deadline
    {
      completion(.success(()))
      return
    }
    captureSessionQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      guard let self else {
        completion(.success(()))
        return
      }
      self.waitForStabilizationReadback(
        connection: connection, preferred: preferred, deadline: deadline, completion: completion)
    }
  }

  func isVideoStabilizationModeSupported(_ mode: PlatformVideoStabilizationMode) -> Bool {
    let stabilizationMode = getAvCaptureVideoStabilizationMode(mode)
    return captureDevice.isVideoStabilizationModeSupported(stabilizationMode)
  }

  func recordingQualityApplied() -> [String: Any] {
    let dimensions = videoDimensionsConverter(captureDevice.flutterActiveFormat)
    var result: [String: Any] = [
      "width": Int(dimensions.width),
      "height": Int(dimensions.height),
      "codec": appliedCodecName(),
    ]

    let duration = captureDevice.activeVideoMinFrameDuration
    let seconds = CMTimeGetSeconds(duration)
    if seconds.isFinite && seconds > 0 {
      result["fps"] = 1.0 / seconds
    }

    if let connection = captureVideoOutput.connection(with: .video) {
      result["stabilizationEnabled"] = connection.activeVideoStabilizationMode != .off
    }
    return result
  }

  /// The codec the writer uses (or would use), not the request.
  ///
  /// It comes from the current writer settings or the output's recommended settings. When the
  /// output cannot list its codecs yet, the configured codec is reported; `setupWriter` validates
  /// it again before writing. "unknown" (the output lists codecs without the configured one) makes
  /// the shared layer reject the profile instead of assuming H.264.
  private func appliedCodecName() -> String {
    if let codec = RecordingQuality.VideoCodec(
      writerSettings: writerVideoSettings ?? recommendedWriterVideoSettings())
    {
      return codec.rawValue
    }
    if captureVideoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mp4).isEmpty {
      return recordingVideoCodec.rawValue
    }
    return "unknown"
  }

  func writerVideoCodecTypes(forCameraName cameraName: String) -> [AVVideoCodecType]? {
    guard captureDevice.uniqueID == cameraName else { return nil }
    let codecs = captureVideoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mp4)
    return codecs.isEmpty ? nil : codecs
  }

  func waitForRecordingFocus(completion: @escaping (Bool) -> Void) {
    guard captureDevice.isFocusModeSupported(.locked),
      captureDevice.isExposureModeSupported(.locked)
    else {
      completion(false)
      return
    }

    let deadline = DispatchTime.now() + .seconds(2)
    waitForFocusAndExposure(deadline: deadline, completion: completion)
  }

  private func waitForFocusAndExposure(
    deadline: DispatchTime,
    adjustmentObservedAt: DispatchTime? = nil,
    completion: @escaping (Bool) -> Void
  ) {
    guard captureDevice.isFocusModeSupported(.locked),
      captureDevice.isExposureModeSupported(.locked)
    else {
      completion(false)
      return
    }

    let now = DispatchTime.now()
    let isAdjusting = captureDevice.isAdjustingFocus || captureDevice.isAdjustingExposure
    if !isAdjusting && hasMeteringSettled(now: now, adjustmentObservedAt: adjustmentObservedAt) {
      completion(now < deadline)
      return
    }

    guard now < deadline else {
      completion(false)
      return
    }

    let observedAt = isAdjusting ? now : adjustmentObservedAt
    captureSessionQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      guard let self else {
        // The camera was closed while waiting; report no convergence instead of never replying.
        completion(false)
        return
      }
      self.waitForFocusAndExposure(
        deadline: deadline, adjustmentObservedAt: observedAt, completion: completion)
    }
  }

  private func hasMeteringSettled(now: DispatchTime, adjustmentObservedAt: DispatchTime?) -> Bool {
    return CaptureMetering.hasSettled(
      lastChange: lastMeteringChange, adjustmentObservedAt: adjustmentObservedAt, now: now)
  }

  func setFlashMode(
    _ mode: PlatformFlashMode,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    switch mode {
    case .torch:
      guard captureDevice.hasTorch else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Device does not support torch mode",
              details: nil))
        )
        return
      }
      guard captureDevice.isTorchAvailable else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Torch mode is currently not available",
              details: nil)))
        return
      }
      if captureDevice.torchMode != .on {
        do {
          try captureDevice.lockForConfiguration()
        } catch {
          completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
          return
        }
        defer { captureDevice.unlockForConfiguration() }
        captureDevice.torchMode = .on
      }
    case .off, .auto, .always:
      guard captureDevice.hasFlash else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Device does not have flash capabilities",
              details: nil)))
        return
      }
      let avFlashMode = getAVCaptureFlashMode(for: mode)
      guard capturePhotoOutput.supportedFlashModes.contains(avFlashMode)
      else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Device does not support this specific flash mode",
              details: nil)))
        return
      }
      if captureDevice.torchMode != .off {
        do {
          try captureDevice.lockForConfiguration()
        } catch {
          completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
          return
        }
        defer { captureDevice.unlockForConfiguration() }
        captureDevice.torchMode = .off
      }
    @unknown default:
      assertionFailure("Unknown flash mode")
    }

    flashMode = mode
    completion(.success(()))
  }

  func pausePreview() {
    isPreviewPaused = true
  }

  func resumePreview() {
    isPreviewPaused = false
  }

  func setDescriptionWhileRecording(
    _ cameraName: String, withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    guard isRecording else {
      completion(
        .failure(
          PigeonError(
            code: "setDescriptionWhileRecordingFailed",
            message: "Device was not recording",
            details: nil)))
      return
    }

    guard let newDevice = videoCaptureDeviceFactory(cameraName) else {
      completion(
        .failure(
          PigeonError(
            code: "cameraNotFound",
            message: DefaultCamera.cameraNotFoundError(cameraName).localizedDescription,
            details: nil)))
      return
    }

    // Everything that can fail without touching the session is resolved first, so a failure
    // leaves the running recording untouched.
    let requiredFormat: CaptureDeviceFormat?
    do {
      requiredFormat = try self.requiredFormat(for: newDevice)
    } catch {
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: error.localizedDescription,
            details: nil)))
      return
    }

    let newInput: CaptureInput
    let newOutput: CaptureVideoDataOutput
    let newConnection: AVCaptureConnection
    do {
      (newInput, newOutput, newConnection) = try DefaultCamera.createConnection(
        captureDevice: newDevice,
        videoFormat: videoFormat,
        captureDeviceInputFactory: captureDeviceInputFactory)
    } catch {
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to create video connection",
            details: nil)))
      return
    }

    let oldDevice = captureDevice
    let oldInput = captureVideoInput
    let oldOutput = captureVideoOutput
    let oldConnection = oldOutput.connection(with: .video)

    // Keep the same orientation the old connections had.
    if let oldConnection = oldConnection, newConnection.isVideoOrientationSupported {
      newConnection.videoOrientation = oldConnection.videoOrientation
    }

    // Stop video capture from the old output.
    oldOutput.setSampleBufferDelegate(nil, queue: nil)

    videoCaptureSession.beginConfiguration()
    // Every path below commits the configuration exactly once.
    videoCaptureSession.removeInput(oldInput)
    videoCaptureSession.removeOutput(oldOutput.avOutput)

    if let failure = attachVideo(input: newInput, output: newOutput, connection: newConnection) {
      // Restore the previous camera so the recording continues from it.
      let restoredConnection = DefaultCamera.makeVideoConnection(
        input: oldInput, output: oldOutput, position: oldDevice.position)
      if let oldConnection = oldConnection, restoredConnection.isVideoOrientationSupported {
        restoredConnection.videoOrientation = oldConnection.videoOrientation
      }
      if attachVideo(input: oldInput, output: oldOutput, connection: restoredConnection) != nil {
        reportErrorMessage("Unable to restore the previous camera after a failed switch")
      }
      oldOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)
      videoCaptureSession.commitConfiguration()
      completion(.failure(failure))
      return
    }

    captureDevice = newDevice
    captureVideoInput = newInput
    captureVideoOutput = newOutput
    newOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)

    // Timing offsets were tracked on the old output; without re-pointing, a later pause/resume
    // would wait forever for a sample from an output that is no longer attached.
    if outputForOffsetAdjusting == oldOutput.avOutput {
      outputForOffsetAdjusting = newOutput.avOutput
    }

    // Apply the same format and frame duration the camera was configured with.
    if let requiredFormat = requiredFormat {
      do {
        try mediaSettingsAVWrapper.lockDevice(newDevice)
        defer { mediaSettingsAVWrapper.unlockDevice(newDevice) }
        newDevice.flutterActiveFormat = requiredFormat
        if let framesPerSecond = framesPerSecond {
          let duration = CMTimeMakeWithSeconds(1.0 / framesPerSecond, preferredTimescale: 60_000)
          mediaSettingsAVWrapper.setMinFrameDuration(duration, on: newDevice)
          mediaSettingsAVWrapper.setMaxFrameDuration(duration, on: newDevice)
        }
      } catch {
        reportErrorMessage(
          "Unable to apply the recording format to the new camera: \(error.localizedDescription)")
      }
    }

    videoCaptureSession.commitConfiguration()
    completion(.success(()))
  }

  /// The device format `init` selected explicitly (an exact recording profile or `.max`), looked
  /// up on `device`; nil when the session preset determines the format.
  private func requiredFormat(for device: CaptureDevice) throws -> CaptureDeviceFormat? {
    if let framesPerSecond = framesPerSecond {
      let targetResolution = try exactRecordingResolution(for: mediaSettings.resolutionPreset)
      guard
        let format = FormatUtils.findExactFormat(
          for: device,
          targetResolution: targetResolution,
          targetFrameRate: framesPerSecond,
          videoDimensionsConverter: videoDimensionsConverter)
      else {
        throw recordingProfileError(
          width: targetResolution.width,
          height: targetResolution.height,
          framesPerSecond: Int64(framesPerSecond))
      }
      return format
    }
    if mediaSettings.resolutionPreset == .max {
      return highestResolutionFormat(forCaptureDevice: device)
    }
    return nil
  }

  /// Adds `input`, `output` and `connection` to the video session. On failure, whatever was added
  /// is removed again and the error to report is returned. Must be called inside a
  /// `beginConfiguration`/`commitConfiguration` pair.
  private func attachVideo(
    input: CaptureInput,
    output: CaptureVideoDataOutput,
    connection: AVCaptureConnection
  ) -> PigeonError? {
    guard videoCaptureSession.canAddInput(input) else {
      return PigeonError(code: "VideoError", message: "Unable to switch video input", details: nil)
    }
    videoCaptureSession.addInputWithNoConnections(input)

    guard videoCaptureSession.canAddOutput(output.avOutput) else {
      videoCaptureSession.removeInput(input)
      return PigeonError(code: "VideoError", message: "Unable to switch video output", details: nil)
    }
    videoCaptureSession.addOutputWithNoConnections(output.avOutput)

    guard videoCaptureSession.canAddConnection(connection) else {
      videoCaptureSession.removeOutput(output.avOutput)
      videoCaptureSession.removeInput(input)
      return PigeonError(
        code: "VideoError", message: "Unable to switch video connection", details: nil)
    }
    videoCaptureSession.addConnection(connection)
    return nil
  }

  func startImageStream(
    with messenger: any FlutterBinaryMessenger,
    completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    startImageStream(
      with: messenger,
      imageStreamHandler: DefaultImageStreamHandler(captureSessionQueue: captureSessionQueue),
      completion: completion
    )
  }

  func startImageStream(
    with messenger: FlutterBinaryMessenger,
    imageStreamHandler: ImageStreamHandler,
    completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    if isStreamingImages {
      reportErrorMessage("Images from camera are already streaming!")
      completion(.success(()))
      return
    }

    ensureToRunOnMainQueue { [weak self] in
      guard let self else {
        completion(.success(()))
        return
      }
      ImageDataStreamStreamHandler.register(with: messenger, streamHandler: imageStreamHandler)
      self.imageStreamHandler = imageStreamHandler
      self.captureSessionQueue.async { [weak self] in
        if let self {
          self.isStreamingImages = true
          self.streamingPendingFramesCount = 0
        }
        completion(.success(()))
      }
    }
  }

  func stopImageStream() {
    if isStreamingImages {
      isStreamingImages = false
      imageStreamHandler = nil
    } else {
      reportErrorMessage("Images from camera are not streaming!")
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output == captureVideoOutput.avOutput {
      if let newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {

        pixelBufferSynchronizationQueue.sync {
          latestPixelBuffer = newBuffer
        }

        onFrameAvailable?()
      }
    }

    guard CMSampleBufferDataIsReady(sampleBuffer) else {
      reportErrorMessage("sample buffer is not ready. Skipping sample")
      return
    }

    handleSampleBufferStreaming(sampleBuffer)

    if isRecording && !isRecordingPaused && videoCaptureSession.isRunning
      && audioCaptureSession.isRunning
    {
      if videoWriter?.status == .failed, let error = videoWriter?.error {
        reportErrorMessage("\(error)")
        return
      }

      // do not append sample buffer when readyForMoreMediaData is NO to avoid crash
      // https://github.com/flutter/flutter/issues/132073
      if output == captureVideoOutput.avOutput {
        if !(videoWriterInput?.isReadyForMoreMediaData ?? false) {
          return
        }
      } else {
        // ignore audio samples until the first video sample arrives to avoid black frames
        // https://github.com/flutter/flutter/issues/57831
        if isFirstVideoSample || !(audioWriterInput?.isReadyForMoreMediaData ?? false) {
          return
        }
        outputForOffsetAdjusting = output
      }

      let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      if isFirstVideoSample {
        videoWriter?.startSession(atSourceTime: sampleTime)
        // fix sample times not being numeric when pause/resume happens before first sample buffer
        // arrives
        // https://github.com/flutter/flutter/issues/132014
        isRecordingDisconnected = false
        isFirstVideoSample = false
      }

      var currentSampleEndTime = sampleTime
      let duration = CMSampleBufferGetDuration(sampleBuffer)
      if CMTIME_IS_NUMERIC(duration) {
        currentSampleEndTime = CMTimeAdd(currentSampleEndTime, duration)
      }

      // Use a single time offset for both video and audio to avoid desync.
      // https://github.com/flutter/flutter/issues/149978
      if isRecordingDisconnected {
        if output == outputForOffsetAdjusting {
          let offset = CMTimeSubtract(currentSampleEndTime, lastSampleEndTime)
          recordingTimeOffset = CMTimeAdd(recordingTimeOffset, offset)
          lastSampleEndTime = currentSampleEndTime
          isRecordingDisconnected = false
        }
        return
      }

      if output == outputForOffsetAdjusting {
        lastSampleEndTime = currentSampleEndTime
      }

      if output == captureVideoOutput.avOutput {
        let nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let nextSampleTime = CMTimeSubtract(sampleTime, recordingTimeOffset)
        if nextSampleTime > lastAppendedVideoSampleTime {
          let _ = videoAdaptor?.append(nextBuffer!, withPresentationTime: nextSampleTime)
          lastAppendedVideoSampleTime = nextSampleTime
        }
      } else {
        if recordingTimeOffset.value != 0 {
          if let adjustedSampleBuffer = copySampleBufferWithAdjustedTime(
            sampleBuffer,
            by: recordingTimeOffset)
          {
            newAudioSample(adjustedSampleBuffer)
          }
        } else {
          newAudioSample(sampleBuffer)
        }
      }
    }
  }

  private func handleSampleBufferStreaming(_ sampleBuffer: CMSampleBuffer) {
    guard isStreamingImages,
      let eventSink = imageStreamHandler?.eventSink,
      streamingPendingFramesCount < maxStreamingPendingFramesCount
    else {
      return
    }

    // Non-pixel buffer samples, such as audio samples, are ignored for streaming
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    streamingPendingFramesCount += 1

    // Must lock base address before accessing the pixel data
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

    let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
    let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

    var planes: [PlatformCameraImagePlane] = []

    let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
    let planeCount = isPlanar ? CVPixelBufferGetPlaneCount(pixelBuffer) : 1

    for i in 0..<planeCount {
      let planeAddress: UnsafeMutableRawPointer?
      let bytesPerRow: Int
      let height: Int
      let width: Int

      if isPlanar {
        planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i)
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i)
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i)
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i)
      } else {
        planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        width = CVPixelBufferGetWidth(pixelBuffer)
      }

      let length = bytesPerRow * height
      let bytes = Data(bytes: planeAddress!, count: length)

      let planeBuffer = PlatformCameraImagePlane(
        bytes: FlutterStandardTypedData(bytes: bytes),
        bytesPerRow: Int64(bytesPerRow),
        width: Int64(width),
        height: Int64(height)
      )
      planes.append(planeBuffer)
    }

    // Lock the base address before accessing pixel data, and unlock it afterwards.
    // Done accessing the `pixelBuffer` at this point.
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

    let imageBuffer = PlatformCameraImageData(
      formatCode: Int64(videoFormat),
      width: Int64(imageWidth),
      height: Int64(imageHeight),
      planes: planes,
      lensAperture: Double(captureDevice.lensAperture),
      sensorExposureTimeNanoseconds: Int64(captureDevice.exposureDuration.seconds * 1_000_000_000),
      sensorSensitivity: Double(captureDevice.iso)
    )

    DispatchQueue.main.async {
      eventSink.success(imageBuffer)
    }
  }

  private func copySampleBufferWithAdjustedTime(_ sample: CMSampleBuffer, by offset: CMTime)
    -> CMSampleBuffer?
  {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)

    let timingInfo = UnsafeMutablePointer<CMSampleTimingInfo>.allocate(capacity: Int(count))
    defer { timingInfo.deallocate() }

    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: count, arrayToFill: timingInfo, entriesNeededOut: &count)

    for i in 0..<count {
      timingInfo[Int(i)].decodeTimeStamp = CMTimeSubtract(
        timingInfo[Int(i)].decodeTimeStamp, offset)
      timingInfo[Int(i)].presentationTimeStamp = CMTimeSubtract(
        timingInfo[Int(i)].presentationTimeStamp, offset)
    }

    var adjustedSampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil,
      sampleBuffer: sample,
      sampleTimingEntryCount: count,
      sampleTimingArray: timingInfo,
      sampleBufferOut: &adjustedSampleBuffer)

    return adjustedSampleBuffer
  }

  private func newAudioSample(_ sampleBuffer: CMSampleBuffer) {
    guard videoWriter?.status == .writing else {
      if videoWriter?.status == .failed, let error = videoWriter?.error {
        reportErrorMessage("\(error)")
      }
      return
    }
    if !(audioWriterInput?.append(sampleBuffer) ?? false) {
      reportErrorMessage("Unable to write to audio input")
    }
  }

  func close(completion: @escaping () -> Void) {
    stop()
    for input in videoCaptureSession.inputs {
      videoCaptureSession.removeInput(input)
    }
    for output in videoCaptureSession.outputs {
      videoCaptureSession.removeOutput(output)
    }
    for input in audioCaptureSession.inputs {
      audioCaptureSession.removeInput(input)
    }
    for output in audioCaptureSession.outputs {
      audioCaptureSession.removeOutput(output)
    }

    // Closing while recording finalizes the file rather than dropping it (matching the shared
    // release/dispose contract). Dart gets no path from `dispose`, so the file is kept on disk and
    // its path logged; a writer that cannot be finalized is cancelled and its file removed.
    let logOutcome: (Result<String, any Error>) -> Void = { result in
      switch result {
      case .success(let path):
        NSLog("camera_avfoundation: recording finalized on close: %@", path)
      case .failure(let error):
        NSLog("camera_avfoundation: recording could not be finalized on close: %@", "\(error)")
      }
    }
    if case .success(let path)? = backgroundFinalizedRecording {
      NSLog("camera_avfoundation: recording finalized in background was not collected: %@", path)
    }
    backgroundFinalizedRecording = nil

    if isRecording {
      finishWriting { result in
        logOutcome(result)
        completion()
      }
    } else if isFinishingWriting {
      finishWritingWaiters.append { result in
        logOutcome(result)
        completion()
      }
    } else {
      backgroundTask.end()
      completion()
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    var pixelBuffer: CVPixelBuffer?
    pixelBufferSynchronizationQueue.sync {
      pixelBuffer = latestPixelBuffer
      latestPixelBuffer = nil
    }

    if let buffer = pixelBuffer {
      return Unmanaged.passRetained(buffer)
    } else {
      return nil
    }
  }

  /// Reports the given error message to the Dart side of the plugin.
  ///
  /// Can be called from any thread.
  private func reportErrorMessage(_ errorMessage: String) {
    ensureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.error(message: errorMessage) { _ in
        // Ignore any errors, as this is just an event broadcast.
      }
    }
  }

  deinit {
    motionManager.stopAccelerometerUpdates()
    backgroundTask.end()
  }
}
