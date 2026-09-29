import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera_recording/camera_recording.dart';

import 'camera_service_test.dart' show TestCameraControllerFactory;

const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 90,
);
const back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const macInternal = CameraDescription(
  name: 'internal',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 90,
);
const macExternal = CameraDescription(
  name: 'external',
  lensDirection: CameraLensDirection.external,
  sensorOrientation: 90,
);
const hd30 = RecordingVideoFormat(width: 1280, height: 720, fps: 30);
const sd30 = RecordingVideoFormat(width: 640, height: 480, fps: 30);
const fhd30 = RecordingVideoFormat(
  width: 1920,
  height: 1080,
  fps: 30,
  codecs: {RecordingVideoCodec.h264, RecordingVideoCodec.hevc},
);
const fhd60 = RecordingVideoFormat(width: 1920, height: 1080, fps: 60);
const uhd30 = RecordingVideoFormat(width: 3840, height: 2160, fps: 30);
const uhd60 = RecordingVideoFormat(width: 3840, height: 2160, fps: 60);
const fhd30Hevc = RecordingVideoFormat(
  width: 1920,
  height: 1080,
  fps: 30,
  codecs: {RecordingVideoCodec.hevc},
);
const fhd30Narrow = RecordingVideoFormat(width: 1440, height: 1080, fps: 30);

/// `RecordingVideoFormat.==` identifies the capture mode only, so format
/// assertions that care about the codec must use this matcher.
Matcher withCodecs(
  RecordingVideoFormat format,
  Set<RecordingVideoCodec> codecs,
) => isA<RecordingVideoFormat>()
    .having((value) => value, 'capture mode', format)
    .having((value) => value.width, 'width', format.width)
    .having((value) => value.height, 'height', format.height)
    .having((value) => value.codecs, 'codecs', codecs);

Matcher h264(RecordingVideoFormat format) =>
    withCodecs(format, {RecordingVideoCodec.h264});
