import 'dart:async';

import 'package:flutter/services.dart';

import 'package:camera/camera.dart';

import 'package:camera_recording/src/platform/camera_platform_capabilities.dart';
import 'package:camera_recording/src/models/recording_profile.dart';
import 'package:camera_recording/src/models/recording_capabilities.dart';
import 'package:camera_recording/src/models/recorded_media_metadata.dart';
import 'package:camera_recording/src/models/recording_result.dart';
import 'package:camera_recording/src/models/recording_storage_estimate.dart';
import 'package:camera_recording/src/services/recording_gateway.dart';

typedef CameraControllerFactory =
    CameraController Function({
      required CameraDescription description,
      required ResolutionPreset resolutionPreset,
      required bool enableAudio,
    });

/// When starting a new controller and restoring the previous camera/profile
/// both fail, the service has no usable preview. Both errors are retained for diagnostics.
class CameraControllerRecoveryException implements Exception {
  const CameraControllerRecoveryException({
    required this.applyError,
    required this.recoveryError,
  });

  final Object applyError;
  final Object recoveryError;

  @override
  String toString() =>
      'CameraControllerRecoveryException('
      'applyError: $applyError, recoveryError: $recoveryError)';
}

/// Coordinates camera preview, recording, and quality negotiation.
///
/// `startVideoRecording` records only the camera sensor stream. Any widgets
/// drawn above the preview are not burned into the saved video.
class CameraService {
  CameraService(
    this._cameras, {
    CameraPlatformCapabilities? capabilities,
    CameraControllerFactory? controllerFactory,
    RecordingGateway? recordingGateway,
    this.focusSettleDelay = const Duration(milliseconds: 400),
  }) : _capabilities = capabilities ?? CameraPlatformCapabilities.current,
       // Keep the public factory argument for existing host adapters.
       // ignore: prefer_initializing_formals
       _controllerFactory = controllerFactory,
       _gateway = recordingGateway ?? const RecordingGateway();

  /// Cameras available on the device, from `availableCameras()` in bootstrap.
  final List<CameraDescription> _cameras;
  final CameraPlatformCapabilities _capabilities;
  final CameraControllerFactory? _controllerFactory;
  final RecordingGateway _gateway;
  RecordingCapabilities _recordingCapabilities = const RecordingCapabilities();
  AppliedRecordingProfile? _appliedProfile;
  AppliedRecordingProfile? _captureProfile;
  bool _focusLockUnavailable = false;

  bool get supportsQualitySelection =>
      _controllerFactory == null && _gateway.supportsQualitySelection;
  RecordingCapabilities get recordingCapabilities => _recordingCapabilities;
  AppliedRecordingProfile? get appliedProfile => _appliedProfile;
  bool get focusLockUnavailable => _focusLockUnavailable;
  final Duration focusSettleDelay;

  CameraController? _controller;
  CameraDescription? _selectedCamera;
  RecordingProfile _recordingProfile = const RecordingProfile();
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposeRequested = false;
  final StreamController<RecordingResult> _interruptedRecordings =
      StreamController<RecordingResult>.broadcast();
  bool _videoStabilizationEnabled = false;
  double _minimumZoomLevel = 1;
  double _maximumZoomLevel = 1;
  double _zoomLevel = 1;
  double _minimumExposureOffset = 0;
  double _maximumExposureOffset = 0;
  double _exposureOffsetStepSize = 0;
  double _exposureOffset = 0;

