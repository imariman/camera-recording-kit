import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera_recording/camera_recording.dart';

void main() {
  const frontCamera = CameraDescription(
    name: 'front',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 0,
  );
  const externalCamera = CameraDescription(
    name: 'external',
    lensDirection: CameraLensDirection.external,
    sensorOrientation: 0,
  );

  test('disables camera switching when only one camera is available', () {
    final service = CameraService(const [
      frontCamera,
    ], capabilities: DefaultCameraPlatformCapabilities.macos);

    expect(service.hasCameras, isTrue);
    expect(service.canSwitchCamera, isFalse);
  });

  test('enables switching when multiple cameras, including an external camera, are available', () {
    final service = CameraService(const [
      frontCamera,
      externalCamera,
    ], capabilities: DefaultCameraPlatformCapabilities.macos);

    expect(service.canSwitchCamera, isTrue);
  });

  test('resolves a persisted camera name from the available camera list', () {
    final service = CameraService(const [
      frontCamera,
      externalCamera,
    ], capabilities: DefaultCameraPlatformCapabilities.macos);

    expect(service.cameraNamed('external'), externalCamera);
    expect(service.cameraNamed('missing'), isNull);
  });

  test('maps quality intents to portable presets', () {
    expect(
      CameraService.resolutionPresetFor(RecordingQualityIntent.automatic),
      ResolutionPreset.max,
    );
    expect(
      CameraService.resolutionPresetFor(RecordingQualityIntent.high),
      ResolutionPreset.high,
    );
    expect(
      CameraService.resolutionPresetFor(RecordingQualityIntent.balanced),
      ResolutionPreset.medium,
    );
    expect(
      CameraService.resolutionPresetFor(RecordingQualityIntent.compact),
      ResolutionPreset.low,
    );
  });

  test(
    'initializes the controller without audio when the profile disables sound',
    () async {
      final factory = TestCameraControllerFactory();
      final service = CameraService(
        const [frontCamera],
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        controllerFactory: factory.create,
      );

      final controller = await service.initialize(
        front: true,
        recordingProfile: const RecordingProfile(
          recordAudio: false,
          quality: RecordingQualityIntent.compact,
        ),
      );

      expect(controller, isNotNull);
      expect(controller!.enableAudio, isFalse);
      expect(controller.resolutionPreset, ResolutionPreset.low);
      expect(service.recordingProfile.recordAudio, isFalse);
    },
  );

  test(
    'preserves the existing automatic audio behavior without a profile',
    () async {
      final factory = TestCameraControllerFactory();
      final service = CameraService(
        const [frontCamera],
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        controllerFactory: factory.create,
      );

      final controller = await service.initialize(front: true);

      expect(controller!.enableAudio, isTrue);
      expect(controller.resolutionPreset, ResolutionPreset.max);
    },
  );

  test('rejects profile changes while recording', () async {
    final factory = TestCameraControllerFactory();
    final service = CameraService(
      const [frontCamera],
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      controllerFactory: factory.create,
    );
    await service.initialize(front: true);
    final initialController = service.controller;
    await service.startRecording();

    final applied = await service.applyRecordingProfile(
      const RecordingProfile(recordAudio: false),
    );

    expect(applied, isFalse);
    expect(service.controller, same(initialController));
    expect(service.recordingProfile, const RecordingProfile());
    expect(factory.createdControllers, hasLength(1));
  });

  test(
    'rejects a different profile supplied during recording initialization',
    () async {
      final factory = TestCameraControllerFactory();
      final service = CameraService(
        const [frontCamera],
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        controllerFactory: factory.create,
      );
      await service.initialize(front: true);
      await service.startRecording();

      final controller = await service.initialize(
        front: true,
        recordingProfile: const RecordingProfile(recordAudio: false),
      );

      expect(controller, isNull);
      expect(service.recordingProfile, const RecordingProfile());
      expect(factory.createdControllers, hasLength(1));
    },
  );

  test('restarts the controller for an idle profile change', () async {
    final factory = TestCameraControllerFactory();
    final service = CameraService(
      const [frontCamera],
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      controllerFactory: factory.create,
    );
    await service.initialize(front: true);

    final applied = await service.applyRecordingProfile(
      const RecordingProfile(
        recordAudio: false,
        quality: RecordingQualityIntent.high,
      ),
    );

    expect(applied, isTrue);
    expect(factory.createdControllers, hasLength(2));
    expect(service.controller!.enableAudio, isFalse);
    expect(service.controller!.resolutionPreset, ResolutionPreset.high);
    expect(factory.maxActiveControllers, 1);
    expect(factory.simultaneousInitializationAttempts, 0);
  });

  test('restores the previous profile after a failed profile update', () async {
    final factory = TestCameraControllerFactory(
      failingInitializationIndices: const {2},
    );
    final service = CameraService(
      const [frontCamera],
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      controllerFactory: factory.create,
    );
    await service.initialize(front: true);
    final original = service.controller! as TestCameraController;

    await expectLater(
      service.applyRecordingProfile(const RecordingProfile(recordAudio: false)),
      throwsA(isA<CameraException>()),
    );

    final failedCandidate = factory.createdControllers[1];
    final recovered = factory.createdControllers[2];
    expect(service.controller, same(recovered));
    expect(service.isInitialized, isTrue);
    expect(service.recordingProfile, const RecordingProfile());
    expect(original.wasDisposed, isTrue);
    expect(failedCandidate.wasDisposed, isTrue);
    expect(recovered.enableAudio, isTrue);
    expect(factory.maxActiveControllers, 1);
    expect(factory.simultaneousInitializationAttempts, 0);
  });

  test(
    'returns an explicit recovery error when profile rollback also fails',
    () async {
      final factory = TestCameraControllerFactory(
        failingInitializationIndices: const {2, 3},
      );
      final service = CameraService(
        const [frontCamera],
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        controllerFactory: factory.create,
      );
      await service.initialize(front: true);

      await expectLater(
        service.applyRecordingProfile(
          const RecordingProfile(recordAudio: false),
        ),
        throwsA(isA<CameraControllerRecoveryException>()),
      );

      expect(service.controller, isNull);
      expect(service.isInitialized, isFalse);
      expect(service.recordingProfile, const RecordingProfile());
      expect(factory.activeControllers, 0);
      expect(factory.maxActiveControllers, 1);
      expect(factory.simultaneousInitializationAttempts, 0);
    },
  );

  test('focuses the tapped point and locks it after metering', () async {
    final factory = TestCameraControllerFactory();
    final service = CameraService(
      const [frontCamera],
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      controllerFactory: factory.create,
      focusSettleDelay: Duration.zero,
    );
    await service.initialize(front: true);

    final applied = await service.focusAndExposeAt(
      const Offset(1.4, -0.2),
      lockAfterFocus: true,
    );

    final controller = factory.createdControllers.single;
    expect(applied, isTrue);
    expect(controller.focusPoints, const [Offset(1, 0)]);
    expect(controller.exposurePoints, const [Offset(1, 0)]);
    expect(controller.focusModes, const [FocusMode.auto, FocusMode.locked]);
    expect(controller.exposureModes, const [
      ExposureMode.auto,
      ExposureMode.locked,
    ]);
  });

  test('returns to automatic focus and exposure after unlocking', () async {
    final factory = TestCameraControllerFactory();
    final service = CameraService(
      const [frontCamera],
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      controllerFactory: factory.create,
    );
    await service.initialize(front: true);

    final applied = await service.setFocusAndExposureLocked(false);

    final controller = factory.createdControllers.single;
    expect(applied, isTrue);
    expect(controller.focusModes, const [FocusMode.auto]);
    expect(controller.exposureModes, const [ExposureMode.auto]);
  });

  test(
    'applies stabilization enabled before initialization and turns it off on the live controller',
    () async {
      final factory = TestCameraControllerFactory();
      final service = CameraService(
        const [frontCamera],
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        controllerFactory: factory.create,
      );

      expect(await service.setVideoStabilizationEnabled(true), isTrue);
      await service.initialize(front: true);

      final controller = factory.createdControllers.single;
      expect(controller.videoStabilizationModes, const [
        VideoStabilizationMode.level1,
      ]);

      expect(await service.setVideoStabilizationEnabled(false), isTrue);
      expect(controller.videoStabilizationModes, const [
        VideoStabilizationMode.level1,
        VideoStabilizationMode.off,
      ]);
    },
  );
}

