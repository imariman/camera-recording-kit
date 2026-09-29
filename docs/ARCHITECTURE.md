# Recording-quality architecture

The shared `camera_recording` package defines the Dart-facing quality model and
channel contract. Platform backends perform lens-specific discovery,
configuration, and readback:

| Layer | Responsibility |
| --- | --- |
| Shared API | Validates requests and exposes capabilities, applied state, focus/stabilization controls, and finalized-media inspection. |
| Android CameraX | Selects supported CameraX formats and reports native applied state. |
| iOS AVFoundation | Selects supported AVFoundation formats and reports native applied state. |
| macOS AVFoundation | Provides the same quality boundary plus native pause/resume timing and bounded software stabilization. |

The pipeline keeps three facts separate: the requested profile, the profile
verified as applied to the active camera, and metadata inspected from the
finalized file. A request is never rewritten simply because a lens needs a
fallback. Capability discovery is repeated after a camera switch; a profile
found on one lens is not assumed for another.

Candidate selection for an explicit resolution is resolution-first,
frame-rate-second, and codec-third; an automatic resolution puts the requested
frame rate first. An explicit target is never upgraded while the lens has a
format at or below it; a lens without one uses its closest larger format and
reports `unsupportedProfile`, so a remembered profile does not make a camera
switch fail. An HEVC request retries H.264 at the same size and frame rate
before reducing either dimension. A configured candidate succeeds only when native readback
matches its width, height, frame rate, and selected codec. Permission, access,
and unrelated camera failures are errors, not fallbacks.

Finalized-media inspection is best effort. Missing, malformed, unsupported, or
timed-out inspection data must not invalidate a successfully finalized file.
It reads media metadata and does not rewrite the recording. Known AVC and HEVC
container identifiers are normalized to `h264` and `hevc` in shared metadata.

Releasing or disposing `CameraService` during a recording (for example when the
app enters background) finalizes the recording instead of dropping it. `release()`
and `dispose()` return the finalized file with the configured capture context but
without inspection, so the caller that already awaits them can offer
Save/Discard; the service never deletes it. If a macOS session is disposed
directly while recording, the backend finalizes the file before replying to
Dart, keeps it on disk and logs its path rather than dropping it. On app
termination the macOS backend waits up to five seconds for that finalize
without relying on the main run loop. macOS recordings are fragmented MP4, so
a file whose finalize is cut short (a kill, a crash, a writer failure) stays
readable up to its last one-second fragment.

Focus and exposure default to continuous automatic behavior. A lock is applied
only after convergence and only if both focus and exposure accept it; otherwise
both remain automatic. Stabilization is opt-in and reported active only after
native readback confirms it. The macOS software path supports translation
correction at up to 1080p30, preserves output dimensions with a 6% edge crop,
and does not claim optical, rotational, or rolling-shutter correction.
