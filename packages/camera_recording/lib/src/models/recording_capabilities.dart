import 'package:flutter/foundation.dart';

import 'package:camera_recording/src/models/recording_profile.dart';

@immutable
class RecordingVideoFormat {
  const RecordingVideoFormat({
    required this.width,
    required this.height,
    required this.fps,
  });
  final int width;
  final int height;
  final int fps;

  int get shortSide => width < height ? width : height;
  int get longSide => width > height ? width : height;

  static RecordingVideoFormat? tryParse(Map<Object?, Object?> map) {
    final width = map['width'];
    final height = map['height'];
    final fps = map['fps'];
    if (width is! int ||
        height is! int ||
        fps is! num ||
        !fps.isFinite ||
        width <= 0 ||
        height <= 0 ||
        width > 8192 ||
        height > 8192) {
      return null;
    }
    final rounded = fps.round();
    if (rounded != 30 && rounded != 60) return null;
    return RecordingVideoFormat(width: width, height: height, fps: rounded);
  }

  @override
  bool operator ==(Object other) =>
      other is RecordingVideoFormat &&
      longSide == other.longSide &&
      shortSide == other.shortSide &&
      fps == other.fps;
  @override
  int get hashCode => Object.hash(longSide, shortSide, fps);
}

@immutable
class RecordingCapabilities {
  const RecordingCapabilities({
    this.profiles = const [],
    this.supportsFocusLock = false,
    this.supportsExposureLock = false,
  });
  final List<RecordingVideoFormat> profiles;
  final bool supportsFocusLock;
  final bool supportsExposureLock;

  factory RecordingCapabilities.fromJson(Map<Object?, Object?> json) {
    final formats = <RecordingVideoFormat>{};
    final raw = json['profiles'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final value = RecordingVideoFormat.tryParse(entry);
        if (value != null && value.shortSide <= 2160) formats.add(value);
      }
    }
    return RecordingCapabilities(
      profiles: List.unmodifiable(formats),
      supportsFocusLock: json['supportsFocusLock'] == true,
      supportsExposureLock: json['supportsExposureLock'] == true,
    );
  }

  List<RecordingResolution> get resolutions => [
    RecordingResolution.automatic,
    for (final resolution in RecordingResolution.values.skip(1))
      if (profiles.any((format) => format.shortSide == resolution.height))
        resolution,
  ];

  List<int> frameRates(RecordingResolution resolution) => [
    for (final fps in [30, 60])
      if (profiles.any(
        (format) =>
            format.fps == fps &&
            (resolution == RecordingResolution.automatic ||
                format.shortSide == resolution.height),
      ))
        fps,
  ];

  /// Resolution first, then FPS. Never upgrades an explicit target.
  List<RecordingVideoFormat> candidates(RecordingProfile request) {
    final formats = profiles
        .where(
          (format) =>
              format.shortSide <= request.resolution.height &&
              (format.fps == request.fps || format.fps == 30),
        )
        .toList();
    formats.sort((a, b) {
      final resolution = b.shortSide.compareTo(a.shortSide);
      return resolution != 0 ? resolution : b.fps.compareTo(a.fps);
    });
    return formats;
  }
}

@immutable
class AppliedRecordingProfile {
  const AppliedRecordingProfile({
    required this.requested,
    required this.format,
    required this.cameraName,
    required this.lensDirection,
    this.fallbackReason,
    this.stabilizationEnabled = false,
  });
  final RecordingProfile requested;
  final RecordingVideoFormat format;
  final String cameraName;
  final String lensDirection;
  final String? fallbackReason;
  final bool stabilizationEnabled;
}