class TestCameraControllerFactory {
  TestCameraControllerFactory({this.failingInitializationIndices = const {}});

  final List<TestCameraController> createdControllers = [];
  final Set<int> failingInitializationIndices;
  int activeControllers = 0;
  int maxActiveControllers = 0;
  int simultaneousInitializationAttempts = 0;

  void didInitialize() {
    activeControllers++;
    if (activeControllers > maxActiveControllers) {
      maxActiveControllers = activeControllers;
    }
  }

  void didDispose() => activeControllers--;

  CameraController create({
    required CameraDescription description,
    required ResolutionPreset resolutionPreset,
    required bool enableAudio,
  }) {
    final controller = TestCameraController(
      description,
      resolutionPreset,
      enableAudio: enableAudio,
      owner: this,
      failInitialize: failingInitializationIndices.contains(
        createdControllers.length + 1,
      ),
    );
    createdControllers.add(controller);
    return controller;
  }
}

class TestCameraController extends CameraController {
  TestCameraController(
    super.description,
    super.resolutionPreset, {
    required super.enableAudio,
    required this.owner,
    required this.failInitialize,
  });

  final TestCameraControllerFactory owner;
  final bool failInitialize;
  bool wasDisposed = false;
  bool isActive = false;
  bool rejectFocusLock = false;
  bool rejectExposureLock = false;
  final List<FocusMode> focusModes = [];
  final List<ExposureMode> exposureModes = [];
  final List<Offset> focusPoints = [];
  final List<Offset> exposurePoints = [];
  final List<VideoStabilizationMode> videoStabilizationModes = [];
  final List<double> zoomLevels = [];
  final List<double> exposureOffsets = [];
  int orientationLockCalls = 0;
  int orientationUnlockCalls = 0;

