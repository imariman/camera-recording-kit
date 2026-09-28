import AVFoundation
import FlutterMacOS
import QuartzCore

/// Manages a persistent shared buffer for zero-copy FFI image stream delivery.
/// Native writes frame data here; Dart reads it directly via FFI pointer.
/// Uses a double-buffer strategy so writeFrame() never holds the lock during memcpy.
class ImageStreamFFI {
    // Buffer layout matches C struct ImageStreamBuffer:
    //   int64_t sequence (8 bytes, offset 0)
    //   int32_t width (4 bytes, offset 8)
    //   int32_t height (4 bytes, offset 12)
    //   int32_t bytes_per_row (4 bytes, offset 16)
    //   int32_t format (4 bytes, offset 20) -- 0=BGRA, 1=RGBA
    //   int32_t ready (4 bytes, offset 24) -- 1=ready for Dart, 0=being written
    //   int32_t _pad (4 bytes, offset 28)
    //   uint8_t pixels[] (offset 32)
    static let headerSize = 32

    private var buffers: (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) = (nil, nil)
    private var bufferSizes: (Int, Int) = (0, 0)
    private var frontIndex: Int = 0  // 0 or 1, which buffer Dart reads from
    private var callback: (@convention(c) (Int32) -> Void)?
    private var sequence: Int64 = 0
    private var _disposed = false
    private let lock = UnfairLock()

    func getBufferPointer() -> UnsafeMutableRawPointer? {
        lock.lock()
        guard !_disposed else { lock.unlock(); return nil }
        let idx = frontIndex
        lock.unlock()
        return idx == 0 ? buffers.0 : buffers.1
    }

    var hasCallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func registerCallback(_ cb: @convention(c) (Int32) -> Void) {
        lock.lock()
        callback = cb
        lock.unlock()
    }

    func unregisterCallback() {
        lock.lock()
        callback = nil
        lock.unlock()
    }

    /// Releases buffers and prevents any further writes. Safe to call from any thread.
    func dispose() {
        lock.lock()
        guard !_disposed else { lock.unlock(); return }
        _disposed = true
        callback = nil
        let b0 = buffers.0
        let b1 = buffers.1
        buffers = (nil, nil)
        lock.unlock()
        b0?.deallocate()
        b1?.deallocate()
    }

    func writeFrame(pixelBuffer: CVPixelBuffer, cameraId: Int) {
        // Bail out immediately if disposed, no lock held during memcpy below.
        lock.lock()
        if _disposed { lock.unlock(); return }
        let backIdx = 1 - frontIndex
        lock.unlock()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dataSize = bytesPerRow * height
        let totalSize = ImageStreamFFI.headerSize + dataSize

        // Resize back buffer if needed, hold lock for the pointer swap only.
        lock.lock()
        if _disposed { lock.unlock(); return }
        let backSize = backIdx == 0 ? bufferSizes.0 : bufferSizes.1
        var backBuf = backIdx == 0 ? buffers.0 : buffers.1
        if backSize < totalSize {
            let newBuf = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: 8)
            backBuf?.deallocate()
            backBuf = newBuf
            if backIdx == 0 {
                buffers.0 = newBuf
                bufferSizes.0 = totalSize
            } else {
                buffers.1 = newBuf
                bufferSizes.1 = totalSize
            }
        }
        lock.unlock()

        guard let buf = backBuf else { return }

        // Write to back buffer, no lock held during memcpy
        buf.storeBytes(of: Int32(0), toByteOffset: 24, as: Int32.self) // ready=0
        memcpy(buf.advanced(by: ImageStreamFFI.headerSize), baseAddress, dataSize)

        sequence += 1
        buf.storeBytes(of: sequence, toByteOffset: 0, as: Int64.self)
        buf.storeBytes(of: Int32(width), toByteOffset: 8, as: Int32.self)
        buf.storeBytes(of: Int32(height), toByteOffset: 12, as: Int32.self)
        buf.storeBytes(of: Int32(bytesPerRow), toByteOffset: 16, as: Int32.self)
        buf.storeBytes(of: Int32(0), toByteOffset: 20, as: Int32.self) // format=BGRA
        buf.storeBytes(of: Int32(1), toByteOffset: 24, as: Int32.self) // ready=1

