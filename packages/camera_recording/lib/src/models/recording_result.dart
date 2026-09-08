import 'package:camera/camera.dart';
import 'package:camera_recording/src/models/recorded_media_metadata.dart';

/// Finalized original file with best-effort metadata. Inspection never owns it.
class RecordingResult {
  const RecordingResult({required this.file, this.mediaMetadata});
  final XFile file;
  final RecordedMediaMetadata? mediaMetadata;
}
