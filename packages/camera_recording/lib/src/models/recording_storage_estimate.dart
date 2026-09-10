import 'package:camera_recording/src/models/recording_capabilities.dart';
import 'package:camera_recording/src/models/recording_profile.dart';

/// Deterministic bitrate targets and approximate storage for the selected
/// recording profile. Automatic uses the balanced rate only for estimation;
/// it does not force that bitrate on the platform encoder.
abstract final class RecordingStorageEstimate {
  static const int audioBitrate = 128000;

  static int? requestedVideoBitrate(
    RecordingProfile profile,
    RecordingVideoFormat format,
  ) => profile.bitratePreset == RecordingBitratePreset.automatic
      ? null
      : videoBitrate(profile, format);

  static int? requestedAudioBitrate(RecordingProfile profile) =>
      profile.recordAudio &&
          profile.bitratePreset != RecordingBitratePreset.automatic
      ? audioBitrate
      : null;

  static int videoBitrate(
    RecordingProfile profile,
    RecordingVideoFormat format,
  ) {
    final base = switch (format.shortSide) {
      <= 480 => 2500000,
      <= 720 => 5000000,
      <= 1080 => 10000000,
      _ => 35000000,
    };
    final presetMultiplier = switch (profile.bitratePreset) {
      RecordingBitratePreset.automatic || RecordingBitratePreset.balanced => 1,
      RecordingBitratePreset.dataSaver => 0.5,
      RecordingBitratePreset.high => 1.6,
    };
    final frameRateMultiplier = format.fps > 30 ? 1.5 : 1;
    final codecMultiplier = profile.videoCodec == RecordingVideoCodec.hevc
        ? 0.7
        : 1;
    return (base * presetMultiplier * frameRateMultiplier * codecMultiplier)
        .round();
  }

  static double megabytesPerMinute(
    RecordingProfile profile,
    RecordingVideoFormat format,
  ) {
    final totalBitsPerSecond =
        videoBitrate(profile, format) +
        (profile.recordAudio ? audioBitrate : 0);
    return totalBitsPerSecond * 60 / 8 / 1000000;
  }
}
