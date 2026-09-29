import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_desktop/src/image_stream_ffi.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _CallocNative = Pointer<Void> Function(IntPtr count, IntPtr size);
typedef _CallocDart = Pointer<Void> Function(int count, int size);
typedef _FreeNative = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

final DynamicLibrary _libc = Platform.isWindows
    ? DynamicLibrary.open('ucrtbase.dll')
    : DynamicLibrary.process();
final _CallocDart _calloc = _libc.lookupFunction<_CallocNative, _CallocDart>(
  'calloc',
);
final _FreeDart _free = _libc.lookupFunction<_FreeNative, _FreeDart>('free');

/// A fake native side of the shared-buffer image stream protocol.
class _FakeNativeStream {
  _FakeNativeStream()
    : _buffer = _calloc(
        1,
        sizeOf<ImageStreamBuffer>() + _pixelBytes,
      ).cast<ImageStreamBuffer>();

  static const _pixelBytes = 16;

  final Pointer<ImageStreamBuffer> _buffer;
  final List<int> createdHandles = <int>[];
  int getBufferCalls = 0;
  int registerCalls = 0;
  int unregisterCalls = 0;
  bool _published = false;

  ImageStreamFfi create(int streamHandle) {
    createdHandles.add(streamHandle);
    return ImageStreamFfi.withBindings(
      streamHandle: streamHandle,
      getBuffer: (_) {
        getBufferCalls++;
        return _published ? _buffer.cast<Void>() : nullptr;
      },
      registerCallback: (_, _) => registerCalls++,
      unregisterCallback: (_) => unregisterCalls++,
    );
  }

  /// Publishes a 2x2 BGRA frame with [sequence], as native writeFrame does.
  void publish(int sequence) {
    final header = _buffer.ref;
    header.ready = 0;
    header.width = 2;
    header.height = 2;
    header.bytesPerRow = 8;
    header.format = 0;
    header.sequence = sequence;
    header.ready = 1;
    _published = true;
  }

  void free() => _free(_buffer.cast<Void>());
}