  @override
  Future<void> initialize() async {
    if (owner.activeControllers > 0) {
      owner.simultaneousInitializationAttempts++;
      throw CameraException(
        'simultaneousActiveController',
        'Aynı fiziksel kamera için iki controller aktif olamaz.',
      );
    }
    if (failInitialize) {
      throw CameraException('testInitFailure', 'Controller başlatılamadı.');
    }
    owner.didInitialize();
    isActive = true;
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> dispose() async {
    wasDisposed = true;
    if (isActive) {
      isActive = false;
      owner.didDispose();
    }
    await super.dispose();
  }

  @override
  Future<void> startVideoRecording({
    onLatestImageAvailable? onAvailable,
    bool enablePersistentRecording = true,
  }) async {
    value = value.copyWith(isRecordingVideo: true);
  }

  @override
  Future<void> setFocusMode(FocusMode mode) async {
    if (mode == FocusMode.locked && rejectFocusLock) {
      throw CameraException('focusLockRejected', 'Focus lock was rejected.');
    }
    focusModes.add(mode);
  }

  @override
  Future<void> setExposureMode(ExposureMode mode) async {
    if (mode == ExposureMode.locked && rejectExposureLock) {
      throw CameraException(
        'exposureLockRejected',
        'Exposure lock was rejected.',
      );
    }
    exposureModes.add(mode);
  }

  @override
  Future<void> setFocusPoint(Offset? point) async {
    if (point != null) focusPoints.add(point);
  }

  @override
  Future<void> setExposurePoint(Offset? point) async {
    if (point != null) exposurePoints.add(point);
  }

  @override
  Future<Iterable<VideoStabilizationMode>>
  getSupportedVideoStabilizationModes() async => const [
    VideoStabilizationMode.off,
    VideoStabilizationMode.level1,
  ];

  @override
  Future<void> setVideoStabilizationMode(
    VideoStabilizationMode mode, {
    bool allowFallback = true,
  }) async {
    videoStabilizationModes.add(mode);
  }

  @override
  Future<double> getMinZoomLevel() async => 1;

  @override
  Future<double> getMaxZoomLevel() async => 4;

  @override
  Future<void> setZoomLevel(double zoom) async => zoomLevels.add(zoom);

  @override
  Future<double> getMinExposureOffset() async => -2;

  @override
  Future<double> getMaxExposureOffset() async => 2;

  @override
  Future<double> getExposureOffsetStepSize() async => 0.5;

  @override
  Future<double> setExposureOffset(double offset) async {
    exposureOffsets.add(offset);
    return offset;
  }

  @override
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {
    orientationLockCalls++;
    value = value.copyWith(
      lockedCaptureOrientation: Optional<DeviceOrientation>.of(
        orientation ?? value.deviceOrientation,
      ),
    );
  }

  @override
  Future<void> unlockCaptureOrientation() async {
    orientationUnlockCalls++;
    value = value.copyWith(
      lockedCaptureOrientation: const Optional<DeviceOrientation>.absent(),
    );
  }
}
