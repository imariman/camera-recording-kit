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

Candidate selection is resolution-first and frame-rate-second. A configured
candidate succeeds only when native readback matches its width, height, and
frame rate. Permission, access, and unrelated camera failures are errors, not
fallbacks.

Finalized-media inspection is best effort. Missing, malformed, unsupported, or
timed-out inspection data must not invalidate a successfully finalized file.
It reads media metadata and does not rewrite the recording.

Focus and exposure default to continuous automatic behavior. A lock is applied
only after convergence and only if both focus and exposure accept it; otherwise
both remain automatic. Stabilization is opt-in and reported active only after
native readback confirms it. The macOS software path supports translation
correction at up to 1080p30, preserves output dimensions with a 6% edge crop,
and does not claim optical, rotational, or rolling-shutter correction.
