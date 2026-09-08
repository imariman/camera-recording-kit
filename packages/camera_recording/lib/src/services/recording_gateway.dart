import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camera_android_camerax/recording_quality.dart' as android;
import 'package:camera_avfoundation/recording_quality.dart' as ios;
import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_desktop/recording_quality.dart' as macos;

import 'package:camera_recording/src/models/recorded_media_metadata.dart';
import 'package:camera_recording/src/models/recording_capabilities.dart';

/// Platform selection can be injected to verify routing without real hardware.
enum RecordingBackend { android, ios, macos, unsupported }

/// One injectable platform boundary. No media passes through Flutter widgets.
class RecordingGateway {
  const RecordingGateway({this.backend});

  final RecordingBackend? backend;

  RecordingBackend get _backend =>
      backend ??
      (Platform.isAndroid
          ? RecordingBackend.android
          : Platform.isIOS
          ? RecordingBackend.ios
          : Platform.isMacOS
          ? RecordingBackend.macos
          : RecordingBackend.unsupported);

  bool get supportsQualitySelection => _backend != RecordingBackend.unsupported;

  Future<RecordingCapabilities> capabilities(String cameraName) async {
    final result = switch (_backend) {
      RecordingBackend.android => await android.recordingQualityCapabilities(
        cameraName,
      ),
      RecordingBackend.ios => await ios.recordingQualityCapabilities(
        cameraName,
      ),
      RecordingBackend.macos => await macos.recordingQualityCapabilities(
        cameraName,
      ),
      RecordingBackend.unsupported => <String, dynamic>{},
    };
    return RecordingCapabilities.fromJson(result);
  }

  CameraController createController({
    required CameraDescription description,
    required ResolutionPreset preset,
    required bool enableAudio,
    int? fps,
  }) =>
      CameraController(description, preset, enableAudio: enableAudio, fps: fps);

  Future<Map<String, dynamic>> applied(int cameraId) async =>
      switch (_backend) {
        RecordingBackend.android => await android.recordingQualityApplied(
          cameraId,
        ),
        RecordingBackend.ios => await ios.recordingQualityApplied(cameraId),
        RecordingBackend.macos => await macos.recordingQualityApplied(cameraId),
        RecordingBackend.unsupported => <String, dynamic>{},
      };

  Future<RecordedMediaMetadata?> inspect(String path) async {
    final result = switch (_backend) {
      RecordingBackend.android => await android.inspectRecordingMedia(path),
      RecordingBackend.ios => await ios.inspectRecordingMedia(path),
      RecordingBackend.macos => await macos.inspectRecordingMedia(path),
      RecordingBackend.unsupported => null,
    };
    return RecordedMediaMetadata.tryParse(result);
  }

  Future<bool> waitForFocus(int cameraId) async => switch (_backend) {
    RecordingBackend.android => await android.waitForRecordingFocus(cameraId),
    RecordingBackend.ios => await ios.waitForRecordingFocus(cameraId),
    RecordingBackend.macos => await macos.waitForRecordingFocus(cameraId),
    RecordingBackend.unsupported => false,
  };

  Future<void> setMirror(CameraController controller, bool mirrored) =>
      CameraDesktopPlugin().setMirror(controller.cameraId, mirrored);

  Future<void> initialize(CameraController controller) =>
      controller.initialize();
  Future<void> start(CameraController controller) =>
      controller.startVideoRecording();
  Future<void> pause(CameraController controller) =>
      controller.pauseVideoRecording();
  Future<void> resume(CameraController controller) =>
      controller.resumeVideoRecording();
  Future<XFile> stop(CameraController controller) =>
      controller.stopVideoRecording();
  Future<void> dispose(CameraController controller) => controller.dispose();
}