Matcher hevc(RecordingVideoFormat format) =>
    withCodecs(format, {RecordingVideoCodec.hevc});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'resolution takes precedence over frame rate, without upward fallbacks',
    () {
      const caps = RecordingCapabilities(
        profiles: [hd30, fhd30, uhd30, fhd60, uhd60],
      );
      expect(
        caps.candidates(
          const RecordingProfile(
            resolution: RecordingResolution.ultraHd,
            fps: 60,
          ),
        ),
        [h264(uhd60), h264(uhd30), h264(fhd60), h264(fhd30), h264(hd30)],
      );
      expect(
        caps.candidates(
          const RecordingProfile(resolution: RecordingResolution.fullHd),
        ),
        [h264(fhd30), h264(hd30)],
      );
      expect(caps.candidates(const RecordingProfile()), [
        h264(uhd30),
        h264(fhd30),
        h264(hd30),
      ]);
    },
  );

  test('capability decoder removes invalid entries and duplicates', () {
    final caps = RecordingCapabilities.fromJson({
      'profiles': [
        {'width': 1920, 'height': 1080, 'fps': 30},
        {'width': 1080, 'height': 1920, 'fps': 30},
        {'width': -1, 'height': 1080, 'fps': 30},
        {'width': 3840, 'height': 2160, 'fps': double.nan},
        {'width': 1920, 'height': 1080, 'fps': 120},
        null,
      ],
    });
    // Entries without codec information default to H.264 only.
    expect(caps.profiles, [h264(fhd30)]);
    expect(caps.resolutions, [
      RecordingResolution.automatic,
      RecordingResolution.fullHd,
    ]);
    expect(caps.frameRates(RecordingResolution.fullHd), [30]);
    expect(caps.frameRates(RecordingResolution.ultraHd), isEmpty);
  });

  test('capabilities expose 480p and merge codec support per exact format', () {
    final caps = RecordingCapabilities.fromJson({
      'profiles': [
        {
          'width': 640,
          'height': 480,
          'fps': 30,
          'codecs': ['h264'],
        },
        {
          'width': 480,
          'height': 640,
          'fps': 30,
          'codecs': ['hevc'],
        },
      ],
    });

    expect(caps.profiles, hasLength(1));
    expect(caps.resolutions, contains(RecordingResolution.standardDefinition));
    expect(caps.profiles.single.codecs, {
      RecordingVideoCodec.h264,
      RecordingVideoCodec.hevc,
    });
    final candidates = caps.candidates(
      const RecordingProfile(
        resolution: RecordingResolution.standardDefinition,
        videoCodec: RecordingVideoCodec.hevc,
      ),
    );
    expect(candidates, hasLength(2));
    expect(candidates.map((candidate) => candidate.codecs.single), [
      RecordingVideoCodec.hevc,
      RecordingVideoCodec.h264,
    ]);
  });

  test('resolution remains ahead of preferred codec during fallback', () {
    const caps = RecordingCapabilities(profiles: [fhd30Hevc, uhd30]);

    expect(
      caps.candidates(
        const RecordingProfile(
          resolution: RecordingResolution.ultraHd,
          videoCodec: RecordingVideoCodec.hevc,
        ),
      ),
      [h264(uhd30), hevc(fhd30Hevc)],
    );
  });

  test('front fallback preserves 4K request and rear restores it', () async {
    final gateway = QualityFakeGateway();
    final service = CameraService(
      [front, back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);
    const request = RecordingProfile(
      resolution: RecordingResolution.ultraHd,
      fps: 60,
    );
    await service.initialize(front: true, recordingProfile: request);
    expect(service.recordingProfile, request);
    expect(service.appliedProfile?.format, h264(fhd30));
    expect(service.appliedProfile?.fallbackReason, 'unsupportedProfile');
    expect(
      service.recordingCapabilities.resolutions,
      isNot(contains(RecordingResolution.ultraHd)),
    );
    await service.switchCamera(recordingProfile: request);
    expect(service.appliedProfile?.format, h264(uhd60));
    expect(service.appliedProfile?.fallbackReason, isNull);
    expect(
      service.recordingCapabilities.resolutions,
      contains(RecordingResolution.ultraHd),
    );
    await service.switchCamera(recordingProfile: request);
    expect(service.appliedProfile?.format, h264(fhd30));
    expect(service.recordingProfile, request);
    expect(gateway.factory.maxActiveControllers, 1);
  });

  test(
    'macOS internal 1080p fallback restores the remembered 4K intent externally',
    () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        const [macInternal, macExternal],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.macos,
      );
      addTearDown(service.dispose);
      const request = RecordingProfile(
        resolution: RecordingResolution.ultraHd,
        fps: 60,
      );

      await service.initialize(front: true, recordingProfile: request);

      expect(service.recordingProfile, request);
      expect(service.appliedProfile?.format, h264(fhd60));
      expect(service.appliedProfile?.fallbackReason, 'unsupportedProfile');
      expect(
        service.recordingCapabilities.resolutions,
        isNot(contains(RecordingResolution.ultraHd)),
      );

      await service.switchCamera(recordingProfile: request);

      expect(service.recordingProfile, request);
      expect(service.appliedProfile?.format, h264(uhd60));
      expect(service.appliedProfile?.fallbackReason, isNull);
      expect(
        service.recordingCapabilities.resolutions,
        contains(RecordingResolution.ultraHd),
      );
    },
  );

  for (final supportsQualitySelection in [false, true]) {
    test(
      'macOS keeps recorded output unmirrored after '
      '${supportsQualitySelection ? 'quality' : 'legacy'} reconfiguration',
      () async {
        final gateway = QualityFakeGateway()
          ..qualitySelection = supportsQualitySelection;
        final service = CameraService(
          const [macInternal],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.macos,
        );
        addTearDown(service.dispose);

        // The legacy path honors audio but not explicit formats.
        await service.initialize(
          front: true,
          recordingProfile: supportsQualitySelection
              ? const RecordingProfile(resolution: RecordingResolution.fullHd)
              : const RecordingProfile(),
        );
        expect(
          await service.applyRecordingProfile(
            supportsQualitySelection
                ? const RecordingProfile(
                    resolution: RecordingResolution.fullHd,
                    fps: 60,
                  )
                : const RecordingProfile(recordAudio: false),
          ),
          isTrue,
        );

        expect(gateway.mirrorValues, [false, false]);
      },
    );
  }

  test('macOS pause and resume delegate to the native recording', () async {
    final gateway = QualityFakeGateway();
    final service = CameraService(
      const [macInternal],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.macos,
    );
    addTearDown(service.dispose);

    await service.initialize(front: true);
    expect(await service.startRecording(), isTrue);

    await service.pauseRecording();
    expect(service.isRecordingPaused, isTrue);
    await service.resumeRecording();

    expect(gateway.pauses, 1);
    expect(gateway.resumes, 1);
    expect(service.isRecording, isTrue);
    expect(service.isRecordingPaused, isFalse);
  });

  test(
    'only configuration failures try the next supported candidate',
    () async {
      final gateway = QualityFakeGateway()..reject60 = true;
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      await service.initialize(
        front: false,
        recordingProfile: const RecordingProfile(
          resolution: RecordingResolution.ultraHd,
          fps: 60,
        ),
      );
      expect(service.appliedProfile?.format, h264(uhd30));
      expect(service.appliedProfile?.fallbackReason, 'configurationRejected');
      expect(gateway.attempted, [uhd60, uhd30]);
      expect(gateway.factory.maxActiveControllers, 1);
    },
  );

  test('permission failure never masquerades as resolution fallback', () async {
    final gateway = QualityFakeGateway()
      ..initializeError = CameraException('CameraAccessDenied', 'Denied');
    final service = CameraService(
      [back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);
    await expectLater(
      service.initialize(front: false),
      throwsA(isA<CameraException>()),
    );
    expect(gateway.attempted, [uhd30]);
  });

  test(
    'start winning the queue prevents camera switch and profile changes',
    () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        [front, back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      await service.initialize(front: true);
      final starting = service.startRecording();
      final switching = service.selectCamera('back');
      final changing = service.applyRecordingProfile(
        const RecordingProfile(resolution: RecordingResolution.hd),
      );
      expect(await starting, isTrue);
      expect(await switching, isNull);
      expect(await changing, isFalse);
      expect(service.selectedCamera, front);
      expect(gateway.attempted, [fhd30]);
      expect(service.isRecording, isTrue);
    },
  );

  test(
    'duplicate profile requests do not recreate a working controller',
    () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        [front],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      await service.initialize(front: true);
      expect(
        await service.applyRecordingProfile(const RecordingProfile()),
        isTrue,
      );
      expect(gateway.attempted, [fhd30]);
    },
  );

  test(
    'passes codec, bitrate, audio, and orientation to a new controller',
    () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      const request = RecordingProfile(
        recordAudio: false,
        resolution: RecordingResolution.fullHd,
        bitratePreset: RecordingBitratePreset.dataSaver,
        videoCodec: RecordingVideoCodec.hevc,
        lockOrientation: true,
      );

      await service.initialize(front: false, recordingProfile: request);

      expect(service.appliedProfile?.format, hevc(fhd30));
      expect(gateway.currentCodec, RecordingVideoCodec.hevc);
      expect(gateway.videoBitrates.last, 3500000);
      expect(gateway.audioBitrates.last, isNull);
      expect(gateway.audioSelections.last, isFalse);
      expect(gateway.factory.createdControllers.last.orientationLockCalls, 1);
    },
  );

  test('applies and clamps live zoom and exposure compensation', () async {
    final gateway = QualityFakeGateway();
    final service = CameraService(
      [back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);
    await service.initialize(front: false);

    expect(service.supportsZoom, isTrue);
    expect(service.supportsExposureCompensation, isTrue);
    expect(await service.setZoomLevel(9), isTrue);
    expect(await service.setExposureOffset(-9), isTrue);

    expect(service.zoomLevel, 4);
    expect(service.exposureOffset, -2);
    expect(gateway.factory.createdControllers.last.zoomLevels, [4]);
    expect(gateway.factory.createdControllers.last.exposureOffsets, [-2]);
  });

  test('an unavailable HEVC preference safely falls back to H.264', () async {
    final gateway = QualityFakeGateway()..advertiseHevc = false;
    final service = CameraService(
      [back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);
    const request = RecordingProfile(videoCodec: RecordingVideoCodec.hevc);

    await service.initialize(front: false, recordingProfile: request);

    expect(service.isInitialized, isTrue);
    expect(service.recordingProfile, request);
    expect(gateway.currentCodec, RecordingVideoCodec.h264);
    expect(service.appliedProfile?.fallbackReason, 'unsupportedProfile');
  });

  test('HEVC fallback keeps a higher-resolution H.264 format', () async {
    final gateway = QualityFakeGateway()
      ..capabilitiesOverride = const RecordingCapabilities(
        profiles: [fhd30Hevc, uhd30],
      );
    final service = CameraService(
      [back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);

    await service.initialize(
      front: false,
      recordingProfile: const RecordingProfile(
        resolution: RecordingResolution.ultraHd,
        videoCodec: RecordingVideoCodec.hevc,
      ),
    );

    expect(service.appliedProfile?.format, h264(uhd30));
    expect(gateway.attempted, [uhd30]);
    expect(gateway.attemptedCodecs, [RecordingVideoCodec.h264]);
    expect(service.appliedProfile?.fallbackReason, 'unsupportedProfile');
  });

  test(
    'a rejected HEVC configuration retries H.264 at the same size',
    () async {
      final gateway = QualityFakeGateway()..rejectHevc = true;
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);

      await service.initialize(
        front: false,
        recordingProfile: const RecordingProfile(
          resolution: RecordingResolution.fullHd,
          videoCodec: RecordingVideoCodec.hevc,
        ),
      );

      expect(gateway.attempted, [fhd30, fhd30]);
      expect(gateway.attemptedCodecs, [
        RecordingVideoCodec.hevc,
        RecordingVideoCodec.h264,
      ]);
      expect(service.appliedProfile?.format, h264(fhd30));
      expect(service.appliedProfile?.fallbackReason, 'configurationRejected');
    },
  );

  test('automatic bitrate leaves both encoder defaults untouched', () async {
    final gateway = QualityFakeGateway();
    final service = CameraService(
      [back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);

    await service.initialize(front: false);

    expect(gateway.videoBitrates.last, isNull);
    expect(gateway.audioBitrates.last, isNull);
  });

  test('an explicit bitrate preset configures video and audio', () async {
    final gateway = QualityFakeGateway();
    final service = CameraService(
      [back],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);

    await service.initialize(
      front: false,
      recordingProfile: const RecordingProfile(
        bitratePreset: RecordingBitratePreset.balanced,
      ),
    );

    expect(gateway.videoBitrates.last, 35000000);
    expect(gateway.audioBitrates.last, RecordingStorageEstimate.audioBitrate);
  });

  test(
    'failed focus convergence leaves auto focus and exposure active',
    () async {
      final gateway = QualityFakeGateway()..focusConverged = false;
      final service = CameraService(
        [front],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      await service.initialize(front: true);
      expect(await service.setFocusAndExposureLocked(true), isFalse);
      expect(service.focusLockUnavailable, isTrue);
      expect(
        gateway.factory.createdControllers.last.focusModes.last,
        FocusMode.auto,
      );
      expect(
        gateway.factory.createdControllers.last.exposureModes.last,
        ExposureMode.auto,
      );
    },
  );

  for (final rejectsFocus in [true, false]) {
    test('a rejected ${rejectsFocus ? 'focus' : 'exposure'} lock restores both '
        'auto modes and permits a retry', () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        const [macInternal],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.macos,
      );
      addTearDown(service.dispose);
      await service.initialize(front: true);
      final controller = gateway.factory.createdControllers.last;
      controller.rejectFocusLock = rejectsFocus;
      controller.rejectExposureLock = !rejectsFocus;

      expect(await service.setFocusAndExposureLocked(true), isFalse);
      expect(service.focusLockUnavailable, isTrue);
      expect(controller.focusModes.last, FocusMode.auto);
      expect(controller.exposureModes.last, ExposureMode.auto);

      controller.rejectFocusLock = false;
      controller.rejectExposureLock = false;

      expect(await service.setFocusAndExposureLocked(true), isTrue);
      expect(service.focusLockUnavailable, isFalse);
      expect(controller.focusModes.last, FocusMode.locked);
      expect(controller.exposureModes.last, ExposureMode.locked);
    });
  }

  test('inspection failure preserves original and capture context', () async {
    final gateway = QualityFakeGateway()
      ..inspectionError = StateError('unreadable metadata');
    final service = CameraService(
      [front],
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);
    await service.initialize(
      front: true,
      recordingProfile: const RecordingProfile(
        resolution: RecordingResolution.ultraHd,
      ),
    );
    await service.startRecording();
    final result = await service.finishRecording();
    expect(result?.file.path, '/tmp/quality-original.mp4');
    expect(result?.mediaMetadata?.width, isNull);
    expect(result?.mediaMetadata?.configuredWidth, 1920);
    expect(result?.mediaMetadata?.lensDirection, 'front');
    expect(result?.mediaMetadata?.fallbackReason, 'unsupportedProfile');
    expect(await service.finishRecording(), isNull);
    expect(gateway.stops, 1);
  });

  test(
    'finalized file measurements remain distinct from configured settings',
    () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      await service.initialize(front: false);
      await service.startRecording();
      final result = await service.finishRecording();
      expect(result?.mediaMetadata?.width, 1920);
      expect(result?.mediaMetadata?.configuredWidth, 3840);
      expect(result?.mediaMetadata?.durationMilliseconds, 1250);
      expect(result?.mediaMetadata?.fps, 29.97);
      expect(result?.mediaMetadata?.fpsSource, 'nominal');
    },
  );

  group('explicit 480p (#28)', () {
    test('an exactly applied 480p request is not a fallback', () async {
      final gateway = QualityFakeGateway()
        ..inspectionResult = const RecordedMediaMetadata(
          width: 640,
          height: 480,
          fps: 30,
          fpsSource: 'nominal',
        );
      final service = CameraService(
        [front],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);

      await service.initialize(
        front: true,
        recordingProfile: const RecordingProfile(
          resolution: RecordingResolution.standardDefinition,
        ),
      );

      expect(gateway.attempted, [sd30]);
      expect(service.appliedProfile?.format, h264(sd30));
      expect(service.appliedProfile?.fallbackReason, isNull);

      expect(await service.startRecording(), isTrue);
      final result = await service.finishRecording();
      expect(result?.mediaMetadata?.configuredHeight, 480);
      expect(result?.mediaMetadata?.fallbackReason, isNull);
    });

    test(
      'automatic on a lens that only offers 480p is not a fallback',
      () async {
        final gateway = QualityFakeGateway()
          ..capabilitiesOverride = const RecordingCapabilities(
            profiles: [sd30],
          );
        final service = CameraService(
          [back],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);

        await service.initialize(front: false);

        expect(service.appliedProfile?.format, h264(sd30));
        expect(service.appliedProfile?.fallbackReason, isNull);
      },
    );

    test('480p at an unavailable 60 FPS still reports the fallback', () async {
      final gateway = QualityFakeGateway();
      final service = CameraService(
        [front],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);

      await service.initialize(
        front: true,
        recordingProfile: const RecordingProfile(
          resolution: RecordingResolution.standardDefinition,
          fps: 60,
        ),
      );

      expect(service.appliedProfile?.format, h264(sd30));
      expect(
        service.appliedProfile?.fallbackReason,
        RecordingFallbackReason.unsupportedProfile,
      );
    });
  });

  group('candidate selection (#31)', () {
    test('automatic honors the requested frame rate before resolution', () {
      const caps = RecordingCapabilities(profiles: [uhd30, fhd60, fhd30, hd30]);
      const request = RecordingProfile(fps: 60);

      expect(caps.frameRates(RecordingResolution.automatic), contains(60));
      expect(caps.candidates(request), [
        h264(fhd60),
        h264(uhd30),
        h264(fhd30),
        h264(hd30),
      ]);
    });

    test('automatic 60 FPS applies 1080p60 instead of 2160p30', () async {
      final gateway = QualityFakeGateway()
        ..capabilitiesOverride = const RecordingCapabilities(
          profiles: [uhd30, fhd60, fhd30],
        );
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);

      await service.initialize(
        front: false,
        recordingProfile: const RecordingProfile(fps: 60),
      );

      expect(gateway.attempted, [fhd60]);
      expect(service.appliedProfile?.format, h264(fhd60));
      expect(service.appliedProfile?.fallbackReason, isNull);
    });

    test('an explicit target keeps resolution ahead of frame rate', () {
      const caps = RecordingCapabilities(profiles: [uhd30, fhd60, fhd30]);

      expect(
        caps.candidates(
          const RecordingProfile(
            resolution: RecordingResolution.ultraHd,
            fps: 60,
          ),
        ),
        [h264(uhd30), h264(fhd60), h264(fhd30)],
      );
    });

    test('without a format at or below the target, the closest larger '
        'resolution is the only candidate', () {
      const caps = RecordingCapabilities(profiles: [uhd30, fhd30, hd30]);

      expect(
        caps.candidates(
          const RecordingProfile(
            resolution: RecordingResolution.standardDefinition,
          ),
        ),
        [h264(hd30)],
      );
      // Formats at or below the target still never upgrade.
      expect(
        caps.candidates(
          const RecordingProfile(resolution: RecordingResolution.hd),
        ),
        [h264(hd30)],
      );
      expect(
        const RecordingCapabilities().candidates(
          const RecordingProfile(
            resolution: RecordingResolution.standardDefinition,
          ),
        ),
        isEmpty,
      );
    });

    test('switching a remembered 480p profile to a lens without 480p '
        'degrades instead of failing', () async {
      final gateway = QualityFakeGateway();
      gateway.capabilitiesByCamera['back'] = const RecordingCapabilities(
        profiles: [uhd30, fhd30, hd30],
      );
      final service = CameraService(
        [front, back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);
      const request = RecordingProfile(
        resolution: RecordingResolution.standardDefinition,
      );

      await service.initialize(front: true, recordingProfile: request);
      expect(service.appliedProfile?.fallbackReason, isNull);

      await service.switchCamera();

      expect(service.selectedCamera, back);
      expect(service.recordingProfile, request);
      expect(service.appliedProfile?.cameraName, 'back');
      expect(service.appliedProfile?.format, h264(hd30));
      expect(
        service.appliedProfile?.fallbackReason,
        RecordingFallbackReason.unsupportedProfile,
      );
    });

    test('same-size formats prefer the wider one deterministically', () {
      const caps = RecordingCapabilities(profiles: [fhd30Narrow, fhd30]);

      final candidates = caps.candidates(
        const RecordingProfile(resolution: RecordingResolution.fullHd),
      );

      expect(candidates.map((format) => format.width), [1920, 1440]);
    });
  });

  group('native readback (#31 test gaps)', () {
    test(
      'a readback that differs from the candidate tries the next one',
      () async {
        final gateway = QualityFakeGateway();
        gateway.readbackOverrides[fhd30] = {
          'width': 1280,
          'height': 720,
          'fps': 30,
          'codec': 'h264',
        };
        final service = CameraService(
          [back],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);

        await service.initialize(
          front: false,
          recordingProfile: const RecordingProfile(
            resolution: RecordingResolution.fullHd,
          ),
        );

        expect(gateway.attempted, [fhd30, hd30]);
        expect(service.appliedProfile?.format, h264(hd30));
        expect(
          service.appliedProfile?.fallbackReason,
          RecordingFallbackReason.configurationRejected,
        );
        expect(gateway.factory.activeControllers, 1);
      },
    );

    test('a readback with a different codec is rejected', () async {
      final gateway = QualityFakeGateway();
      gateway.readbackOverrides[fhd30] = {
        'width': 1920,
        'height': 1080,
        'fps': 30,
        'codec': 'h264',
      };
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);

      await service.initialize(
        front: false,
        recordingProfile: const RecordingProfile(
          resolution: RecordingResolution.fullHd,
          videoCodec: RecordingVideoCodec.hevc,
        ),
      );

      // HEVC readback reported H.264: the H.264 attempt at the same size wins.
      expect(gateway.attemptedCodecs, [
        RecordingVideoCodec.hevc,
        RecordingVideoCodec.h264,
      ]);
      expect(service.appliedProfile?.format, h264(fhd30));
      expect(
        service.appliedProfile?.fallbackReason,
        RecordingFallbackReason.configurationRejected,
      );
    });

    test('a readback without a frame rate is not trusted', () async {
      final gateway = QualityFakeGateway();
      gateway.readbackOverrides[fhd30] = {
        'width': 1920,
        'height': 1080,
        'fps': null,
      };
      final service = CameraService(
        [back],
        recordingGateway: gateway,
        capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
      );
      addTearDown(service.dispose);

      await service.initialize(
        front: false,
        recordingProfile: const RecordingProfile(
          resolution: RecordingResolution.fullHd,
        ),
      );

      expect(gateway.attempted, [fhd30, hd30]);
      expect(service.appliedProfile?.format, h264(hd30));
    });

    test(
      'no trustworthy readback fails without leaking a controller',
      () async {
        final gateway = QualityFakeGateway()
          ..capabilitiesOverride = const RecordingCapabilities(
            profiles: [fhd30, hd30],
          );
        for (final format in [fhd30, hd30]) {
          gateway.readbackOverrides[format] = {
            'width': format.width,
            'height': format.height,
          };
        }
        final service = CameraService(
          [back],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);

        await expectLater(
          service.initialize(front: false),
          throwsA(
            isA<CameraException>().having(
              (error) => error.code,
              'code',
              'unsupportedRecordingProfile',
            ),
          ),
        );
        expect(gateway.attempted, [fhd30, hd30]);
        expect(gateway.factory.activeControllers, 0);
        expect(service.appliedProfile, isNull);
      },
    );

    for (final code in const [
      'unsupportedRecordingProfile',
      'unsupported_profile',
      'configurationFailed',
      'cameraConfiguration',
      'cameraNotSupported',
      'UnsupportedOperationException',
      'IllegalArgumentException',
    ]) {
      test('PlatformException "$code" is a configuration rejection', () async {
        final gateway = QualityFakeGateway();
        gateway.rejectFormats[uhd30] = PlatformException(code: code);
        final service = CameraService(
          [back],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);

        await service.initialize(front: false);

        expect(gateway.attempted, [uhd30, fhd30]);
        expect(service.appliedProfile?.format, h264(fhd30));
        expect(
          service.appliedProfile?.fallbackReason,
          RecordingFallbackReason.configurationRejected,
        );
      });
    }

    for (final code in const ['CameraAccessDenied', 'cameraNotBound']) {
      test('PlatformException "$code" is an error, not a fallback', () async {
        final gateway = QualityFakeGateway();
        gateway.rejectFormats[uhd30] = PlatformException(code: code);
        final service = CameraService(
          [back],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);

        await expectLater(
          service.initialize(front: false),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
        );
        expect(gateway.attempted, [uhd30]);
        expect(gateway.factory.activeControllers, 0);
      });
    }

    for (final confirmed in [true, false]) {
      test('stabilization is reported only when readback '
          '${confirmed ? 'confirms' : 'denies'} it', () async {
        final gateway = QualityFakeGateway()
          ..stabilizationReadbackOverride = confirmed;
        final service = CameraService(
          [back],
          recordingGateway: gateway,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);
        await service.initialize(front: false);
        expect(service.appliedProfile?.stabilizationEnabled, isFalse);

        expect(await service.setVideoStabilizationEnabled(true), confirmed);

        expect(service.videoStabilizationEnabled, isTrue);
        expect(service.appliedProfile?.stabilizationEnabled, confirmed);
        expect(
          gateway.factory.createdControllers.last.videoStabilizationModes.last,
          VideoStabilizationMode.level1,
        );
      });
    }
  });
}