        // Swap front/back and invoke callback (a native no-op symbol) under
        // the lock. Safe because the callback is a trivial C function.
        lock.lock()
        if _disposed { lock.unlock(); return }
        frontIndex = backIdx
        callback?(Int32(cameraId))
        lock.unlock()
    }

    deinit {
        dispose()
    }
}

/// Manages a single camera session, AVCaptureSession lifecycle, preview texture,
/// photo capture, video recording, and image streaming.
///
/// One CameraSession instance exists per active camera (identified by cameraId).
class CameraSession: NSObject {
    let cameraId: Int
    private(set) var textureId: Int64 = -1

    private let config: CameraConfig
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var texture: CameraTexture?
    private weak var textureRegistry: FlutterTextureRegistry?
    private weak var methodChannel: FlutterMethodChannel?

    private let captureQueue = DispatchQueue(label: "com.hugocornellier.camera_desktop.capture")
    private let audioQueue = DispatchQueue(label: "com.hugocornellier.camera_desktop.audio")
    private let sessionQueue = DispatchQueue(label: "com.hugocornellier.camera_desktop.session")
    private let bufferLock = UnfairLock()
    private let flagsLock = UnfairLock()

    private var lastTextureNotification: CFTimeInterval = 0
    private let textureNotificationInterval: CFTimeInterval = 1.0 / 120.0

    private var recordHandler = RecordHandler()

    // All stabilization state belongs to captureQueue, including pixel buffers.
    private var videoStabilizer: MacOSVideoStabilizer?
    private var stabilizationVerified = false
    private var stabilizationFailure: String?
    private var pendingStabilizationResult: FlutterResult?
    private var stabilizationGeneration = 0
    private let imageStreamFFI = ImageStreamFFI()
    private var _previewPaused = false
    private var _imageStreaming = false
    private var _isDisposed = false
    private var latestBuffer: CVPixelBuffer?