  CameraController? get controller => _controller;
  List<CameraDescription> get cameras => List.unmodifiable(_cameras);
  CameraDescription? get selectedCamera =>
      _selectedCamera ?? _controller?.description;

  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isRecording => _controller?.value.isRecordingVideo ?? false;
  bool get isRecordingPaused => _controller?.value.isRecordingPaused ?? false;
  bool get hasCameras => _cameras.isNotEmpty;
  RecordingProfile get recordingProfile => _recordingProfile;
  bool get supportsFocusAndExposureControls =>
      _capabilities.supportsFocusAndExposureControls;
  bool get supportsVideoStabilization =>
      _capabilities.supportsVideoStabilization;
  bool get videoStabilizationEnabled => _videoStabilizationEnabled;
  double get minimumZoomLevel => _minimumZoomLevel;
  double get maximumZoomLevel => _maximumZoomLevel;
  double get zoomLevel => _zoomLevel;
  double get minimumExposureOffset => _minimumExposureOffset;
  double get maximumExposureOffset => _maximumExposureOffset;
  double get exposureOffsetStepSize => _exposureOffsetStepSize;
  double get exposureOffset => _exposureOffset;
  bool get supportsZoom => _maximumZoomLevel > _minimumZoomLevel;
  bool get supportsExposureCompensation =>
      _maximumExposureOffset > _minimumExposureOffset;

  /// Recordings that [release] or [dispose] had to stop because they were
  /// still active, for example when the app entered background mid-recording.
  ///
  /// Each event carries the finalized original file, the same file
  /// [finishRecording] would have returned, so the host can offer Save/Discard.
  /// The service never deletes it. Metadata holds only the configured capture
  /// context (null without a verified quality profile); the file is not
  /// inspected, which keeps release fast while the app is backgrounding.
  ///
  /// This is a broadcast stream and events are not buffered: subscribe before
  /// calling [release] or [dispose]. The stream closes after [dispose].
  Stream<RecordingResult> get onRecordingInterrupted =>
      _interruptedRecordings.stream;

  /// Switches front/back cameras on mobile and built-in, external, or Continuity
  /// cameras on desktop. No button is shown on single-camera devices.
  bool get canSwitchCamera => _cameras.length > 1;

  CameraDescription? cameraNamed(String name) {
    if (name.isEmpty) return null;
    for (final camera in _cameras) {
      if (camera.name == name) return camera;
    }
    return null;
  }

  CameraDescription? _select({required bool front}) {
    if (_cameras.isEmpty) return null;
    final direction = front
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    for (final cam in _cameras) {
      if (cam.lensDirection == direction) return cam;
    }
    return _cameras.first;
  }

  /// CameraX surface and recorder transitions are not safe for concurrent calls.
  /// Serializing native camera operations prevents start, stop, dispose, and
  /// camera-switch races.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Starts the selected camera and returns a controller ready for preview.
  Future<CameraController?> initialize({
    required bool front,
    String preferredName = '',
    RecordingProfile? recordingProfile,
  }) async {
    if (_disposeRequested) return null;
    final profile = recordingProfile ?? _recordingProfile;
    if (isRecording) return null;
    final description =
        _selectedCamera ?? cameraNamed(preferredName) ?? _select(front: front);
    if (description == null) return null;

    return _initializeDescription(description, profile);
  }

  /// Starts the camera selected by name. If the list changed, preserves the
  /// current controller and returns null.
  Future<CameraController?> selectCamera(
    String name, {
    RecordingProfile? recordingProfile,
  }) async {
    if (_disposeRequested) return null;
    final description = cameraNamed(name);
    if (description == null) return null;
    final profile = recordingProfile ?? _recordingProfile;
    if (isRecording) return null;
    if (selectedCamera == description && isInitialized) {
      if (profile == _recordingProfile) return _controller;
      final applied = await applyRecordingProfile(profile);
      return applied ? _controller : null;
    }
    return _initializeDescription(description, profile);
  }

  /// Switches to the next camera in the list. This also exposes external webcams
  /// and Continuity Camera devices on desktop.
  Future<CameraController?> switchCamera({
    RecordingProfile? recordingProfile,
  }) async {
    if (_disposeRequested || _cameras.length < 2) return _controller;
    final current = _selectedCamera ?? _controller?.description;
    final currentIndex = current == null ? -1 : _cameras.indexOf(current);
    final nextIndex = currentIndex < 0
        ? 0
        : (currentIndex + 1) % _cameras.length;
    return selectCamera(
      _cameras[nextIndex].name,
      recordingProfile: recordingProfile,
    );
  }

