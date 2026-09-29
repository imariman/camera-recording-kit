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

  /// Whether formats are negotiated and verified by native readback.
  ///
  /// When false (a custom `controllerFactory`, or a host without a quality
  /// backend such as Windows or Linux), only [RecordingProfile.recordAudio],
  /// [RecordingProfile.lockOrientation], and [RecordingProfile.quality] are
  /// honored, [appliedProfile] stays null, and a profile with an explicit
  /// resolution, frame rate, bitrate, or codec is rejected with a
  /// [CameraException] coded `unsupportedRecordingProfile`.
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
  Future<RecordingResult?>? _disposeFuture;
  bool _disposeRequested = false;
  bool _videoStabilizationEnabled = false;

  /// A stabilization change requested during a recording, applied to the
  /// live controller once that recording stops.
  bool _stabilizationPending = false;
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

  /// Starts a camera and returns a controller ready for preview.
  ///
  /// The camera is chosen in this order:
  /// 1. [preferredName], when it names an available camera;
  /// 2. the camera selected earlier in this service's lifetime (by a previous
  ///    [initialize], [selectCamera], or [switchCamera]), so that
  ///    `release()` followed by `initialize()` resumes on the camera the user
  ///    switched to;
  /// 3. the first camera facing [front], or the first camera.
  ///
  /// [front] therefore only applies to the first selection. To change the
  /// camera later, pass [preferredName] or use [selectCamera]/[switchCamera].
  Future<CameraController?> initialize({
    required bool front,
    String preferredName = '',
    RecordingProfile? recordingProfile,
  }) async {
    if (_disposeRequested || isRecording) return null;
    return _enqueue(() async {
      final description =
          cameraNamed(preferredName) ?? selectedCamera ?? _select(front: front);
      if (description == null) return null;
      return _initializeDescriptionInQueue(
        description,
        recordingProfile ?? _recordingProfile,
      );
    });
  }

  /// Starts the camera selected by name. If the list changed, preserves the
  /// current controller and returns null.
  Future<CameraController?> selectCamera(
    String name, {
    RecordingProfile? recordingProfile,
  }) async {
    if (_disposeRequested) return null;
    final description = cameraNamed(name);
    if (description == null || isRecording) return null;
    return _enqueue(() => _selectInQueue(description, recordingProfile));
  }

  /// Switches to the next camera in the list. This also exposes external webcams
  /// and Continuity Camera devices on desktop.
  ///
  /// The next camera is resolved when the queued switch runs, so rapid
  /// repeated calls advance one camera each.
  Future<CameraController?> switchCamera({
    RecordingProfile? recordingProfile,
  }) async {
    if (_disposeRequested || _cameras.length < 2) return _controller;
    if (isRecording) return null;
    return _enqueue(() {
      final current = selectedCamera;
      final currentIndex = current == null ? -1 : _cameras.indexOf(current);
      final nextIndex = currentIndex < 0
          ? 0
          : (currentIndex + 1) % _cameras.length;
      return _selectInQueue(_cameras[nextIndex], recordingProfile);
    });
  }

  Future<CameraController?> _selectInQueue(
    CameraDescription description,
    RecordingProfile? recordingProfile,
  ) async {
    if (_disposeRequested || isRecording) return null;
    final profile = recordingProfile ?? _recordingProfile;
    if (selectedCamera == description &&
        isInitialized &&
        !_requiresRebuild(profile)) {
      _adoptProfile(profile);
      return _controller;
    }
    return _initializeDescriptionInQueue(description, profile);
  }

  /// Whether [next] needs a new controller on the current camera.
  ///
  /// [RecordingProfile.quality] has no effect on quality-selection backends,
  /// so a change to it alone does not tear down the preview there.
  bool _requiresRebuild(RecordingProfile next) {
    if (!supportsQualitySelection) return next != _recordingProfile;
    return next.copyWith(quality: _recordingProfile.quality) !=
        _recordingProfile;
  }

  /// Records [profile] as requested for the unchanged live configuration.
  void _adoptProfile(RecordingProfile profile) {
    _recordingProfile = profile;
    _appliedProfile = _appliedProfile?.copyWith(requested: profile);
  }

  /// Backends without quality selection cannot apply or verify an explicit
  /// resolution, frame rate, bitrate, or codec. Such a request is an error
  /// instead of being silently dropped.
  void _ensureLegacyProfileSupported(RecordingProfile profile) {
    if (supportsQualitySelection) return;
    if (profile.resolution == RecordingResolution.automatic &&
        profile.fps == 30 &&
        profile.bitratePreset == RecordingBitratePreset.automatic &&
        profile.videoCodec == RecordingVideoCodec.h264) {
      return;
    }
    throw CameraException(
      'unsupportedRecordingProfile',
      'This camera backend cannot apply an explicit resolution, frame rate, '
          'bitrate, or codec. Use RecordingProfile.quality instead.',
    );
  }

  Future<CameraController?> _initializeDescriptionInQueue(
    CameraDescription description,
    RecordingProfile recordingProfile,
  ) async {
    // Guards belong inside the queue: a start may have won after enqueueing.
    if (_disposeRequested || isRecording) return null;
    // Validate before tearing down a working preview.
    _ensureLegacyProfileSupported(recordingProfile);
    final previous = _controller;
    final previousDescription = selectedCamera;
    final previousProfile = _recordingProfile;
    final canRecover = previous != null && previous.value.isInitialized;

    // CameraX and some physical-camera backends reject two active controllers
    // for the same device. Fully release the old controller first; on failure,
    // restore the old description and profile.
    try {
      await _releaseCurrentController();
    } catch (_) {
      // The old controller is already detached from the service. A failed
      // dispose must not leave the service without a camera, so the new
      // controller (and, if needed, recovery) is still attempted.
    }

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
        // No camera is active: drop anything a partial attempt may have left.
        _resetControllerState();
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
    // Every new controller receives the current preference directly.
    _stabilizationPending = false;
    if (!supportsQualitySelection) {
      // Both legacy branches honor the same subset of the profile: audio,
      // orientation lock, and `quality` as a portable ResolutionPreset. The
      // rest was rejected by _ensureLegacyProfileSupported, and no applied
      // profile is reported because nothing can be read back.
      _ensureLegacyProfileSupported(recordingProfile);
      final factory = _controllerFactory;
      final preset = resolutionPresetFor(recordingProfile.quality);
      CameraController? controller;
      try {
        if (factory != null) {
          controller = factory(
            description: description,
            resolutionPreset: preset,
            enableAudio: recordingProfile.recordAudio,
          );
          await controller.initialize();
        } else {
          controller = await _gateway.createInitializedController(
            description: description,
            preset: preset,
            enableAudio: recordingProfile.recordAudio,
            videoCodec: RecordingVideoCodec.h264,
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
        // An explicit target (480p included) applied exactly is not a
        // fallback. Automatic accepts the best format of the lens, whatever
        // its size, so only its frame rate and codec are compared.
        final isFallback =
            index > 0 ||
            format.fps != recordingProfile.fps ||
            (recordingProfile.resolution != RecordingResolution.automatic &&
                format.shortSide != recordingProfile.resolution.height) ||
            effectiveProfile.videoCodec != recordingProfile.videoCodec;
        _recordingCapabilities = capabilities;
        _appliedProfile = AppliedRecordingProfile(
          requested: recordingProfile,
          format: format,
          cameraName: description.name,
          lensDirection: description.lensDirection.name,
          fallbackReason: isFallback
              ? (index > 0
                    ? RecordingFallbackReason.configurationRejected
                    : RecordingFallbackReason.unsupportedProfile)
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
      _resetManualControls();
    }
  }

  void _resetManualControls() {
    _minimumZoomLevel = 1;
    _maximumZoomLevel = 1;
    _zoomLevel = 1;
    _minimumExposureOffset = 0;
    _maximumExposureOffset = 0;
    _exposureOffsetStepSize = 0;
    _exposureOffset = 0;
  }

  /// Clears every fact that describes the active controller. Called whenever
  /// the controller is released, so a failed switch never reports the
  /// previous camera's format, capabilities, or control ranges.
  void _resetControllerState() {
    _appliedProfile = null;
    _recordingCapabilities = const RecordingCapabilities();
    _focusLockUnavailable = false;
    _resetManualControls();
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
  ///
  /// On quality-selection backends a change to [RecordingProfile.quality]
  /// alone is recorded without restarting the camera, because it has no
  /// effect there. Without quality selection an explicit resolution, frame
  /// rate, bitrate, or codec throws a [CameraException] with code
  /// `unsupportedRecordingProfile`.
  Future<bool> applyRecordingProfile(RecordingProfile recordingProfile) {
    if (_disposeRequested) return Future<bool>.value(false);

    return _enqueue(() async {
      if (_disposeRequested || isRecording) return false;
      _ensureLegacyProfileSupported(recordingProfile);

      final description = selectedCamera;
      if (description == null || !isInitialized) {
        _recordingProfile = recordingProfile;
        return true;
      }

      if (!_requiresRebuild(recordingProfile)) {
        _adoptProfile(recordingProfile);
        return true;
      }
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
  ///
  /// Returns true when the preference is stored without a camera, or when it
  /// was applied to the live controller. During a recording (including a
  /// paused one) the live stream is left untouched and this returns false;
  /// the preference is applied when that recording stops. [appliedProfile]
  /// reports stabilization only after native readback confirms it.
  Future<bool> setVideoStabilizationEnabled(bool enabled) {
    if (_disposeRequested) return Future<bool>.value(false);
    return _enqueue(() async {
      _videoStabilizationEnabled = enabled;
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        _stabilizationPending = false;
        return true;
      }
      if (controller.value.isRecordingVideo) {
        _stabilizationPending = true;
        return false;
      }
      return _applyStabilizationToLiveController(controller);
    });
  }

  Future<bool> _applyStabilizationToLiveController(
    CameraController controller,
  ) async {
    _stabilizationPending = false;
    final enabled = _videoStabilizationEnabled;
    final applied = await _applyVideoStabilization(
      controller,
      enabled: enabled,
    );
    _appliedProfile = _appliedProfile?.copyWith(
      stabilizationEnabled: enabled && applied,
    );
    return applied;
  }

  /// Applies a stabilization change deferred during the recording that just
  /// stopped. Must run inside the operation queue.
  Future<void> _applyPendingStabilization(CameraController controller) async {
    if (!_stabilizationPending || !identical(controller, _controller)) return;
    if (!controller.value.isInitialized || controller.value.isRecordingVideo) {
      return;
    }
    await _applyStabilizationToLiveController(controller);
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
      final file = await _gateway.stop(controller);
      await _applyPendingStabilization(controller);
      return file;
    });
  }

  /// Finalize once, then inspect the original file without risking its ownership.
  ///
  /// Only the stop is serialized with other camera operations. Inspection
  /// (up to 10 seconds) runs outside the queue and reads the finalized file,
  /// never the controller, so a following `release()` or `dispose()` (for
  /// example when the app moves to background) is not held behind it and
  /// finds no active recording to stop again.
  Future<RecordingResult?> finishRecording() async {
    final stopped = await _enqueue(() async {
      final controller = _controller;
      if (controller == null || !controller.value.isRecordingVideo) return null;
      final capture = _captureProfile;
      final file = await _gateway.stop(controller);
      await _applyPendingStabilization(controller);
      return (file: file, capture: capture);
    });
    if (stopped == null) return null;
    RecordedMediaMetadata? metadata;
    try {
      metadata = await _gateway
          .inspect(stopped.file.path)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      /* The valid original remains available for Save/Discard. */
    }
    return RecordingResult(
      file: stopped.file,
      mediaMetadata: _withCaptureContext(metadata, stopped.capture),
    );
  }

  static RecordedMediaMetadata? _withCaptureContext(
    RecordedMediaMetadata? metadata,
    AppliedRecordingProfile? capture,
  ) {
    if (capture == null) return metadata;
    // A configuration-time reason explains the output better than the
    // resulting mismatch, so it is never replaced by encodedMismatch.
    final fallbackReason =
        capture.fallbackReason ??
        (_outputDiffers(metadata, capture.format)
            ? RecordingFallbackReason.encodedMismatch
            : null);
    return (metadata ?? const RecordedMediaMetadata()).copyWith(
      cameraName: capture.cameraName,
      lensDirection: capture.lensDirection,
      configuredWidth: capture.format.width,
      configuredHeight: capture.format.height,
      configuredFps: capture.format.fps,
      fallbackReason: fallbackReason,
    );
  }

  /// Relative tolerance for a `measured` frame rate.
  ///
  /// A measured rate is frames divided by duration, so it includes start/stop
  /// edge frames, dropped frames under thermal load, and longer exposures in
  /// low light; 28-29 fps is normal for an exact 30 fps configuration. A real
  /// configuration mismatch is a different capture mode (30 vs 60, or 24/25
  /// vs 30), which is at least a 16% difference, so 10% ignores cadence
  /// jitter while still flagging a wrong mode. `nominal` rates come from the
  /// container header and keep the strict one-frame tolerance.
  static const double _measuredFpsTolerance = 0.1;

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
    if (fps == null) return false;
    final tolerance = metadata?.fpsSource == 'measured'
        ? format.fps * _measuredFpsTolerance
        : 1.0;
    return (fps - format.fps).abs() > tolerance;
  }

  /// Releases the controller when the app enters background; the service can be
  /// reused later through [initialize].
  ///
  /// If a recording is active (or paused) it is stopped and finalized first and
  /// its file is returned, so the host can offer Save/Discard instead of losing
  /// it. The result carries the configured capture context but no inspection,
  /// which keeps release fast while the app is backgrounding. Returns null when
  /// nothing was recording, and the service never deletes the file. A failed
  /// stop does not prevent the controller from being released.
  Future<RecordingResult?> release() async {
    if (_disposeRequested) return null;
    return _enqueue(_releaseCurrentController);
  }

  Future<RecordingResult?> _releaseCurrentController() async {
    final controller = _controller;
    _controller = null;
    _resetControllerState();
    if (controller == null) return null;
    RecordingResult? interrupted;
    if (controller.value.isRecordingVideo) {
      final capture = _captureProfile;
      try {
        final file = await _gateway.stop(controller);
        interrupted = RecordingResult(
          file: file,
          mediaMetadata: _withCaptureContext(null, capture),
        );
      } catch (_) {
        // A failed stop has no finalized file to hand over; release anyway.
      }
    }
    try {
      await _gateway.dispose(controller);
    } catch (_) {
      // The finalized file must still reach the caller when disposal fails.
      if (interrupted != null) return interrupted;
      rethrow;
    }
    return interrupted;
  }

  /// Permanently releases the camera. Later calls return the same future.
  ///
  /// Like [release], an active recording is finalized and its file returned
  /// instead of being dropped.
  Future<RecordingResult?> dispose() {
    _disposeRequested = true;
    return _disposeFuture ??= _enqueue(_releaseCurrentController);
  }
}