    private var previewPaused: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _previewPaused }
        set { flagsLock.lock(); _previewPaused = newValue; flagsLock.unlock() }
    }

    private var imageStreaming: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _imageStreaming }
        set { flagsLock.lock(); _imageStreaming = newValue; flagsLock.unlock() }
    }

    private var actualWidth: Int = 0
    private var actualHeight: Int = 0
    private var configuredWidth: Int = 0
    private var configuredHeight: Int = 0
    private var firstFrameReceived = false

    /// Pending initialization result callback, called when the first frame arrives.
    private var pendingInitResult: FlutterResult?

    struct CameraConfig {
        let deviceId: String
        let resolutionPreset: Int
        let enableAudio: Bool
        let targetFps: Int
        let targetBitrate: Int
        let audioBitrate: Int
        let videoCodec: RecordingQuality.VideoCodec
    }

    init(cameraId: Int, config: CameraConfig,
         textureRegistry: FlutterTextureRegistry,
         methodChannel: FlutterMethodChannel) {
        self.cameraId = cameraId
        self.config = config
        self.textureRegistry = textureRegistry
        self.methodChannel = methodChannel
        super.init()
    }

    // MARK: - Texture Registration

    /// Registers a FlutterTexture and returns the texture ID.
    func registerTexture() -> Int64 {
        let tex = CameraTexture()
        texture = tex
        guard let registry = textureRegistry else { return -1 }
        textureId = registry.register(tex)
        return textureId
    }

    // MARK: - Initialization

    /// Initializes the AVCaptureSession. Responds asynchronously when the first frame arrives.
    func initialize(result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                DispatchQueue.main.async {
                    result(FlutterError(code: "permission_denied",
                                        message: "Camera permission was denied",
                                        details: nil))
                }
                return
            }
            if self.config.enableAudio {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioGranted in
                    guard let self = self else { return }
                    guard audioGranted else {
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code: "audio_permission_denied",
                                message: "Microphone permission was denied.",
                                details: nil
                            ))
                        }
                        return
                    }
                    self.sessionQueue.async {
                        self.setupSession(result: result)
                    }
                }
            } else {
                self.sessionQueue.async {
                    self.setupSession(result: result)
                }
            }
        }
    }

    private func setupSession(result: @escaping FlutterResult) {
        let session = AVCaptureSession()

        // Resolve the exact selected device. Falling back to another camera can
        // disclose the wrong feed and makes capability results meaningless.
        let devices = AVCaptureDevice.captureDevices(mediaType: .video)
        guard let device = devices.first(where: { $0.uniqueID == config.deviceId }) else {
            DispatchQueue.main.async {
                result(FlutterError(code: "no_camera",
                                    message: "No camera device found for ID: \(self.config.deviceId)",
                                    details: nil))
            }
            return
        }
        videoDevice = device

        let selectedFormat: RecordingQuality.SelectedFormat
        do {
            selectedFormat = try RecordingQuality.selectFormat(
                for: device,
                resolutionPreset: config.resolutionPreset,
                framesPerSecond: config.targetFps,
                codec: config.videoCodec
            )
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
                result(FlutterError(code: "unsupportedRecordingProfile",
                                    message: message,
                                    details: nil))
            }
            return
        }

        // Add video input.
        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            let canAdd = session.canAddInput(videoInput)
            guard canAdd else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "input_failed",
                                        message: "canAddInput returned false for device=\(device.uniqueID) format=BGRA",
                                        details: nil))
                }
                return
            }
            session.addInput(videoInput)
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
                result(FlutterError(code: "input_failed",
                                    message: "Failed to create video input: \(message)",
                                    details: nil))
            }
            return
        }

        // Add audio input if enabled.
        if config.enableAudio {
            let audioDevices = AVCaptureDevice.captureDevices(mediaType: .audio)
            guard let audioDevice = audioDevices.first else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "audio_unavailable",
                                        message: "Audio recording was requested but no microphone is available.",
                                        details: nil))
                }
                return
            }
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                guard session.canAddInput(audioInput) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "audio_input_failed",
                                            message: "The selected microphone cannot be added to this capture session.",
                                            details: nil))
                    }
                    return
                }
                session.addInput(audioInput)
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    result(FlutterError(code: "audio_input_failed",
                                        message: "Could not configure the microphone: \(message)",
                                        details: nil))
                }
                return
            }
        }

        // Add video output.
        let vOutput = AVCaptureVideoDataOutput()
        vOutput.alwaysDiscardsLateVideoFrames = true
        vOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        vOutput.setSampleBufferDelegate(self, queue: captureQueue)
        let canAddOutput = session.canAddOutput(vOutput)
        guard canAddOutput else {
            DispatchQueue.main.async {
                result(FlutterError(code: "output_failed",
                                    message: "canAddOutput returned false for device=\(device.uniqueID) format=BGRA",
                                    details: nil))
            }
            return
        }
        session.addOutput(vOutput)
        videoOutput = vOutput

        // Preview mirroring remains runtime configurable. The app disables it
        // before recording so the saved sensor stream stays unmirrored.
        if let connection = vOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        } else {
        }

        // Add audio output if enabled.
        if config.enableAudio {
            let aOutput = AVCaptureAudioDataOutput()
            aOutput.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(aOutput) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "audio_output_failed",
                                        message: "Audio capture output is unavailable.",
                                        details: nil))
                }
                return
            }
            session.addOutput(aOutput)
            audioOutput = aOutput
        }

        // macOS does not expose AVCaptureSessionPresetInputPriority. Configure
        // the device's activeFormat directly after the complete session graph
        // has been attached, and bracket format + frame duration changes in one
        // capture-session configuration transaction as AVFoundation requires.
        session.beginConfiguration()
        do {
            try device.lockForConfiguration()
            device.activeFormat = selectedFormat.format
            let requestedDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(selectedFormat.profile.framesPerSecond)
            )
            device.activeVideoMinFrameDuration = requestedDuration
            device.activeVideoMaxFrameDuration = requestedDuration
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            let message = error.localizedDescription
            DispatchQueue.main.async {
                result(FlutterError(code: "unsupportedRecordingProfile",
                                    message: "Could not apply the requested recording profile: \(message)",
                                    details: nil))
            }
            return
        }

        let activeDimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )
        let activeFps = RecordingQuality.framesPerSecond(for: device.activeVideoMinFrameDuration)
        guard activeDimensions.width == selectedFormat.profile.width,
              activeDimensions.height == selectedFormat.profile.height,
              let activeFps = activeFps,
              abs(activeFps - Double(selectedFormat.profile.framesPerSecond)) < 0.01 else {
            DispatchQueue.main.async {
                result(FlutterError(code: "unsupportedRecordingProfile",
                                    message: "AVFoundation applied a different format or frame rate than requested.",
                                    details: nil))
            }
            return
        }
        configuredWidth = Int(activeDimensions.width)
        configuredHeight = Int(activeDimensions.height)

        // Subscribe to runtime error and interruption notifications.
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError,
                       object: session)
        nc.addObserver(self,
                       selector: #selector(sessionWasInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted,
                       object: session)
        nc.addObserver(self,
                       selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded,
                       object: session)

        captureSession = session
        pendingInitResult = result
        firstFrameReceived = false

        // Start running, the first frame callback will respond to the pending result.
        session.startRunning()

        // Timeout: if no frame arrives in 15 seconds, fail.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self, let pending = self.pendingInitResult else { return }
            self.pendingInitResult = nil
            pending(FlutterError(code: "initialization_timeout",
                                 message: "Camera initialization timed out, no frames received",
                                 details: nil))
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        let message = error?.localizedDescription ?? "Unknown runtime error"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.methodChannel?.invokeMethod("cameraError", arguments: [
                "cameraId": self.cameraId,
                "message": message,
            ])
        }
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.methodChannel?.invokeMethod("cameraError", arguments: [
                "cameraId": self.cameraId,
                "message": "Camera session interrupted",
            ])
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
    }

    // MARK: - Photo Capture

    func takePicture(result: @escaping FlutterResult) {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()

        guard let buffer = buffer else {
            result(FlutterError(code: "no_frame",
                                message: "No frame available for capture",
                                details: nil))
            return
        }

        let path = PhotoHandler.generatePath(cameraId: cameraId)
        sessionQueue.async {
            let success = PhotoHandler.takePicture(from: buffer, outputPath: path)
            DispatchQueue.main.async {
                if success {
                    result(path)
                } else {
                    result(FlutterError(code: "capture_failed",
                                        message: "Failed to write JPEG to disk",
                                        details: nil))
                }
            }
        }
    }

    // MARK: - Video Recording

    func startVideoRecording(result: @escaping FlutterResult) {
        let enableAudio = config.enableAudio

        sessionQueue.async { [self] in
            do {
                self.bufferLock.lock()
                let recordingWidth = self.actualWidth
                let recordingHeight = self.actualHeight
                self.bufferLock.unlock()
                let captureClock: CMClock?
                if #available(macOS 12.3, *) {
                    captureClock = self.captureSession?.synchronizationClock
                } else {
                    captureClock = self.captureSession?.masterClock
                }
                _ = try self.recordHandler.startRecording(
                    width: recordingWidth,
                    height: recordingHeight,
                    targetFps: self.config.targetFps,
                    targetBitrate: self.config.targetBitrate,
                    audioBitrate: self.config.audioBitrate,
                    videoCodec: self.config.videoCodec,
                    enableAudio: enableAudio,
                    captureClock: captureClock
                )
                DispatchQueue.main.async { result(nil) }
            } catch {
                let nsError = error as NSError
                let code = nsError.domain == RecordingQuality.errorDomain && nsError.code == 2
                    ? "unsupportedRecordingProfile"
                    : "recording_failed"
                DispatchQueue.main.async {
                    result(FlutterError(code: code,
                                        message: "Failed to start recording: \(nsError.localizedDescription)",
                                        details: nil))
                }
            }
        }
    }

    func pauseVideoRecording(result: @escaping FlutterResult) {
        sessionQueue.async { [self] in
            guard self.recordHandler.isRecording else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "not_recording", message: "No recording in progress", details: nil))
                }
                return
            }
            _ = self.recordHandler.pause()
            DispatchQueue.main.async { result(nil) }
        }
    }

    func resumeVideoRecording(result: @escaping FlutterResult) {
        sessionQueue.async { [self] in
            guard self.recordHandler.isRecording else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "not_recording", message: "No recording in progress", details: nil))
                }
                return
            }
            self.captureQueue.async {
                // The capture profile is unchanged across a pause, so keep the
                // stabilizer's buffer pools and only drop stale motion state.
                self.videoStabilizer?.resetMotion()
                _ = self.recordHandler.resume()
                DispatchQueue.main.async { result(nil) }
            }
        }
    }

    func stopVideoRecording(result: @escaping FlutterResult) {
        guard recordHandler.isRecording else {
            result(FlutterError(code: "not_recording",
                                message: "No recording in progress",
                                details: nil))
            return
        }

        recordHandler.stopRecording { path in
            DispatchQueue.main.async {
                if let path = path {
                    result(path)
                } else {
                    result(FlutterError(code: "recording_failed",
                                        message: "Failed to finalize recording",
                                        details: nil))
                }
            }
        }
    }

    // MARK: - Image Streaming

    func startImageStream() {
        imageStreaming = true
    }

    func stopImageStream() {
        imageStreaming = false
    }

    // MARK: - FFI Image Stream Access

    func getImageStreamBufferPointer() -> UnsafeMutableRawPointer? {
        return imageStreamFFI.getBufferPointer()
    }

    func registerImageStreamCallback(_ callback: @convention(c) (Int32) -> Void) {
        imageStreamFFI.registerCallback(callback)
    }

    func unregisterImageStreamCallback() {
        imageStreamFFI.unregisterCallback()
    }

    // MARK: - Preview Control

    func pausePreview() {
        previewPaused = true
    }

    func resumePreview() {
        previewPaused = false
    }

    // MARK: - Software Video Stabilization

    private var stabilizationAvailable: Bool {
        MacOSVideoStabilizer.availability(
            width: configuredWidth, height: configuredHeight,
            framesPerSecond: config.targetFps
        ).isAvailable
    }

    func getSupportedVideoStabilizationModes(result: @escaping FlutterResult) {
        captureQueue.async { [self] in
            let modes = self.stabilizationAvailable ? ["off", "level1"] : ["off"]
            DispatchQueue.main.async { result(modes) }
        }
    }

    func setVideoStabilizationMode(_ mode: String, result: @escaping FlutterResult) {
        captureQueue.async { [self] in
            guard !self.recordHandler.isRecording else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "recording_in_progress", message: "Change stabilization before recording.", details: nil))
                }
                return
            }
            guard mode == "off" || (mode == "level1" && self.stabilizationAvailable) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "unsupported_stabilization_mode", message: "Software stabilization supports up to 1080p at 30 FPS.", details: nil))
                }
                return
            }
            self.finishPendingStabilization(error: "Stabilization configuration was superseded.")
            self.stabilizationGeneration += 1
            self.stabilizationVerified = false
            self.stabilizationFailure = nil
            self.videoStabilizer = nil
            if mode == "off" {
                DispatchQueue.main.async { result(nil) }
                return
            }
            let stabilizer = MacOSVideoStabilizer()
            guard stabilizer.configure(width: self.configuredWidth, height: self.configuredHeight,
                                       framesPerSecond: self.config.targetFps).isAvailable else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "stabilization_failed", message: "Could not allocate stabilization buffers.", details: nil))
                }
                return
            }
            self.videoStabilizer = stabilizer
            self.pendingStabilizationResult = result
            let generation = self.stabilizationGeneration
            // Only report applied after a real capture sample has traversed the pipeline.
            self.captureQueue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                guard let self, self.stabilizationGeneration == generation,
                      self.pendingStabilizationResult != nil else { return }
                self.videoStabilizer = nil
                self.stabilizationVerified = false
                self.finishPendingStabilization(error: "No stabilized capture frame arrived in time.")
            }
        }
    }

    private func finishPendingStabilization(error: String? = nil) {
        guard let pending = pendingStabilizationResult else { return }
        pendingStabilizationResult = nil
        DispatchQueue.main.async {
            if let error {
                pending(FlutterError(code: "stabilization_failed", message: error, details: nil))
            } else {
                pending(nil)
            }
        }
    }

    private func sensorPoint(fromPreview point: CGPoint) -> CGPoint {
        captureQueue.sync {
            self.videoStabilizer?.sensorPoint(fromOutputNormalized: point) ?? point
        }
    }

    // MARK: - Mirror Control

    /// Toggles horizontal mirroring on the live video output connection.
    /// Can be called while the session is running, no restart needed.
    func setMirror(mirrored: Bool) {
        sessionQueue.async { [self] in
            guard let connection = self.videoOutput?.connection(with: .video) else {
                return
            }
            guard connection.isVideoMirroringSupported else {
                return
            }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    // MARK: - Focus and Exposure

    func setExposureMode(_ mode: Int, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else {
                self?.replyCameraUnavailable(result)
                return
            }
            let requestedMode: AVCaptureDevice.ExposureMode
            switch mode {
            case 0:
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    requestedMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    requestedMode = .autoExpose
                } else {
                    self.replyUnsupportedControl("Automatic exposure is unavailable.", result: result)
                    return
                }
            case 1:
                guard device.isExposureModeSupported(.locked) else {
                    self.replyUnsupportedControl("Exposure lock is unavailable.", result: result)
                    return
                }
                requestedMode = .locked
            default:
                self.replyInvalidControl("Unknown exposure mode \(mode).", result: result)
                return
            }
            do {
                try device.lockForConfiguration()
                device.exposureMode = requestedMode
                device.unlockForConfiguration()
                DispatchQueue.main.async { result(nil) }
            } catch {
                self.replyControlError("Could not set exposure mode: \(error.localizedDescription)", result: result)
            }
        }
    }

    func setExposurePoint(_ point: CGPoint?, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else {
                self?.replyCameraUnavailable(result)
                return
            }
            guard device.isExposurePointOfInterestSupported else {
                self.replyUnsupportedControl("Exposure point selection is unavailable.", result: result)
                return
            }
            let requestedPoint = point ?? CGPoint(x: 0.5, y: 0.5)
            guard Self.isValid(point: requestedPoint) else {
                self.replyInvalidControl("Exposure point must be within the normalized 0...1 range.", result: result)
                return
            }
            do {
                try device.lockForConfiguration()
                device.exposurePointOfInterest = self.sensorPoint(fromPreview: requestedPoint)
                // Reassign the current automatic mode to trigger a new cycle;
                // never change a lock mode selected by Dart.
                if device.exposureMode == .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                } else if device.exposureMode == .autoExpose {
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { result(nil) }
            } catch {
                self.replyControlError("Could not set exposure point: \(error.localizedDescription)", result: result)
            }
        }
    }

    func setFocusMode(_ mode: Int, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else {
                self?.replyCameraUnavailable(result)
                return
            }
            let requestedMode: AVCaptureDevice.FocusMode
            switch mode {
            case 0:
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    requestedMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    requestedMode = .autoFocus
                } else {
                    self.replyUnsupportedControl("Automatic focus is unavailable.", result: result)
                    return
                }
            case 1:
                guard device.isFocusModeSupported(.locked) else {
                    self.replyUnsupportedControl("Focus lock is unavailable.", result: result)
                    return
                }
                requestedMode = .locked
            default:
                self.replyInvalidControl("Unknown focus mode \(mode).", result: result)
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusMode = requestedMode
                device.unlockForConfiguration()
                DispatchQueue.main.async { result(nil) }
            } catch {
                self.replyControlError("Could not set focus mode: \(error.localizedDescription)", result: result)
            }
        }
    }

    func setFocusPoint(_ point: CGPoint?, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else {
                self?.replyCameraUnavailable(result)
                return
            }
            guard device.isFocusPointOfInterestSupported else {
                self.replyUnsupportedControl("Focus point selection is unavailable.", result: result)
                return
            }
            let requestedPoint = point ?? CGPoint(x: 0.5, y: 0.5)
            guard Self.isValid(point: requestedPoint) else {
                self.replyInvalidControl("Focus point must be within the normalized 0...1 range.", result: result)
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = self.sensorPoint(fromPreview: requestedPoint)
                // Preserve Dart's active mode while retriggering an automatic cycle.
                if device.focusMode == .continuousAutoFocus {
                    device.focusMode = .continuousAutoFocus
                } else if device.focusMode == .autoFocus {
                    device.focusMode = .autoFocus
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { result(nil) }
            } catch {
                self.replyControlError("Could not set focus point: \(error.localizedDescription)", result: result)
            }
        }
    }

    func recordingQualityApplied(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else {
                self?.replyCameraUnavailable(result)
                return
            }
            self.bufferLock.lock()
            let sampleWidth = self.actualWidth
            let sampleHeight = self.actualHeight
            self.bufferLock.unlock()
            guard sampleWidth > 0 && sampleHeight > 0 else {
                self.replyControlError("No verified video sample is available yet.", result: result)
                return
            }

            let activeDimensions = CMVideoFormatDescriptionGetDimensions(
                device.activeFormat.formatDescription
            )
            var applied: [String: Any] = [
                "width": sampleWidth,
                "height": sampleHeight,
                "dimensionsSource": "captureSample",
                "configuredWidth": Int(activeDimensions.width),
                "configuredHeight": Int(activeDimensions.height),
                // AVAssetWriter input settings are constructed with this exact
                // codec and validated before recording starts.
                "codec": self.config.videoCodec.rawValue,
                "codecSource": "configuredAVAssetWriter",

            ]
            if let framesPerSecond = RecordingQuality.framesPerSecond(
                for: device.activeVideoMinFrameDuration
            ) {
                applied["fps"] = framesPerSecond
                applied["fpsSource"] = "activeVideoMinFrameDuration"
                applied["configuredFps"] = framesPerSecond
            }
            self.captureQueue.async {
                applied["stabilizationEnabled"] = self.stabilizationVerified
                applied["supportsVideoStabilization"] = self.stabilizationAvailable
                applied["stabilizationAlgorithm"] = self.videoStabilizer == nil ? "off" : "visionTranslationalCoreImage"
                applied["stabilizationCropInsetFraction"] = self.stabilizationVerified ? Double(MacOSVideoStabilizer.cropInsetFraction) : 0
                if let failure = self.stabilizationFailure { applied["stabilizationFailure"] = failure }
                DispatchQueue.main.async { result(applied) }
            }
        }
    }

    func waitForRecordingFocus(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else {
                DispatchQueue.main.async { result(false) }
                return
            }
            guard device.isFocusModeSupported(.locked),
                  device.isExposureModeSupported(.locked) else {
                DispatchQueue.main.async { result(false) }
                return
            }
            self.waitForFocusAndExposure(
                device: device,
                deadline: DispatchTime.now() + .seconds(2),
                result: result
            )
        }
    }

    private func waitForFocusAndExposure(
        device: AVCaptureDevice,
        deadline: DispatchTime,
        result: @escaping FlutterResult
    ) {
        guard videoDevice === device else {
            DispatchQueue.main.async { result(false) }
            return
        }
        if !device.isAdjustingFocus && !device.isAdjustingExposure {
            DispatchQueue.main.async { result(DispatchTime.now() < deadline) }
            return
        }
        guard DispatchTime.now() < deadline else {
            DispatchQueue.main.async { result(false) }
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { result(false) }
                return
            }
            self.waitForFocusAndExposure(device: device, deadline: deadline, result: result)
        }
    }

    private static func isValid(point: CGPoint) -> Bool {
        return point.x.isFinite && point.y.isFinite &&
            (0.0...1.0).contains(point.x) && (0.0...1.0).contains(point.y)
    }

    private func replyCameraUnavailable(_ result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(FlutterError(code: "camera_not_found", message: "Camera is unavailable.", details: nil))
        }
    }

    private func replyUnsupportedControl(_ message: String, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(FlutterError(code: "unsupported", message: message, details: nil))
        }
    }

    private func replyInvalidControl(_ message: String, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(FlutterError(code: "invalid_args", message: message, details: nil))
        }
    }

    private func replyControlError(_ message: String, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(FlutterError(code: "camera_configuration", message: message, details: nil))
        }
    }

    // MARK: - Disposal

    /// Disposes the camera session. Safe to call multiple times (idempotent).
    ///
    /// Synchronously unregisters the FFI callback, stops image streaming, stops
    /// the AVCaptureSession (which blocks until all in-flight delegate calls
    /// complete), and tears down the session graph. After this method returns,
    /// the capture queue will not invoke any more callbacks.
    /// Texture unregistration and the cameraClosing event are dispatched to the
    /// main queue as they require UI-thread access.
    func dispose() {
        // Idempotency guard, first caller wins.
        flagsLock.lock()
        if _isDisposed { flagsLock.unlock(); return }
        _isDisposed = true
        _imageStreaming = false
        flagsLock.unlock()


        // Null out the FFI callback under lock, guarantees no in-flight
        // invocation reaches Dart after this returns.
        imageStreamFFI.unregisterCallback()

        // Remove notification observers before stopping the session.
        NotificationCenter.default.removeObserver(self)

        // stopRunning() blocks until all in-flight AVCaptureOutput delegate
        // calls have returned, so after this line captureOutput() cannot fire.
        recordHandler.stopRecording { _ in }
        captureSession?.stopRunning()
        captureQueue.sync {
            self.finishPendingStabilization(error: "Camera was disposed.")
            self.videoStabilizer = nil
            self.stabilizationVerified = false
        }
        captureSession = nil
        videoDevice = nil
        videoOutput = nil
        audioOutput = nil

        // The plugin has removed this session from its registry. Retain it
        // until the main-thread texture cleanup finishes, including when a
        // quality change immediately creates the next camera session.
        DispatchQueue.main.async { [self] in
            if self.texture != nil, let registry = self.textureRegistry {
                registry.unregisterTexture(self.textureId)
            }
            self.texture = nil
            self.methodChannel?.invokeMethod("cameraClosing", arguments: ["cameraId": self.cameraId])
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Route audio buffers to the record handler.
        if output == audioOutput {
            recordHandler.appendAudioBuffer(sampleBuffer)
            return
        }

        // Preview, photos, image stream and recording share the same sensor-only image.
        var outputSample = sampleBuffer
        if let stabilizer = videoStabilizer {
            let processed = stabilizer.process(sampleBuffer: sampleBuffer)
            outputSample = processed.sampleBuffer
            stabilizationVerified = processed.isStabilized
            stabilizationFailure = processed.fallbackReason
            if processed.isStabilized { finishPendingStabilization() }
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(outputSample) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Store the latest buffer for photo capture.
        bufferLock.lock()
        latestBuffer = pixelBuffer
        bufferLock.unlock()

        // Handle first-frame initialization response.
        let isFirstFrame = !firstFrameReceived
        if isFirstFrame {
            firstFrameReceived = true
            let activeDimensions = videoDevice.map {
                CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
            }
            let activeFps = videoDevice.flatMap {
                RecordingQuality.framesPerSecond(for: $0.activeVideoMinFrameDuration)
            }
            guard width == configuredWidth,
                  height == configuredHeight,
                  activeDimensions?.width == Int32(configuredWidth),
                  activeDimensions?.height == Int32(configuredHeight),
                  let activeFps = activeFps,
                  abs(activeFps - Double(config.targetFps)) < 0.01 else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let pending = self.pendingInitResult else { return }
                    self.pendingInitResult = nil
                    pending(FlutterError(
                        code: "unsupportedRecordingProfile",
                        message: "Capture did not preserve the requested \(self.configuredWidth)x\(self.configuredHeight) at \(self.config.targetFps) FPS profile.",
                        details: nil
                    ))
                }
                sessionQueue.async { [weak self] in self?.captureSession?.stopRunning() }
                return
            }
            bufferLock.lock()
            actualWidth = width
            actualHeight = height
            bufferLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let pending = self.pendingInitResult else { return }
                self.pendingInitResult = nil
                pending([
                    "previewWidth": Double(width),
                    "previewHeight": Double(height),
                    "supportsExposurePoint": self.videoDevice?.isExposurePointOfInterestSupported ?? false,
                    "supportsFocusPoint": self.videoDevice?.isFocusPointOfInterestSupported ?? false,
                ])
            }
        }

        // Update the texture for Flutter preview.
        if !previewPaused || isFirstFrame {
            texture?.update(buffer: pixelBuffer)
            let now = CACurrentMediaTime()
            if isFirstFrame || (now - lastTextureNotification) >= textureNotificationInterval {
                lastTextureNotification = now
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let registry = self.textureRegistry else { return }
                    registry.textureFrameAvailable(self.textureId)
                }
            }
        }

        // Append to recording if active.
        recordHandler.appendVideoBuffer(outputSample)

        // Send frame to Dart image stream if active.
        if imageStreaming {
            if imageStreamFFI.hasCallback {
                imageStreamFFI.writeFrame(pixelBuffer: pixelBuffer, cameraId: cameraId)
            } else {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let dataSize = bytesPerRow * height
                let data = Data(bytes: baseAddress, count: dataSize)
                let capturedBytesPerRow = bytesPerRow
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.methodChannel?.invokeMethod("imageStreamFrame", arguments: [
                        "cameraId": self.cameraId,
                        "width": width,
                        "height": height,
                        "bytesPerRow": capturedBytesPerRow,
                        "bytes": FlutterStandardTypedData(bytes: data),
                    ])
                }
            }
        }
    }
}
