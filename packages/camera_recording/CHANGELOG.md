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