  Future<CameraController?> _initializeDescription(
    CameraDescription description,
    RecordingProfile recordingProfile,
  ) async {
    return _enqueue(
      () => _initializeDescriptionInQueue(description, recordingProfile),
    );
  }

  Future<CameraController?> _initializeDescriptionInQueue(
    CameraDescription description,
    RecordingProfile recordingProfile,
  ) async {
    // Guards belong inside the queue: a start may have won after enqueueing.
    if (_disposeRequested || isRecording) return null;
    final previous = _controller;
    final previousDescription = selectedCamera;
    final previousProfile = _recordingProfile;
    final canRecover = previous != null && previous.value.isInitialized;

    // CameraX and some physical-camera backends reject two active controllers
    // for the same device. Fully release the old controller first; on failure,
    // restore the old description and profile.
    await _releaseCurrentController();

    try {
      final controller = await _createInitializedController(
        description,
        recordingProfile,
      );
      _controller = controller;
      _selectedCamera = description;
      _recordingProfile = recordingProfile;
      return controller;
    } catch (applyError, applyStackTrace) {
      if (!canRecover || previousDescription == null || _disposeRequested) {
        Error.throwWithStackTrace(applyError, applyStackTrace);
      }
      try {
        final recovered = await _createInitializedController(
          previousDescription,
          previousProfile,
        );
        _controller = recovered;
        _selectedCamera = previousDescription;
        _recordingProfile = previousProfile;
      } catch (recoveryError, recoveryStackTrace) {
        Error.throwWithStackTrace(
          CameraControllerRecoveryException(
            applyError: applyError,
            recoveryError: recoveryError,
          ),
          recoveryStackTrace,
        );
      }
      Error.throwWithStackTrace(applyError, applyStackTrace);
    }
  }

  Future<CameraController> _createInitializedController(
    CameraDescription description,
    RecordingProfile recordingProfile,
  ) async {
    _focusLockUnavailable = false;
    if (!supportsQualitySelection) {
      final factory = _controllerFactory;
      CameraController? controller;
      try {
        if (factory != null) {
          controller = factory(
            description: description,
            resolutionPreset: resolutionPresetFor(recordingProfile.quality),
            enableAudio: recordingProfile.recordAudio,
          );
          await controller.initialize();
        } else {
          controller = await _gateway.createInitializedController(
            description: description,
            preset: ResolutionPreset.max,
            enableAudio: recordingProfile.recordAudio,
            videoCodec: recordingProfile.videoCodec,
          );
        }
        if (_capabilities.usesDesktopCameraBackend) {
          await _gateway.setMirror(controller, false);
        }
        if (_videoStabilizationEnabled) {
          await _applyVideoStabilization(controller, enabled: true);
        }
        await _applyOrientationLock(
          controller,
          locked: recordingProfile.lockOrientation,
        );
        await _loadManualControls(controller);
        _appliedProfile = null;
        return controller;
      } catch (_) {
        if (controller != null) await _disposeBestEffort(controller);
        rethrow;
      }
    }

    final capabilities = await _gateway.capabilities(description.name);
    final candidates = capabilities.candidates(recordingProfile);
    if (candidates.isEmpty) {
      throw CameraException(
        'unsupportedRecordingProfile',
        'No supported recording profile.',
      );
    }
    Object? lastError;
    for (var index = 0; index < candidates.length; index++) {
      if (_disposeRequested) {
        throw CameraException('disposed', 'Camera was disposed.');
      }
      final candidate = candidates[index];
      final selectedCodec = candidate.supportsCodec(recordingProfile.videoCodec)
          ? recordingProfile.videoCodec
          : RecordingVideoCodec.h264;
      final effectiveProfile = recordingProfile.copyWith(
        videoCodec: selectedCodec,
      );
      CameraController? controller;
      try {
        controller = await _gateway.createInitializedController(
          description: description,
          preset: presetForFormat(candidate),
          enableAudio: recordingProfile.recordAudio,
          videoCodec: selectedCodec,
          fps: candidate.fps,
          videoBitrate: RecordingStorageEstimate.requestedVideoBitrate(
            effectiveProfile,
            candidate,
          ),
          audioBitrate: RecordingStorageEstimate.requestedAudioBitrate(
            recordingProfile,
          ),
        );
        if (_capabilities.usesDesktopCameraBackend) {
          await _gateway.setMirror(controller, false);
        }
        final actual = await _gateway.applied(controller.cameraId);
        final format = RecordingVideoFormat.tryParse(actual);
        if (format == null ||
            format != candidate ||
            !format.supportsCodec(effectiveProfile.videoCodec)) {
          throw CameraException(
            'unsupportedRecordingProfile',
            'Applied format differs from request.',
          );
        }
        final stabilization = await _applyVideoStabilization(
          controller,
          enabled: _videoStabilizationEnabled,
        );
        await _applyOrientationLock(
          controller,
          locked: recordingProfile.lockOrientation,
        );
        await _loadManualControls(controller);
        final isFallback =
            index > 0 ||
            format.fps != recordingProfile.fps ||
            (recordingProfile.resolution != RecordingResolution.automatic &&
                format.shortSide != recordingProfile.resolution.height) ||
            effectiveProfile.videoCodec != recordingProfile.videoCodec ||
            format.shortSide < 720;
        _recordingCapabilities = capabilities;
        _appliedProfile = AppliedRecordingProfile(
          requested: recordingProfile,
          format: format,
          cameraName: description.name,
          lensDirection: description.lensDirection.name,
          fallbackReason: isFallback
              ? (index > 0 ? 'configurationRejected' : 'unsupportedProfile')
              : null,
          stabilizationEnabled: _videoStabilizationEnabled && stabilization,
        );
        return controller;
      } catch (error) {
        if (controller != null) await _disposeBestEffort(controller);
        if (!_isUnsupportedConfiguration(error)) rethrow;
        lastError = error;
      }
    }
    throw lastError ??
        CameraException(
          'unsupportedRecordingProfile',
          'No profile could be configured.',
        );
  }

