import 'package:flutter/foundation.dart';

/// Represents the user's preferred recording-quality intent.
///
/// These values do not guarantee a resolution, frame rate, or codec. They are
/// used only by backends without quality selection; see
/// [RecordingProfile.quality].
enum RecordingQualityIntent { automatic, high, balanced, compact }

/// Explicit recording targets; Automatic is resolved independently per lens.
enum RecordingResolution { automatic, standardDefinition, hd, fullHd, ultraHd }

/// Optional encoder bitrate overrides. Automatic leaves selection to the OS.
enum RecordingBitratePreset { automatic, dataSaver, balanced, high }

/// Video codecs offered only when the exact camera format advertises support.
enum RecordingVideoCodec { h264, hevc }

extension RecordingResolutionDimensions on RecordingResolution {
  int get height => switch (this) {
    RecordingResolution.automatic => 2160,
    RecordingResolution.standardDefinition => 480,
    RecordingResolution.hd => 720,
    RecordingResolution.fullHd => 1080,
    RecordingResolution.ultraHd => 2160,
  };
}

@immutable
class RecordingProfile {
  const RecordingProfile({
    this.recordAudio = true,
    this.quality = RecordingQualityIntent.automatic,
    this.resolution = RecordingResolution.automatic,
    this.fps = 30,
    this.bitratePreset = RecordingBitratePreset.automatic,
    this.videoCodec = RecordingVideoCodec.h264,
    this.lockOrientation = false,
  });

  /// Whether the camera controller records audio with the video stream.
  final bool recordAudio;

  /// Coarse quality intent for backends without quality selection.
  ///
  /// It is used only when `CameraService.supportsQualitySelection` is false
  /// (a custom `controllerFactory` or an unsupported host such as Windows or
  /// Linux), where it maps to a `ResolutionPreset` through
  /// `CameraService.resolutionPresetFor`. On the Android, iOS, and macOS
  /// quality backends [resolution], [fps], [bitratePreset], and [videoCodec]
  /// select the format and this value has no effect; changing only [quality]
  /// there updates the remembered profile without restarting the camera.
  final RecordingQualityIntent quality;
  final RecordingResolution resolution;
  final int fps;
  final RecordingBitratePreset bitratePreset;
  final RecordingVideoCodec videoCodec;
  final bool lockOrientation;

  RecordingProfile copyWith({
    bool? recordAudio,
    RecordingQualityIntent? quality,
    RecordingResolution? resolution,
    int? fps,
    RecordingBitratePreset? bitratePreset,
    RecordingVideoCodec? videoCodec,
    bool? lockOrientation,
  }) => RecordingProfile(
    recordAudio: recordAudio ?? this.recordAudio,
    quality: quality ?? this.quality,
    resolution: resolution ?? this.resolution,
    fps: fps ?? this.fps,
    bitratePreset: bitratePreset ?? this.bitratePreset,
    videoCodec: videoCodec ?? this.videoCodec,
    lockOrientation: lockOrientation ?? this.lockOrientation,
  );

  Map<String, dynamic> toJson() {
    return {
      'version': 3,
      'recordAudio': recordAudio,
      'quality': quality.name,
      'resolution': resolution.name,
      'fps': fps,
      'bitratePreset': bitratePreset.name,
      'videoCodec': videoCodec.name,
      'lockOrientation': lockOrientation,
    };
  }

  factory RecordingProfile.fromJson(Map<String, dynamic> json) {
    final qualityName = json['quality'];

    return RecordingProfile(
      resolution: RecordingResolution.values.firstWhere(
        (value) => value.name == json['resolution'],
        orElse: () => RecordingResolution.automatic,
      ),
      fps: json['fps'] == 60 ? 60 : 30,
      recordAudio: json['recordAudio'] is bool
          ? json['recordAudio'] as bool
          : true,
      quality: RecordingQualityIntent.values.firstWhere(
        (quality) => quality.name == qualityName,
        orElse: () => RecordingQualityIntent.automatic,
      ),
      bitratePreset: RecordingBitratePreset.values.firstWhere(
        (value) => value.name == json['bitratePreset'],
        orElse: () => RecordingBitratePreset.automatic,
      ),
      videoCodec: RecordingVideoCodec.values.firstWhere(
        (value) => value.name == json['videoCodec'],
        orElse: () => RecordingVideoCodec.h264,
      ),
      lockOrientation: json['lockOrientation'] is bool
          ? json['lockOrientation'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RecordingProfile &&
        other.recordAudio == recordAudio &&
        other.quality == quality &&
        other.resolution == resolution &&
        other.fps == fps &&
        other.bitratePreset == bitratePreset &&
        other.videoCodec == videoCodec &&
        other.lockOrientation == lockOrientation;
  }

  @override
  int get hashCode => Object.hash(
    recordAudio,
    quality,
    resolution,
    fps,
    bitratePreset,
    videoCodec,
    lockOrientation,
  );
}
