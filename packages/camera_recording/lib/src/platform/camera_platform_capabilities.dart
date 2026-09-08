import 'dart:io';

/// Camera behavior available on the current host.
abstract interface class CameraPlatformCapabilities {
  const CameraPlatformCapabilities();

  static CameraPlatformCapabilities get current => Platform.isMacOS
      ? DefaultCameraPlatformCapabilities.macos
      : DefaultCameraPlatformCapabilities.cameraCapable;

  bool get supportsRecordingPause;
  bool get usesDesktopCameraBackend;
  bool get supportsFocusAndExposureControls;
  bool get supportsVideoStabilization;
}

/// Default profiles used when an embedding application does not supply policy.
final class DefaultCameraPlatformCapabilities
    implements CameraPlatformCapabilities {
  const DefaultCameraPlatformCapabilities({
    required this.supportsRecordingPause,
    required this.usesDesktopCameraBackend,
    required this.supportsFocusAndExposureControls,
    required this.supportsVideoStabilization,
  });

  static const cameraCapable = DefaultCameraPlatformCapabilities(
    supportsRecordingPause: true,
    usesDesktopCameraBackend: false,
    supportsFocusAndExposureControls: true,
    supportsVideoStabilization: true,
  );

  static const macos = DefaultCameraPlatformCapabilities(
    supportsRecordingPause: true,
    usesDesktopCameraBackend: true,
    supportsFocusAndExposureControls: true,
    supportsVideoStabilization: true,
  );

  @override
  final bool supportsRecordingPause;
  @override
  final bool usesDesktopCameraBackend;
  @override
  final bool supportsFocusAndExposureControls;
  @override
  final bool supportsVideoStabilization;
}