  Future<void> _disposeBestEffort(CameraController controller) async {
    try {
      await _gateway.dispose(controller);
    } catch (_) {}
  }

  static bool _isUnsupportedConfiguration(Object error) {
    final code = switch (error) {
      CameraException e => e.code,
      PlatformException e => e.code,
      _ => '',
    };
    return const {
      'unsupportedRecordingProfile',
      'unsupported_profile',
      'configurationFailed',
      'cameraConfiguration',
      'cameraNotSupported',
      'UnsupportedOperationException',
      'IllegalArgumentException',
    }.contains(code);
  }

  static ResolutionPreset presetForFormat(RecordingVideoFormat format) =>
      switch (format.shortSide) {
        >= 2160 => ResolutionPreset.ultraHigh,
        >= 1080 => ResolutionPreset.veryHigh,
        >= 720 => ResolutionPreset.high,
        _ => ResolutionPreset.medium,
      };

  Future<void> _loadManualControls(CameraController controller) async {
    try {
      final values = await Future.wait<double>([
        controller.getMinZoomLevel(),
        controller.getMaxZoomLevel(),
        controller.getMinExposureOffset(),
        controller.getMaxExposureOffset(),
        controller.getExposureOffsetStepSize(),
      ]);
      _minimumZoomLevel = values[0];
      _maximumZoomLevel = values[1];
      _zoomLevel = 1.clamp(_minimumZoomLevel, _maximumZoomLevel).toDouble();
      _minimumExposureOffset = values[2];
      _maximumExposureOffset = values[3];
      _exposureOffsetStepSize = values[4];
      _exposureOffset = 0
          .clamp(_minimumExposureOffset, _maximumExposureOffset)
          .toDouble();
    } catch (_) {
      _minimumZoomLevel = 1;
      _maximumZoomLevel = 1;
      _zoomLevel = 1;
      _minimumExposureOffset = 0;
      _maximumExposureOffset = 0;
      _exposureOffsetStepSize = 0;
      _exposureOffset = 0;
    }
  }

