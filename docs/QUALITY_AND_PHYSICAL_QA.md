# Recording quality and physical QA

Automated tests establish contract and regression behavior. They do not prove
camera hardware support or recorded-image quality. Run `tool/validate.sh` for
the automated package suite, then complete this release acceptance matrix on
the devices and lenses your product supports.

| Area | Acceptance check |
| --- | --- |
| Capabilities | Compare advertised 720p, 1080p, and 4K profiles at 30/60 FPS with each physical lens. Unsupported choices must be absent or yield an explicit fallback. |
| Applied format | Record supported combinations and confirm native readback matches the selected recorder format. Verify resolution-first fallback after a rejected candidate. |
| Final media | Inspect dimensions, frame rate, duration, orientation, codec, bitrate, file size, MIME type, and audio. Verify portrait and landscape playback. |
| Focus and exposure | Check continuous defaults, point focus, lock after convergence, and safe automatic behavior when locking is unavailable. |
| Stabilization | Test off/on on supported profiles, confirm applied-state readback, and compare crop and field of view. On macOS, confirm 4K or 60 FPS reports it unavailable without lowering the requested profile. |
| Long recording | Record for at least 20 minutes and check thermal behavior, A/V synchronization, finalization, storage handling, and later camera reuse. |
| Pause/resume | Where supported, exercise repeated cycles and confirm one playable file with continuous timing and correct duration. |
| Lifecycle | Exercise interruption and background/foreground transitions during initialization, recording, pause, and finalization. Check for stuck camera state, duplicate starts, and orphaned files. |
| Native baseline | Compare the same scene/profile with the device's native camera app for framing, orientation, audio, focus/exposure, cadence, codec, bitrate, and stabilization crop. |

The native-camera comparison is diagnostic. Proprietary camera apps can use
private HDR, lens fusion, denoising, stabilization, encoder tuning, and thermal
policies unavailable to CameraX or AVFoundation.

## macOS native tests and limits

`tool/test_macos_camera_native.py` compiles and runs synthetic XCTest coverage
against the native writer and image-processing code without a Flutter app or a
physical camera. It requires macOS, full Xcode selected by `xcode-select`, and
the macOS SDK; run directly, it exits with an error on other hosts or with only
the Command Line Tools. `tool/validate.sh` checks for full Xcode and skips it
with a message when it is unavailable.

Synthetic tests exercise media finalization and Vision/Core Image behavior;
they do not establish webcam support, permission handling, visual quality, or
sustained capture performance. Test built-in and external/Continuity cameras,
unplug/reconnect behavior, and camera/microphone permission denial on real
hardware before release. On macOS, unplugging the camera during a recording
should finalize the file, emit a `cameraError`, and let `stopVideoRecording`
return that file; quitting the app while recording should leave a playable
file; with an external microphone selected as the system input, recordings
should use it.
