## 0.3.0

* A stop rejected by the platform (for example an Android recording finalized
  without a usable file) no longer leaves the service reporting an active
  recording: `stopRecording()`/`finishRecording()` rethrow the error and the
  camera can record, switch or change profile again without a release.
* An exactly applied explicit 480p profile no longer reports
  `fallbackReason: 'unsupportedProfile'`; a sub-HD result for an automatic
  resolution is not a fallback either (#28).
* New `RecordingFallbackReason` constants document the `fallbackReason` values.
* **Behavior change:** without quality selection (a custom `controllerFactory`,
  or Windows/Linux), a profile with an explicit resolution, 60 FPS, a bitrate
  preset, or HEVC now throws a `CameraException` coded
  `unsupportedRecordingProfile` instead of being silently ignored. Both legacy
  paths now map `RecordingProfile.quality` to the same `ResolutionPreset`
  (the unsupported-host path previously always used `ResolutionPreset.max`).
* On quality-selection backends a change to `RecordingProfile.quality` alone no
  longer restarts the camera; the field has no effect there and is documented
  as such.
* `RecordingResolution.automatic` with `fps: 60` now prefers a 60 FPS format
  (1080p60 over 2160p30), matching `frameRates(automatic)`.
* A lens with no format at or below an explicit target now uses its closest
  larger format with `unsupportedProfile` instead of failing, so switching a
  remembered 480p profile to such a lens works. Same-size candidates prefer the
  wider format.
* `setVideoStabilizationEnabled` during a recording now returns false and
  applies the preference when the recording stops, instead of reporting
  success without applying it.
* `initialize(preferredName:)` now takes precedence over the previously
  selected camera. Without a matching name the previous camera is still reused.
* Rapid repeated `switchCamera()` calls advance one camera each.
* `appliedProfile`, `recordingCapabilities`, and zoom/exposure ranges are
  cleared when the controller is released, including after a failed switch
  whose recovery also failed. A throwing `dispose` of the old controller no
  longer aborts a switch or its recovery.
* Finalized metadata keeps a configuration-time `fallbackReason` instead of
  overwriting it with `encodedMismatch`, and a `measured` frame rate within 10%
  of the configured rate is no longer a mismatch.
* `finishRecording()` no longer holds the operation queue during media
  inspection, so `release()`/`dispose()` are not delayed by up to 10 seconds.
* Added `AppliedRecordingProfile.copyWith` and `RecordingVideoFormat.toString`.

## 0.2.0

* **Breaking:** `CameraService.release()` and `CameraService.dispose()` now
  return `Future<RecordingResult?>`. A recording that is active or paused when
  the camera is released is finalized and returned with its configured capture
  context instead of being dropped. They return null when nothing was recording,
  and a failed controller dispose no longer loses an already finalized file.

## 0.1.0

* Initial Git-consumable release: capability-driven recording formats through
  supported 4K/60 modes, H.264/HEVC codec selection, bitrate presets and storage
  estimates, audio and orientation controls, and zoom/exposure/focus controls.
