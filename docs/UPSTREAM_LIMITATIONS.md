# Imported upstream tooling

The upstream `packages/camera_android_camerax` workflow guidance refers to
`.agents/skills` directories, including `check-readiness` and pre-push tooling,
that were not included in the Teleprompter PR #24 fork snapshot. The package's
`AGENTS.md` therefore points to this repository's `tool/validate.sh` and
`tool/test_android_jvm.sh` instead of those skills, and `skills/README.md` is
retained only as imported upstream text. The package does not run the upstream
`dart_skills_lint` validation or its custom publishing-prevention test.

This does not change package runtime behavior, native code, or its Flutter and
CameraX test coverage. Repository validation uses `tool/validate.sh`, the
package's retained Dart tests, and the JVM unit tests run by
`tool/test_android_jvm.sh`.

# Desktop FFI image stream buffer lifetime

`camera_desktop` hands Dart a raw pointer to a native shared frame buffer
(`camera_desktop_get_image_stream_buffer`), and Dart copies the frame outside
any native lock. The Linux and Windows backends (inherited from upstream) and
the macOS double buffer can free or reallocate that buffer when the camera is
disposed or the frame size grows, and the Linux/Windows handle lookup returns
a `Camera*` after releasing the handle-map lock. Making the copy happen under
the native lock needs a new copy-into-Dart-buffer FFI entry point on all three
platforms, which has not been done.

Mitigations in place: Dart stops and disposes the FFI poller before it asks
native to stop the stream or dispose the camera, a disposed reader never polls
again, and the reader re-checks `ready` and `sequence` after its copy and drops
a torn frame. The remaining window is a frame-size change (or a native dispose
not initiated by Dart) during a single in-flight copy.

Between native `startImageStream` and Dart's FFI callback registration, the
native side still delivers frames through the MethodChannel. Dart drops them
because no fallback controller is registered for an FFI stream. The window is
one Dart event-loop turn, so no delivery-mode flag was added.
