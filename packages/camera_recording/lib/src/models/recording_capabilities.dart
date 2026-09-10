import 'package:flutter/foundation.dart';

import 'package:camera_recording/src/models/recording_profile.dart';

@immutable
class RecordingVideoFormat {
  const RecordingVideoFormat({
    required this.width,
    required this.height,
    required this.fps,
    this.codecs = const {RecordingVideoCodec.h264},
  });
  final int width;
  final int height;
  final int fps;
  final Set<RecordingVideoCodec> codecs;

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
    final rawCodecs = map['codecs'];
    final rawCodec = map['codec'];
    final codecs = <RecordingVideoCodec>{};
    if (rawCodecs is List) {
      for (final entry in rawCodecs) {
        for (final codec in RecordingVideoCodec.values) {
          if (entry == codec.name) codecs.add(codec);
        }
      }
    }
    for (final codec in RecordingVideoCodec.values) {
      if (rawCodec == codec.name) codecs.add(codec);
    }
    if (codecs.isEmpty && rawCodecs == null && rawCodec == null) {
      codecs.add(RecordingVideoCodec.h264);
    }
    if (codecs.isEmpty) return null;
    return RecordingVideoFormat(
      width: width,
      height: height,
      fps: rounded,
      codecs: Set.unmodifiable(codecs),
    );
  }

  bool supportsCodec(RecordingVideoCodec codec) => codecs.contains(codec);

  RecordingVideoFormat mergeCodecs(RecordingVideoFormat other) =>
      RecordingVideoFormat(
        width: width,
        height: height,
        fps: fps,
        codecs: Set.unmodifiable({...codecs, ...other.codecs}),
      );

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
    final formats = <RecordingVideoFormat>[];
    final raw = json['profiles'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final value = RecordingVideoFormat.tryParse(entry);
        if (value == null || value.shortSide > 2160) continue;
        final duplicateIndex = formats.indexOf(value);
        if (duplicateIndex < 0) {
          formats.add(value);
        } else {
          formats[duplicateIndex] = formats[duplicateIndex].mergeCodecs(value);
        }
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

  Set<RecordingVideoCodec> codecs({
    required RecordingResolution resolution,
    required int fps,
  }) => {
    for (final format in profiles)
      if (format.fps == fps &&
          (resolution == RecordingResolution.automatic ||
              format.shortSide == resolution.height))
        ...format.codecs,
  };

  /// Resolution first, then FPS, then the requested codec. Never upgrades an
  /// explicit target. HEVC requests retain an H.264 attempt for the same exact
  /// format before falling back to a lower resolution or frame rate.
  List<RecordingVideoFormat> candidates(RecordingProfile request) {
    final formats = <RecordingVideoFormat>[];
    for (final format in profiles) {
      if (format.shortSide > request.resolution.height ||
          (format.fps != request.fps && format.fps != 30)) {
        continue;
      }
      if (format.supportsCodec(request.videoCodec)) {
        formats.add(
          RecordingVideoFormat(
            width: format.width,
            height: format.height,
            fps: format.fps,
            codecs: {request.videoCodec},
          ),
        );
      }
      if (request.videoCodec == RecordingVideoCodec.hevc &&
          format.supportsCodec(RecordingVideoCodec.h264)) {
        formats.add(
          RecordingVideoFormat(
            width: format.width,
            height: format.height,
            fps: format.fps,
          ),
        );
      }
    }
    formats.sort((a, b) {
      final resolution = b.shortSide.compareTo(a.shortSide);
      if (resolution != 0) return resolution;
      final frameRate = b.fps.compareTo(a.fps);
      if (frameRate != 0) return frameRate;
      final aPreferred = a.supportsCodec(request.videoCodec) ? 1 : 0;
      final bPreferred = b.supportsCodec(request.videoCodec) ? 1 : 0;
      return bPreferred.compareTo(aPreferred);
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
