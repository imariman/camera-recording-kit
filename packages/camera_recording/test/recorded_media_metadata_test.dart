import 'package:flutter_test/flutter_test.dart';

import 'package:camera_recording/camera_recording.dart';

void main() {
  const metadata = RecordedMediaMetadata(
    width: 1920,
    height: 1080,
    durationMilliseconds: 12345,
    rotationDegrees: 90,
    fps: 29.97,
    fpsSource: 'measured',
    bitrate: 8400000,
    bitrateSource: 'estimated',
    codec: 'h264',
    mimeType: 'video/mp4',
    fileSizeBytes: 12900000,
    cameraName: 'Front Camera',
    lensDirection: 'front',
    configuredWidth: 1920,
    configuredHeight: 1080,
    configuredFps: 30,
    fallbackReason: 'highUnavailable',
  );

  test('version 1 metadata bütün alanları kayıpsız round-trip eder', () {
    final json = metadata.toJson();

    expect(json['schemaVersion'], RecordedMediaMetadata.currentSchemaVersion);
    expect(RecordedMediaMetadata.tryParse(json), metadata);
  });

  test('bozuk alanları yok sayar ve geçerli kısmi metadatayı korur', () {
    final parsed = RecordedMediaMetadata.tryParse({
      'width': -1920,
      'height': 1080.5,
      'durationMilliseconds': 0,
      'rotationDegrees': '90',
      'fps': double.nan,
      'fpsSource': 'guessed',
      'bitrate': 8400000,
      'bitrateSource': 'measured',
      'codec': '  h265  ',
      'mimeType': '',
      'fileSizeBytes': 0,
      'cameraName': 42,
      'lensDirection': ' front ',
      'configuredWidth': 1280.0,
      'configuredHeight': -720,
      'configuredFps': 60,
      'fallbackReason': '  compactFallback  ',
    });

    expect(parsed, isNotNull);
    expect(parsed?.width, isNull);
    expect(parsed?.height, isNull);
    expect(parsed?.durationMilliseconds, 0);
    expect(parsed?.rotationDegrees, isNull);
    expect(parsed?.fps, isNull);
    expect(parsed?.fpsSource, isNull);
    expect(parsed?.bitrate, 8400000);
    expect(parsed?.bitrateSource, 'measured');
    expect(parsed?.codec, 'h265');
    expect(parsed?.mimeType, isNull);
    expect(parsed?.fileSizeBytes, isNull);
    expect(parsed?.lensDirection, 'front');
    expect(parsed?.configuredWidth, 1280);
    expect(parsed?.configuredHeight, isNull);
    expect(parsed?.configuredFps, 60);
    expect(parsed?.fallbackReason, 'compactFallback');
  });

  test('capture fields can be attached to inspected metadata', () {
    final inspected = RecordedMediaMetadata.tryParse({
      'width': 1920,
      'height': 1080,
      'fps': 30,
      'fpsSource': 'nominal',
    });

    final attached = inspected?.copyWith(
      cameraName: 'Front Camera',
      lensDirection: 'front',
      configuredWidth: 1280,
      configuredHeight: 720,
      configuredFps: 30,
      fallbackReason: 'resolutionFallback',
    );

    expect(attached?.width, 1920);
    expect(attached?.cameraName, 'Front Camera');
    expect(attached?.configuredWidth, 1280);
    expect(attached?.fallbackReason, 'resolutionFallback');
  });
}