  Future<void> _applyOrientationLock(
    CameraController controller, {
    required bool locked,
  }) async {
    try {
      if (locked) {
        await controller.lockCaptureOrientation();
      } else if (controller.value.isCaptureOrientationLocked) {
        await controller.unlockCaptureOrientation();
      }
    } catch (_) {
      // Orientation locking is optional on cameras without orientation data.
      // A rejected lock must not make the preview unusable.
    }
  }

  Future<bool> setZoomLevel(double value) {
    if (_disposeRequested) return Future<bool>.value(false);
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return false;
      final clamped = value
          .clamp(_minimumZoomLevel, _maximumZoomLevel)
          .toDouble();
      try {
        await controller.setZoomLevel(clamped);
        _zoomLevel = clamped;
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  Future<bool> setExposureOffset(double value) {
    if (_disposeRequested) return Future<bool>.value(false);
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return false;
      final clamped = value
          .clamp(_minimumExposureOffset, _maximumExposureOffset)
          .toDouble();
      try {
        _exposureOffset = await controller.setExposureOffset(clamped);
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  /// Applies a recording profile only when recording is inactive. An initialized
  /// controller restarts for new audio or preset settings; while recording this
  /// returns `false` and leaves the current recording untouched.
  Future<bool> applyRecordingProfile(RecordingProfile recordingProfile) {
    if (_disposeRequested) return Future<bool>.value(false);

    return _enqueue(() async {
      if (_disposeRequested || isRecording) return false;

      final description = selectedCamera;
      if (description == null || !isInitialized) {
        _recordingProfile = recordingProfile;
        return true;
      }

      if (recordingProfile == _recordingProfile) return true;
      return await _initializeDescriptionInQueue(
            description,
            recordingProfile,
          ) !=
          null;
    });
  }

  /// Converts quality intent to a portable `ResolutionPreset` target. This
  /// mapping does not guarantee an exact device resolution or FPS.
  static ResolutionPreset resolutionPresetFor(RecordingQualityIntent quality) {
    return switch (quality) {
      RecordingQualityIntent.automatic => ResolutionPreset.max,
      RecordingQualityIntent.high => ResolutionPreset.high,
      RecordingQualityIntent.balanced => ResolutionPreset.medium,
      RecordingQualityIntent.compact => ResolutionPreset.low,
    };
  }

  /// Remembers the preference even without a camera, applying the same intent
  /// to the next initialized or switched controller. Unsupported stabilization
  /// does not disrupt recording.
  Future<bool> setVideoStabilizationEnabled(bool enabled) {
    if (_disposeRequested) return Future<bool>.value(false);
    return _enqueue(() async {
      _videoStabilizationEnabled = enabled;
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return true;
      if (controller.value.isRecordingVideo) return true;
      final applied = await _applyVideoStabilization(
        controller,
        enabled: enabled,
      );
      final profile = _appliedProfile;
      if (profile != null) {
        _appliedProfile = AppliedRecordingProfile(
          requested: profile.requested,
          format: profile.format,
          cameraName: profile.cameraName,
          lensDirection: profile.lensDirection,
          fallbackReason: profile.fallbackReason,
          stabilizationEnabled: enabled && applied,
        );
      }
      return applied;
    });
  }

  Future<bool> _applyVideoStabilization(
    CameraController controller, {
    required bool enabled,
  }) async {
    if (!_capabilities.supportsVideoStabilization) return false;
    try {
      final supported = await controller.getSupportedVideoStabilizationModes();
      if (enabled &&
          !supported.any((mode) => mode != VideoStabilizationMode.off)) {
        return false;
      }
      final mode = !enabled
          ? VideoStabilizationMode.off
          : supported.contains(VideoStabilizationMode.level1)
          ? VideoStabilizationMode.level1
          : supported.firstWhere(
              (value) => value != VideoStabilizationMode.off,
            );
      await controller.setVideoStabilizationMode(mode, allowFallback: false);
      if (supportsQualitySelection && enabled) {
        final applied = await _gateway.applied(controller.cameraId);
        return applied['stabilizationEnabled'] == true;
      }
      return true;
    } catch (_) {
      // Some camera/OS pairs advertise the API but reject it at runtime.
      // Stabilization is optional, so preserve camera and recording operation.
      return false;
    }
  }

  /// Applies autofocus and autoexposure to a normalized point selected in the
  /// preview. When locking is enabled, fixes both values after a short metering delay.
  Future<bool> focusAndExposeAt(Offset point, {required bool lockAfterFocus}) {
    if (_disposeRequested || !_capabilities.supportsFocusAndExposureControls) {
      return Future<bool>.value(false);
    }
    final normalized = Offset(
      point.dx.clamp(0.0, 1.0).toDouble(),
      point.dy.clamp(0.0, 1.0).toDouble(),
    );
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return false;
      if (controller.value.isRecordingVideo) return false;

      final focusModeApplied = await _tryCameraAction(
        () => controller.setFocusMode(FocusMode.auto),
      );
      final exposureModeApplied = await _tryCameraAction(
        () => controller.setExposureMode(ExposureMode.auto),
      );
      final focusPointApplied = await _tryCameraAction(
        () => controller.setFocusPoint(normalized),
      );
      final exposurePointApplied = await _tryCameraAction(
        () => controller.setExposurePoint(normalized),
      );
      final applied =
          focusModeApplied ||
          exposureModeApplied ||
          focusPointApplied ||
          exposurePointApplied;
      if (!applied || !lockAfterFocus) return applied;

      if (!await _settleForLock(controller)) return false;
      return _lockFocusAndExposure(controller);
    });
  }

  /// Locks current auto metering immediately before recording; returns to
  /// continuous autofocus and autoexposure when the user disables the preference.
  Future<bool> setFocusAndExposureLocked(bool locked) {
    if (_disposeRequested || !_capabilities.supportsFocusAndExposureControls) {
      return Future<bool>.value(false);
    }
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return false;
      if (controller.value.isRecordingVideo) return false;
      if (locked) {
        if (!await _settleForLock(controller)) return false;
        return _lockFocusAndExposure(controller);
      }
      _focusLockUnavailable = false;
      final focusApplied = await _tryCameraAction(
        () =>
            controller.setFocusMode(locked ? FocusMode.locked : FocusMode.auto),
      );
      final exposureApplied = await _tryCameraAction(
        () => controller.setExposureMode(
          locked ? ExposureMode.locked : ExposureMode.auto,
        ),
      );
      return focusApplied || exposureApplied;
    });
  }