/// Exercises Dart negotiation/lifecycle only; it does not validate hardware.
class QualityFakeGateway extends RecordingGateway {
  final factory = TestCameraControllerFactory();
  final attempted = <RecordingVideoFormat>[];
  final mirrorValues = <bool>[];
  RecordingVideoFormat current = fhd30;
  bool qualitySelection = true;
  bool reject60 = false;
  bool rejectHevc = false;
  bool advertiseHevc = true;
  RecordingCapabilities? capabilitiesOverride;

  /// Per-camera capabilities, checked before [capabilitiesOverride].
  final Map<String, RecordingCapabilities> capabilitiesByCamera = {};
  bool focusConverged = true;
  Object? initializeError;
  Object? inspectionError;
  Object? stopError;
  Object? disposeError;

  /// Errors thrown while initializing a specific attempted format.
  final Map<RecordingVideoFormat, Object> rejectFormats = {};

  /// Native readback per attempted format, replacing the exact echo of the
  /// request. Lets tests exercise the candidate/readback mismatch branch and
  /// malformed native results such as a missing frame rate.
  final Map<RecordingVideoFormat, Map<String, dynamic>> readbackOverrides = {};

  /// Replaces the stabilization readback derived from the live controller.
  bool? stabilizationReadbackOverride;

  /// Replaces the default inspection result.
  RecordedMediaMetadata? inspectionResult;