Future<void> _pollWindow() =>
    Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/camera_desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _FakeNativeStream native;
  late CameraDesktopPlugin plugin;
  late List<MethodCall> log;
  late Future<Object?> Function(MethodCall call) nativeHandler;

  setUp(() {
    native = _FakeNativeStream();
    plugin = CameraDesktopPlugin(
      channel: channel,
      imageStreamFfiFactory: native.create,
    );
    log = <MethodCall>[];
    nativeHandler = (call) async => switch (call.method) {
      'startImageStream' => {'streamHandle': 41},
      _ => null,
    };
    messenger.setMockMethodCallHandler(channel, (call) {
      log.add(call);
      return nativeHandler(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    native.free();
  });

  test(
    'FFI frames are delivered and a stale frame is skipped on start',
    () async {
      // Native keeps the last frame of a previous stream in the shared buffer.
      native.publish(5);
      final frames = <CameraImageData>[];
      final subscription = plugin
          .onStreamedFrameAvailable(1)
          .listen(frames.add);
      await _pollWindow();
      expect(native.createdHandles, [41]);
      expect(native.registerCalls, 1);
      expect(frames, isEmpty, reason: 'sequence 5 predates this stream');

      native.publish(6);
      await _pollWindow();
      expect(frames, hasLength(1));
      expect(frames.single.width, 2);
      expect(frames.single.height, 2);
      expect(frames.single.planes.single.bytesPerRow, 8);
      expect(frames.single.planes.single.bytes, hasLength(16));

      await subscription.cancel();
      expect(native.unregisterCalls, 1);
      final stop = log.lastWhere((call) => call.method == 'stopImageStream');
      expect(stop.arguments, {'cameraId': 1, 'streamHandle': 41});
    },
  );

  test('cancel while startImageStream is in flight stops the real handle '
      'and never starts a poller', () async {
    final startReply = Completer<Object?>();
    nativeHandler = (call) async => switch (call.method) {
      'startImageStream' => startReply.future,
      _ => null,
    };
    final subscription = plugin.onStreamedFrameAvailable(3).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    final cancelled = subscription.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(
      log.where((call) => call.method == 'stopImageStream'),
      isEmpty,
      reason: 'the stream handle is not known yet',
    );

    startReply.complete({'streamHandle': 77});
    await cancelled;
    final stop = log.singleWhere((call) => call.method == 'stopImageStream');
    expect(stop.arguments, {'cameraId': 3, 'streamHandle': 77});

    native.publish(1);
    await _pollWindow();
    expect(native.createdHandles, isEmpty);
    expect(native.getBufferCalls, 0);
    expect(native.registerCalls, 0);
  });

  test('dispose stops an FFI poller whose subscriber never cancels', () async {
    final done = Completer<void>();
    plugin.onStreamedFrameAvailable(1).listen((_) {}, onDone: done.complete);
    await _pollWindow();
    expect(native.getBufferCalls, greaterThan(0));

    await plugin.dispose(1);
    await done.future.timeout(const Duration(seconds: 2));
    expect(native.unregisterCalls, 1);
    final callsAfterDispose = native.getBufferCalls;
    native.publish(9);
    await _pollWindow();
    expect(
      native.getBufferCalls,
      callsAfterDispose,
      reason: 'a disposed camera must not be polled',
    );
    expect(log.map((call) => call.method), contains('dispose'));
  });

  test('a failing stopImageStream still releases the FFI reader', () async {
    nativeHandler = (call) async => switch (call.method) {
      'startImageStream' => {'streamHandle': 41},
      'stopImageStream' => throw PlatformException(code: 'camera_not_found'),
      _ => null,
    };
    final subscription = plugin.onStreamedFrameAvailable(1).listen((_) {});
    await _pollWindow();

    await subscription.cancel();
    expect(native.unregisterCalls, 1);
    final callsAfterCancel = native.getBufferCalls;
    native.publish(2);
    await _pollWindow();
    expect(native.getBufferCalls, callsAfterCancel);
  });

  test('a failing startImageStream is reported on the stream', () async {
    nativeHandler = (call) async => switch (call.method) {
      'startImageStream' => throw PlatformException(
        code: 'camera_not_found',
        message: 'No camera found with the given ID',
      ),
      _ => null,
    };
    final error = Completer<Object>();
    final subscription = plugin
        .onStreamedFrameAvailable(1)
        .listen((_) {}, onError: error.complete);
    expect(
      await error.future.timeout(const Duration(seconds: 2)),
      isA<CameraException>().having((e) => e.code, 'code', 'camera_not_found'),
    );
    await subscription.cancel();
    expect(log.where((call) => call.method == 'stopImageStream'), isEmpty);
    expect(native.createdHandles, isEmpty);
  });

  test(
    'restarting a stream delivers only frames newer than the restart',
    () async {
      final first = <CameraImageData>[];
      var subscription = plugin.onStreamedFrameAvailable(1).listen(first.add);
      await _pollWindow();
      native.publish(1);
      await _pollWindow();
      expect(first, hasLength(1));
      await subscription.cancel();

      final second = <CameraImageData>[];
      subscription = plugin.onStreamedFrameAvailable(1).listen(second.add);
      await _pollWindow();
      expect(second, isEmpty, reason: 'frame 1 belongs to the previous stream');
      native.publish(2);
      await _pollWindow();
      expect(second, hasLength(1));
      await subscription.cancel();
    },
  );

  test('ImageStreamFfi.dispose is idempotent and stops polling', () async {
    final reader = native.create(5);
    final controller = StreamController<CameraImageData>();
    reader.start(controller);
    await _pollWindow();
    reader.dispose();
    reader.dispose();
    expect(native.unregisterCalls, 1);
    final calls = native.getBufferCalls;
    reader.start(controller);
    await _pollWindow();
    expect(native.getBufferCalls, calls, reason: 'a disposed reader stays off');
    unawaited(controller.close());
  });
}