  Future<bool> _lockFocusAndExposure(CameraController controller) async {
    final focusLocked = await _tryCameraAction(
      () => controller.setFocusMode(FocusMode.locked),
    );
    final exposureLocked = await _tryCameraAction(
      () => controller.setExposureMode(ExposureMode.locked),
    );
    final locked = focusLocked && exposureLocked;
    _focusLockUnavailable = !locked;
    if (!locked) {
      // A partial lock must not look like a successful joint lock.
      await _tryCameraAction(() => controller.setFocusMode(FocusMode.auto));
      await _tryCameraAction(
        () => controller.setExposureMode(ExposureMode.auto),
      );
    }
    return locked;
  }

  Future<bool> _settleForLock(CameraController controller) async {
    if (!supportsQualitySelection) {
      if (focusSettleDelay > Duration.zero) {
        await Future<void>.delayed(focusSettleDelay);
      }
      return true;
    }
    bool converged;
    try {
      converged = await _gateway
          .waitForFocus(controller.cameraId)
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {
      converged = false;
    }
    if (!converged) {
      _focusLockUnavailable = true;
      await _tryCameraAction(() => controller.setFocusMode(FocusMode.auto));
      await _tryCameraAction(
        () => controller.setExposureMode(ExposureMode.auto),
      );
    }
    return converged;
  }

  static Future<bool> _tryCameraAction(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startRecording() async {
    if (_disposeRequested) return false;
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return false;
      if (controller.value.isRecordingVideo) return false;
      if (_disposeRequested) return false;
      _captureProfile = _appliedProfile;
      await _gateway.start(controller);
      return controller.value.isRecordingVideo;
    });
  }