  /// When set, inspection waits for this gate before answering.
  Completer<void>? inspectionGate;
  int inspections = 0;
  Completer<void>? _deferredInitialize;
  Completer<void>? _deferredInitializeStarted;
  int starts = 0;
  int stops = 0;
  int pauses = 0;
  int resumes = 0;
  RecordingVideoCodec currentCodec = RecordingVideoCodec.h264;
  final List<RecordingVideoCodec> attemptedCodecs = [];
  final List<int?> videoBitrates = [];
  final List<int?> audioBitrates = [];
  final List<bool> audioSelections = [];

  Future<void> deferNextInitialize() {
    _deferredInitialize = Completer<void>();
    _deferredInitializeStarted = Completer<void>();
    return _deferredInitializeStarted!.future;
  }

  void completeDeferredInitialize() {
    final gate = _deferredInitialize;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  bool get supportsQualitySelection => qualitySelection;
  @override
  Future<RecordingCapabilities> capabilities(String cameraName) async {
    final overridden = capabilitiesByCamera[cameraName] ?? capabilitiesOverride;
    if (overridden != null) return overridden;
    final advertisedFhd30 = advertiseHevc
        ? fhd30
        : const RecordingVideoFormat(width: 1920, height: 1080, fps: 30);
    return RecordingCapabilities(
      profiles: switch (cameraName) {
        'front' => [advertisedFhd30, hd30, sd30],
        'internal' => [fhd60, advertisedFhd30, hd30, sd30],
        _ => [uhd60, uhd30, fhd60, advertisedFhd30, hd30, sd30],
      },
      supportsFocusLock: true,
      supportsExposureLock: true,
    );
  }

  @override
  Future<CameraController> createInitializedController({
    required CameraDescription description,
    required ResolutionPreset preset,
    required bool enableAudio,
    required RecordingVideoCodec videoCodec,
    int? fps,
    int? videoBitrate,
    int? audioBitrate,
  }) async {
    currentCodec = videoCodec;
    attemptedCodecs.add(videoCodec);
    current = switch (preset) {
      ResolutionPreset.ultraHigh => fps == 60 ? uhd60 : uhd30,
      ResolutionPreset.veryHigh => fps == 60 ? fhd60 : fhd30,
      ResolutionPreset.medium => sd30,
      _ => hd30,
    };
    attempted.add(current);
    videoBitrates.add(videoBitrate);
    audioBitrates.add(audioBitrate);
    audioSelections.add(enableAudio);
    final controller = factory.create(
      description: description,
      resolutionPreset: preset,
      enableAudio: enableAudio,
    );
    try {
      await initialize(controller);
      return controller;
    } catch (error, stackTrace) {
      try {
        await controller.dispose();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> initialize(CameraController controller) async {
    final error = initializeError ?? rejectFormats[current];
    if (error != null) throw error;
    if (reject60 && current.fps == 60) {
      throw CameraException('unsupportedRecordingProfile', 'Test rejection');
    }
    if (rejectHevc && currentCodec == RecordingVideoCodec.hevc) {
      throw CameraException('unsupportedRecordingProfile', 'Test rejection');
    }
    final gate = _deferredInitialize;
    if (gate != null) {
      final started = _deferredInitializeStarted;
      if (started != null && !started.isCompleted) started.complete();
      await gate.future;
      if (identical(_deferredInitialize, gate)) {
        _deferredInitialize = null;
        _deferredInitializeStarted = null;
      }
    }
    await controller.initialize();
  }

  @override
  Future<Map<String, dynamic>> applied(int cameraId) async {
    // Test controllers all share the uninitialized camera id; the most
    // recently created controller is the live one.
    final live = factory.createdControllers.last;
    final modes = live.videoStabilizationModes;
    final stabilized =
        stabilizationReadbackOverride ??
        (modes.isNotEmpty && modes.last != VideoStabilizationMode.off);
    return {
      ...readbackOverrides[current] ??
          {
            'width': current.width,
            'height': current.height,
            'fps': current.fps,
            'codec': currentCodec.name,
          },
      'stabilizationEnabled': stabilized,
    };
  }

  @override
  Future<bool> waitForFocus(int cameraId) async => focusConverged;

  @override
  Future<void> start(CameraController controller) async {
    starts++;
    await super.start(controller);
  }

  @override
  Future<void> setMirror(CameraController controller, bool mirror) async {
    mirrorValues.add(mirror);
  }

  @override
  Future<void> pause(CameraController controller) async {
    pauses++;
    controller.value = controller.value.copyWith(isRecordingPaused: true);
  }

  @override
  Future<void> resume(CameraController controller) async {
    resumes++;
    controller.value = controller.value.copyWith(isRecordingPaused: false);
  }

  @override
  Future<void> dispose(CameraController controller) async {
    await super.dispose(controller);
    final error = disposeError;
    if (error != null) throw error;
  }

  @override
  Future<XFile> stop(CameraController controller) async {
    stops++;
    final error = stopError;
    if (error != null) throw error;
    controller.value = controller.value.copyWith(isRecordingVideo: false);
    return XFile('/tmp/quality-original.mp4');
  }

  @override
  Future<RecordedMediaMetadata?> inspect(String path) async {
    inspections++;
    final gate = inspectionGate;
    if (gate != null) await gate.future;
    final error = inspectionError;
    if (error != null) throw error;
    return inspectionResult ??
        const RecordedMediaMetadata(
          width: 1920,
          height: 1080,
          durationMilliseconds: 1250,
          fps: 29.97,
          fpsSource: 'nominal',
        );
  }
}
