// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera_recording/camera_recording.dart';

import 'camera_service_test.dart' show TestCameraControllerFactory;
import 'recording_quality_selection_test.dart'
    show QualityFakeGateway, back, front, uhd30;

const external = CameraDescription(
  name: 'external',
  lensDirection: CameraLensDirection.external,
  sensorOrientation: 90,
);

/// CameraService state-machine regressions from issue #31.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CameraService serviceFor(
    QualityFakeGateway gateway, [
    List<CameraDescription> cameras = const [front, back],
  ]) {
    final service = CameraService(
      cameras,
      recordingGateway: gateway,
      capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
    );
    addTearDown(service.dispose);
    return service;
  }

  group('stabilization toggled during a recording', () {
    test(
      'is not reported as applied and takes effect after the stop',
      () async {
        final gateway = QualityFakeGateway();
        final service = serviceFor(gateway);
        await service.initialize(front: true);
        final controller = gateway.factory.createdControllers.last;
        expect(controller.videoStabilizationModes, [
          VideoStabilizationMode.off,
        ]);
        expect(await service.startRecording(), isTrue);

        expect(await service.setVideoStabilizationEnabled(true), isFalse);

        expect(service.videoStabilizationEnabled, isTrue);
        expect(controller.videoStabilizationModes, [
          VideoStabilizationMode.off,
        ]);
        expect(service.appliedProfile?.stabilizationEnabled, isFalse);

        await service.finishRecording();

        expect(controller.videoStabilizationModes, [
          VideoStabilizationMode.off,
          VideoStabilizationMode.level1,
        ]);
        expect(service.appliedProfile?.stabilizationEnabled, isTrue);
      },
    );

    test('a pending change also applies after stopRecording', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.setVideoStabilizationEnabled(true);
      await service.initialize(front: true);
      expect(service.appliedProfile?.stabilizationEnabled, isTrue);
      expect(await service.startRecording(), isTrue);

      expect(await service.setVideoStabilizationEnabled(false), isFalse);
      expect(service.appliedProfile?.stabilizationEnabled, isTrue);

      await service.stopRecording();

      expect(
        gateway.factory.createdControllers.last.videoStabilizationModes.last,
        VideoStabilizationMode.off,
      );
      expect(service.appliedProfile?.stabilizationEnabled, isFalse);
    });
  });

  test('rapid double switchCamera advances two cameras', () async {
    final gateway = QualityFakeGateway();
    final service = serviceFor(gateway, const [front, back, external]);
    await service.initialize(front: true);

    final first = service.switchCamera();
    final second = service.switchCamera();
    await Future.wait([first, second]);

    expect(service.selectedCamera, external);
    expect(service.appliedProfile?.cameraName, 'external');
    expect(gateway.factory.createdControllers, hasLength(3));
    expect(gateway.factory.createdControllers.map((c) => c.description.name), [
      'front',
      'back',
      'external',
    ]);
    expect(gateway.factory.maxActiveControllers, 1);
  });

  group('RecordingProfile.quality on quality-selection backends', () {
    test('a quality-only change does not rebuild the controller', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: false, preferredName: 'back');
      final controller = service.controller;
      const compact = RecordingProfile(quality: RecordingQualityIntent.compact);

      expect(await service.applyRecordingProfile(compact), isTrue);

      expect(service.controller, same(controller));
      expect(gateway.factory.createdControllers, hasLength(1));
      expect(service.recordingProfile, compact);
      expect(service.appliedProfile?.requested, compact);
    });

    test(
      'selectCamera on the same camera adopts a quality-only change',
      () async {
        final gateway = QualityFakeGateway();
        final service = serviceFor(gateway);
        await service.initialize(front: true);
        final controller = service.controller;
        const high = RecordingProfile(quality: RecordingQualityIntent.high);

        expect(
          await service.selectCamera('front', recordingProfile: high),
          same(controller),
        );
        expect(gateway.factory.createdControllers, hasLength(1));
        expect(service.recordingProfile, high);
      },
    );

    test('other changes still rebuild', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true);

      expect(
        await service.applyRecordingProfile(
          const RecordingProfile(recordAudio: false),
        ),
        isTrue,
      );
      expect(gateway.factory.createdControllers, hasLength(2));
    });
  });

  group('failed camera switch', () {
    test('failed recovery clears the previous camera state', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true);
      expect(service.appliedProfile, isNotNull);
      expect(service.recordingCapabilities.profiles, isNotEmpty);
      expect(service.supportsZoom, isTrue);
      gateway.initializeError = CameraException('cameraGone', 'Unplugged');

      await expectLater(
        service.switchCamera(),
        throwsA(isA<CameraControllerRecoveryException>()),
      );

      expect(service.controller, isNull);
      expect(service.appliedProfile, isNull);
      expect(service.recordingCapabilities.profiles, isEmpty);
      expect(service.supportsZoom, isFalse);
      expect(service.supportsExposureCompensation, isFalse);
      expect(service.zoomLevel, 1);
      expect(service.exposureOffset, 0);
      expect(gateway.factory.activeControllers, 0);
    });

    test('a throwing dispose of the old controller does not abort the '
        'switch', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true);
      gateway.disposeError = CameraException('disposeFailed', 'Busy');
      addTearDown(() => gateway.disposeError = null);

      final controller = await service.switchCamera();

      expect(controller, isNotNull);
      expect(service.selectedCamera, back);
      expect(service.isInitialized, isTrue);
      expect(service.appliedProfile?.cameraName, 'back');
    });

    test('a throwing dispose still attempts recovery', () async {
      final gateway = QualityFakeGateway();
      gateway.rejectFormats[uhd30] = CameraException('cameraGone', 'Busy');
      final service = serviceFor(gateway);
      await service.initialize(front: true);
      gateway.disposeError = CameraException('disposeFailed', 'Busy');
      addTearDown(() => gateway.disposeError = null);

      await expectLater(
        service.switchCamera(),
        throwsA(
          isA<CameraException>().having((e) => e.code, 'code', 'cameraGone'),
        ),
      );

      expect(service.selectedCamera, front);
      expect(service.isInitialized, isTrue);
      expect(service.appliedProfile?.cameraName, 'front');
    });
  });

  group('initialize camera choice', () {
    test('an explicit preferredName wins over the remembered camera', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true);
      expect(service.selectedCamera, front);

      await service.initialize(front: false, preferredName: 'back');

      expect(service.selectedCamera, back);
      expect(service.appliedProfile?.cameraName, 'back');
    });

    test('without a preferredName the remembered camera is reused', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true);
      await service.switchCamera();
      await service.release();

      await service.initialize(front: true);

      expect(service.selectedCamera, back);
    });

    test(
      'an unknown preferredName falls back to the remembered camera',
      () async {
        final gateway = QualityFakeGateway();
        final service = serviceFor(gateway);
        await service.initialize(front: false);

        await service.initialize(front: true, preferredName: 'missing');

        expect(service.selectedCamera, back);
      },
    );
  });

  group('finalized metadata', () {
    Future<RecordingResult?> record(
      QualityFakeGateway gateway,
      RecordingProfile profile, {
      bool front = false,
    }) async {
      final service = serviceFor(gateway);
      await service.initialize(front: front, recordingProfile: profile);
      expect(await service.startRecording(), isTrue);
      return service.finishRecording();
    }

    test(
      'encodedMismatch does not overwrite a configuration fallback',
      () async {
        final gateway = QualityFakeGateway()
          ..inspectionResult = const RecordedMediaMetadata(
            width: 1280,
            height: 720,
            fps: 30,
            fpsSource: 'nominal',
          );

        final result = await record(
          gateway,
          const RecordingProfile(resolution: RecordingResolution.ultraHd),
          front: true,
        );

        expect(
          result?.mediaMetadata?.fallbackReason,
          RecordingFallbackReason.unsupportedProfile,
        );
      },
    );

    test('an exact configuration still reports encodedMismatch', () async {
      final gateway = QualityFakeGateway()
        ..inspectionResult = const RecordedMediaMetadata(
          width: 1280,
          height: 720,
          fps: 30,
          fpsSource: 'nominal',
        );

      final result = await record(
        gateway,
        const RecordingProfile(resolution: RecordingResolution.fullHd),
      );

      expect(
        result?.mediaMetadata?.fallbackReason,
        RecordingFallbackReason.encodedMismatch,
      );
    });

    for (final (fps, source, mismatch) in const [
      (28.4, 'measured', false),
      (27.2, 'measured', false),
      (25.0, 'measured', true),
      (28.4, 'nominal', true),
      (29.97, 'nominal', false),
    ]) {
      test('$source $fps fps for a 30 fps configuration is '
          '${mismatch ? '' : 'not '}a mismatch', () async {
        final gateway = QualityFakeGateway()
          ..inspectionResult = RecordedMediaMetadata(
            width: 1920,
            height: 1080,
            fps: fps,
            fpsSource: source,
          );

        final result = await record(
          gateway,
          const RecordingProfile(resolution: RecordingResolution.fullHd),
        );

        expect(result?.mediaMetadata?.configuredFps, 30);
        expect(
          result?.mediaMetadata?.fallbackReason,
          mismatch ? RecordingFallbackReason.encodedMismatch : isNull,
        );
      });
    }
  });

  test('finishRecording inspection does not hold release()', () async {
    final gate = Completer<void>();
    final gateway = QualityFakeGateway()..inspectionGate = gate;
    final service = serviceFor(gateway);
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await service.initialize(front: true);
    expect(await service.startRecording(), isTrue);

    final finishing = service.finishRecording();
    var released = false;
    final releasing = service.release().then((result) {
      released = true;
      return result;
    });
    await pumpEventQueue();

    expect(gateway.inspections, 1);
    expect(released, isTrue);
    // The recording was already stopped in order; release has nothing to stop.
    expect(await releasing, isNull);
    expect(gateway.stops, 1);
    expect(service.controller, isNull);

    gate.complete();
    final result = await finishing;
    expect(result?.file.path, '/tmp/quality-original.mp4');
    expect(result?.mediaMetadata?.width, 1920);
    expect(result?.mediaMetadata?.cameraName, 'front');
  });

  group('backends without quality selection', () {
    for (final useFactory in [true, false]) {
      final label = useFactory ? 'controllerFactory' : 'unsupported backend';

      CameraService legacyService(
        QualityFakeGateway gateway,
        TestCameraControllerFactory factory,
      ) {
        gateway.qualitySelection = false;
        final service = CameraService(
          const [front],
          recordingGateway: gateway,
          controllerFactory: useFactory ? factory.create : null,
          capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
        );
        addTearDown(service.dispose);
        return service;
      }

      TestCameraControllerFactory created(
        QualityFakeGateway gateway,
        TestCameraControllerFactory factory,
      ) => useFactory ? factory : gateway.factory;

      for (final profile in const [
        RecordingProfile(resolution: RecordingResolution.fullHd),
        RecordingProfile(fps: 60),
        RecordingProfile(bitratePreset: RecordingBitratePreset.high),
        RecordingProfile(videoCodec: RecordingVideoCodec.hevc),
      ]) {
        test('$label rejects an explicit profile it cannot apply '
            '(${profile.toJson()})', () async {
          final gateway = QualityFakeGateway();
          final factory = TestCameraControllerFactory();
          final service = legacyService(gateway, factory);

          await expectLater(
            service.initialize(front: true, recordingProfile: profile),
            throwsA(
              isA<CameraException>().having(
                (e) => e.code,
                'code',
                'unsupportedRecordingProfile',
              ),
            ),
          );
          expect(created(gateway, factory).createdControllers, isEmpty);
          expect(service.appliedProfile, isNull);
        });
      }

      test('$label keeps the preview when an explicit profile is '
          'applied', () async {
        final gateway = QualityFakeGateway();
        final factory = TestCameraControllerFactory();
        final service = legacyService(gateway, factory);
        await service.initialize(front: true);
        final controller = service.controller;

        await expectLater(
          service.applyRecordingProfile(
            const RecordingProfile(resolution: RecordingResolution.hd),
          ),
          throwsA(isA<CameraException>()),
        );

        expect(service.controller, same(controller));
        expect(service.isInitialized, isTrue);
        expect(service.recordingProfile, const RecordingProfile());
        expect(created(gateway, factory).createdControllers, hasLength(1));
      });

      test('$label maps quality to the same preset', () async {
        final gateway = QualityFakeGateway();
        final factory = TestCameraControllerFactory();
        final service = legacyService(gateway, factory);

        await service.initialize(
          front: true,
          recordingProfile: const RecordingProfile(
            quality: RecordingQualityIntent.compact,
          ),
        );

        expect(service.controller?.resolutionPreset, ResolutionPreset.low);
        expect(service.appliedProfile, isNull);
      });
    }
  });
}