  /// Pauses recording; a subsequent [resumeRecording] continues the same file,
  /// joining segments into one video without an additional merge step.
  Future<void> pauseRecording() async {
    if (_disposeRequested || !_capabilities.supportsRecordingPause) return;
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isRecordingVideo) return;
      if (controller.value.isRecordingPaused) return;
      await _gateway.pause(controller);
    });
  }

  Future<void> resumeRecording() async {
    if (_disposeRequested || !_capabilities.supportsRecordingPause) return;
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isRecordingVideo) return;
      if (!controller.value.isRecordingPaused) return;
      await _gateway.resume(controller);
    });
  }

  /// Stops recording and returns the temporary file; saving to the gallery is the caller's responsibility.
  Future<XFile?> stopRecording() async {
    if (_disposeRequested) return null;
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isRecordingVideo) return null;
      return _gateway.stop(controller);
    });
  }

  /// Finalize once, then inspect the original file without risking its ownership.
  Future<RecordingResult?> finishRecording() {
    return _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isRecordingVideo) return null;
      final capture = _captureProfile;
      final file = await _gateway.stop(controller);
      RecordedMediaMetadata? metadata;
      try {
        metadata = await _gateway
            .inspect(file.path)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        /* The valid original remains available for Save/Discard. */
      }
      return RecordingResult(
        file: file,
        mediaMetadata: _withCaptureContext(metadata, capture),
      );
    });
  }

  static RecordedMediaMetadata? _withCaptureContext(
    RecordedMediaMetadata? metadata,
    AppliedRecordingProfile? capture,
  ) {
    if (capture == null) return metadata;
    return (metadata ?? const RecordedMediaMetadata()).copyWith(
      cameraName: capture.cameraName,
      lensDirection: capture.lensDirection,
      configuredWidth: capture.format.width,
      configuredHeight: capture.format.height,
      configuredFps: capture.format.fps,
      fallbackReason: _outputDiffers(metadata, capture.format)
          ? 'encodedMismatch'
          : capture.fallbackReason,
    );
  }

  static bool _outputDiffers(
    RecordedMediaMetadata? metadata,
    RecordingVideoFormat format,
  ) {
    final width = metadata?.width;
    final height = metadata?.height;
    if (width != null &&
        height != null &&
        !((width == format.width && height == format.height) ||
            (height == format.width && width == format.height))) {
      return true;
    }
    final fps = metadata?.fps;
    return fps != null && (fps - format.fps).abs() > 1;
  }

  /// Releases the controller when the app enters background; the service can be
  /// reused later through [initialize].
  ///
  /// An active (or paused) recording is stopped and finalized first, and its
  /// file is delivered through [onRecordingInterrupted] instead of being
  /// dropped. A failed stop does not prevent the controller from being
  /// released.
  Future<void> release() async {
    if (_disposeRequested) return;
    return _enqueue(_releaseCurrentController);
  }

  Future<void> _releaseCurrentController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    if (controller.value.isRecordingVideo) {
      final capture = _captureProfile;
      XFile? file;
      try {
        file = await _gateway.stop(controller);
      } catch (_) {
        // A failed stop has no finalized file to hand over; release anyway.
      }
      // Deliver before disposing so a dispose failure cannot lose the file.
      if (file != null && !_interruptedRecordings.isClosed) {
        _interruptedRecordings.add(
          RecordingResult(
            file: file,
            mediaMetadata: _withCaptureContext(null, capture),
          ),
        );
      }
    }
    await _gateway.dispose(controller);
  }

  /// Permanently releases the camera. Later calls return the same future.
  ///
  /// Like [release], an active recording is finalized and delivered through
  /// [onRecordingInterrupted] before that stream closes.
  Future<void> dispose() {
    _disposeRequested = true;
    return _disposeFuture ??= _enqueue(() async {
      try {
        await _releaseCurrentController();
      } finally {
        // Not awaited: a paused host subscription must not block disposal.
        unawaited(_interruptedRecordings.close());
      }
    });
  }
}
