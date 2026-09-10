// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.content.Context;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.TotalCaptureResult;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Range;
import android.util.Size;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2CameraControl;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraControl;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.DynamicRange;
import androidx.camera.core.FocusMeteringAction;
import androidx.camera.core.Preview;
import androidx.camera.core.ResolutionInfo;
import androidx.camera.core.SurfaceOrientedMeteringPointFactory;
import androidx.camera.core.UseCase;
import androidx.camera.core.impl.EncoderProfilesProxy;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.video.EncoderProfilesResolver;
import androidx.camera.video.Quality;
import androidx.camera.video.Recorder;
import androidx.camera.video.VideoCapabilities;
import androidx.camera.video.VideoCapture;
import androidx.core.content.ContextCompat;
import com.google.common.util.concurrent.ListenableFuture;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/** Host-side implementation for the recording quality extension channel. */
@OptIn(markerClass = ExperimentalCamera2Interop.class)
final class RecordingQualityController implements MethodChannel.MethodCallHandler {
  static final String CHANNEL_NAME =
      "plugins.flutter.io/camera_android_camerax/recording_quality";
  private static final int[] RECORDING_FRAME_RATES = {30, 60};
  private static final long FOCUS_TIMEOUT_SECONDS = 2L;
  private static final long APPLIED_PROFILE_TIMEOUT_MILLIS = 2_000L;
  private static final long APPLIED_PROFILE_POLL_MILLIS = 50L;
  private static final String CODEC_H264 = "h264";
  private static final String CODEC_HEVC = "hevc";

  @NonNull private final Context context;
  @NonNull private final ExecutorService mediaExecutor = Executors.newSingleThreadExecutor();
  @NonNull
  private final ScheduledExecutorService focusTimeoutExecutor =
      Executors.newSingleThreadScheduledExecutor();
  @NonNull private final Map<Preview, Long> previewIds = new IdentityHashMap<>();
  @NonNull private final Map<CameraSelector, CameraInfo> selectedCameraInfos = new IdentityHashMap<>();
  @NonNull
  private final Map<VideoCapture<?>, RecordingConvergenceTracker> convergenceTrackers =
      new IdentityHashMap<>();
  @NonNull
  private final Map<CameraControl, RecordingConvergenceTracker> cameraControlTrackers =
      new IdentityHashMap<>();
  @NonNull private final Map<Long, BoundRecordingCamera> boundCameras = new HashMap<>();

  @Nullable private MethodChannel channel;
  @Nullable private Handler mainHandler;

  RecordingQualityController(@NonNull Context context) {
    final Context applicationContext = context.getApplicationContext();
    this.context = applicationContext == null ? context : applicationContext;
  }

  void setUp(@NonNull BinaryMessenger messenger) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
    channel = new MethodChannel(messenger, CHANNEL_NAME);
    channel.setMethodCallHandler(this);
  }

  void tearDown() {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
    synchronized (this) {
      previewIds.clear();
      selectedCameraInfos.clear();
      convergenceTrackers.clear();
      cameraControlTrackers.clear();
      boundCameras.clear();
    }
    if (mainHandler != null) {
      mainHandler.removeCallbacksAndMessages(null);
      mainHandler = null;
    }
    mediaExecutor.shutdownNow();
    focusTimeoutExecutor.shutdownNow();
  }

  synchronized void registerPreview(@NonNull Preview preview, long cameraId) {
    if (boundCameras.isEmpty()) {
      previewIds.clear();
      convergenceTrackers.clear();
      cameraControlTrackers.clear();
    }
    previewIds.put(preview, cameraId);
  }

  synchronized void unregisterPreview(@NonNull Preview preview) {
    final Long cameraId = previewIds.remove(preview);
    if (cameraId != null) {
      final BoundRecordingCamera removedCamera = boundCameras.remove(cameraId);
      if (removedCamera != null) {
        cameraControlTrackers.remove(removedCamera.camera.getCameraControl());
        if (removedCamera.videoCapture != null) {
          convergenceTrackers.remove(removedCamera.videoCapture);
        }
      }
    }
  }

  synchronized void registerCameraSelector(
      @NonNull CameraSelector selector, @Nullable CameraInfo cameraInfo) {
    if (cameraInfo != null) {
      selectedCameraInfos.put(selector, cameraInfo);
    }
  }

  @NonNull
  RecordingConvergenceTracker createConvergenceTracker() {
    return new RecordingConvergenceTracker();
  }

  synchronized void registerVideoCapture(
      @NonNull VideoCapture<?> videoCapture,
      @NonNull RecordingConvergenceTracker convergenceTracker) {
    convergenceTrackers.put(videoCapture, convergenceTracker);
  }

  synchronized void onFocusMeteringStarted(@NonNull CameraControl cameraControl) {
    final RecordingConvergenceTracker tracker = cameraControlTrackers.get(cameraControl);
    if (tracker != null) {
      tracker.reset();
    }
  }

  synchronized void onFocusMeteringCancelled(@NonNull CameraControl cameraControl) {
    final RecordingConvergenceTracker tracker = cameraControlTrackers.get(cameraControl);
    if (tracker != null) {
      tracker.reset();
    }
  }

  synchronized void registerBoundCamera(
      @NonNull CameraSelector selector,
      @NonNull List<? extends UseCase> useCases,
      @NonNull Camera camera) {
    Long cameraId = null;
    VideoCapture<?> videoCapture = null;
    for (UseCase useCase : useCases) {
      if (useCase instanceof Preview) {
        cameraId = previewIds.get((Preview) useCase);
      } else if (useCase instanceof VideoCapture<?>) {
        videoCapture = (VideoCapture<?>) useCase;
      }
    }
    if (cameraId == null) {
      return;
    }
    final CameraInfo selectedCameraInfo = selectedCameraInfos.get(selector);
    final RecordingConvergenceTracker convergenceTracker =
        videoCapture == null ? null : convergenceTrackers.get(videoCapture);
    if (convergenceTracker != null) {
      cameraControlTrackers.put(camera.getCameraControl(), convergenceTracker);
    }
    boundCameras.put(
        cameraId,
        new BoundRecordingCamera(
            camera,
            selectedCameraInfo == null ? camera.getCameraInfo() : selectedCameraInfo,
            videoCapture,
            convergenceTracker));
  }

  synchronized void clearBoundCameras() {
    boundCameras.clear();
    cameraControlTrackers.clear();
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    try {
      switch (call.method) {
        case "recordingQualityCapabilities":
          recordingQualityCapabilities(requireString(call, "cameraName"), result);
          break;
        case "recordingQualityApplied":
          recordingQualityApplied(requireLong(call, "cameraId"), result);
          break;
        case "setRecordingVideoCodec":
          setRecordingVideoCodec(requireString(call, "codec"), result);
          break;
        case "inspectRecordingMedia":
          inspectRecordingMedia(requireString(call, "path"), result);
          break;
        case "waitForRecordingFocus":
          waitForRecordingFocus(requireLong(call, "cameraId"), result);
          break;
        default:
          result.notImplemented();
          break;
      }
    } catch (IllegalArgumentException exception) {
      sendError(result, "invalidArguments", exception.getMessage(), exception);
    }
  }

  private void recordingQualityCapabilities(
      @NonNull String cameraName, @NonNull MethodChannel.Result result) {
    final ListenableFuture<ProcessCameraProvider> providerFuture =
        ProcessCameraProvider.getInstance(context);
    providerFuture.addListener(
        () -> {
          try {
            final ProcessCameraProvider provider = providerFuture.get();
            final CameraInfo cameraInfo = findCameraInfo(provider, cameraName);
            if (cameraInfo == null) {
              result.error(
                  "cameraNotFound",
                  "No CameraX camera matches camera name " + cameraName + ".",
                  null);
              return;
            }
            result.success(buildCapabilities(cameraInfo));
          } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            sendError(result, "recordingQualityFailure", "Camera lookup was interrupted.", exception);
          } catch (ExecutionException exception) {
            sendError(
                result,
                "recordingQualityFailure",
                "CameraX could not enumerate recording capabilities.",
                exception.getCause() == null ? exception : exception.getCause());
          } catch (RuntimeException exception) {
            sendError(
                result,
                "recordingQualityFailure",
                "CameraX could not inspect recording capabilities.",
                exception);
          }
        },
        ContextCompat.getMainExecutor(context));
  }

  @Nullable
  private CameraInfo findCameraInfo(
      @NonNull ProcessCameraProvider provider, @NonNull String cameraName) {
    for (CameraInfo cameraInfo : provider.getAvailableCameraInfos()) {
      if (cameraName.equals(Camera2CameraInfo.from(cameraInfo).getCameraId())) {
        return cameraInfo;
      }
    }
    return null;
  }

  @NonNull
  private Map<String, Object> buildCapabilities(@NonNull CameraInfo cameraInfo) {
    final Recorder capabilityRecorder = new Recorder.Builder().build();
    final int capabilitiesSource = capabilityRecorder.getVideoCapabilitiesSource();
    final VideoCapabilities videoCapabilities =
        capabilityRecorder.getMediaCapabilities(cameraInfo, capabilitiesSource);
    final EncoderProfilesResolver profilesResolver =
        capabilityRecorder.getEncoderProfilesResolver(cameraInfo, capabilitiesSource);
    final Set<Range<Integer>> cameraFrameRateRanges = cameraInfo.getSupportedFrameRateRanges();
    final List<Map<String, Object>> profiles = new ArrayList<>();

    for (Quality quality : videoCapabilities.getSupportedQualities(DynamicRange.SDR)) {
      final Size resolution = videoCapabilities.getResolution(quality, DynamicRange.SDR);
      final EncoderProfilesProxy encoderProfiles =
          profilesResolver.getProfiles(quality, DynamicRange.SDR);
      if (resolution == null || encoderProfiles == null) {
        continue;
      }
      for (int fps : RECORDING_FRAME_RATES) {
        if (!hasFrameRateRangeContaining(cameraFrameRateRanges, fps)
            || !sensorSupportsFrameRate(cameraInfo, resolution, fps)
            || !hasCompatibleEncoderProfile(encoderProfiles, resolution, fps)) {
          continue;
        }
        final Map<String, Object> profile = new HashMap<>();
        profile.put("width", resolution.getWidth());
        profile.put("height", resolution.getHeight());
        profile.put("fps", fps);
        profile.put("codecs", supportedRecordingCodecs());
        if (!profiles.contains(profile)) {
          profiles.add(profile);
        }
      }
    }

    profiles.sort(
        Comparator.<Map<String, Object>>comparingLong(
                profile ->
                    ((Integer) profile.get("width")).longValue()
                        * ((Integer) profile.get("height")).longValue())
            .reversed()
            .thenComparing(
                profile -> (Integer) profile.get("fps"), Comparator.reverseOrder()));

    final Map<String, Object> capabilities = new HashMap<>();
    capabilities.put("profiles", profiles);
    capabilities.put("supportsFocusLock", supportsFocusLock(cameraInfo));
    capabilities.put("supportsExposureLock", supportsExposureLock(cameraInfo));
    return capabilities;
  }

  @NonNull
  static List<String> supportedRecordingCodecs() {
    // CameraX Recorder 1.6.1 selects the eventual codec internally and has no
    // public codec-selection API. Restrict the extension contract to AVC so an
    // HEVC preference can never be silently ignored.
    return Collections.singletonList(CODEC_H264);
  }

  private void setRecordingVideoCodec(
      @NonNull String codec, @NonNull MethodChannel.Result result) {
    if (CODEC_H264.equals(codec)) {
      result.success(null);
      return;
    }
    if (CODEC_HEVC.equals(codec)) {
      result.error(
          "unsupportedVideoCodec",
          "CameraX Recorder does not expose a public API for selecting HEVC video.",
          null);
      return;
    }
    throw new IllegalArgumentException("codec must be h264 or hevc.");
  }

  private boolean hasFrameRateRangeContaining(
      @NonNull Set<Range<Integer>> availableRanges, int fps) {
    for (Range<Integer> range : availableRanges) {
      if (range.contains(fps)) {
        return true;
      }
    }
    return false;
  }

  private boolean sensorSupportsFrameRate(
      @NonNull CameraInfo cameraInfo, @NonNull Size resolution, int fps) {
    final StreamConfigurationMap configurationMap =
        Camera2CameraInfo.from(cameraInfo)
            .getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    if (configurationMap == null) {
      return false;
    }
    final Size[] recordingSizes = configurationMap.getOutputSizes(MediaRecorder.class);
    if (recordingSizes == null) {
      return false;
    }
    boolean exposesResolution = false;
    for (Size recordingSize : recordingSizes) {
      if (resolution.equals(recordingSize)) {
        exposesResolution = true;
        break;
      }
    }
    if (!exposesResolution) {
      return false;
    }
    final long minimumFrameDuration =
        getMinimumRecordingFrameDuration(configurationMap, resolution);
    return minimumFrameDuration > 0
        && 1_000_000_000.0 / minimumFrameDuration + 0.001 >= fps;
  }

  private long getMinimumRecordingFrameDuration(
      @NonNull StreamConfigurationMap configurationMap, @NonNull Size resolution) {
    try {
      return configurationMap.getOutputMinFrameDuration(MediaRecorder.class, resolution);
    } catch (IllegalArgumentException exception) {
      return 0L;
    }
  }

  private boolean hasCompatibleEncoderProfile(
      @NonNull EncoderProfilesProxy encoderProfiles, @NonNull Size resolution, int fps) {
    for (EncoderProfilesProxy.VideoProfileProxy videoProfile : encoderProfiles.getVideoProfiles()) {
      if (videoProfile.getWidth() != resolution.getWidth()
          || videoProfile.getHeight() != resolution.getHeight()) {
        continue;
      }
      if (encoderAccepts(
          videoProfile.getMediaType(), resolution.getWidth(), resolution.getHeight(), fps)) {
        return true;
      }
    }
    return false;
  }

  private boolean encoderAccepts(
      @NonNull String mimeType, int width, int height, int fps) {
    try {
      for (MediaCodecInfo codecInfo : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
        if (!codecInfo.isEncoder()) {
          continue;
        }
        for (String supportedType : codecInfo.getSupportedTypes()) {
          if (!mimeType.equalsIgnoreCase(supportedType)) {
            continue;
          }
          final MediaCodecInfo.VideoCapabilities videoCapabilities =
              codecInfo.getCapabilitiesForType(supportedType).getVideoCapabilities();
          if (videoCapabilities != null
              && videoCapabilities.areSizeAndRateSupported(width, height, fps)) {
            return true;
          }
        }
      }
    } catch (IllegalArgumentException | IllegalStateException exception) {
      // Failure to verify encoder constraints means this combination must not
      // be advertised as supported.
      return false;
    }
    return false;
  }

  private boolean supportsFocusLock(@NonNull CameraInfo cameraInfo) {
    final FocusMeteringAction action = createFocusCapabilityAction();
    return cameraInfo.isFocusMeteringSupported(action);
  }

  private boolean supportsExposureLock(@NonNull CameraInfo cameraInfo) {
    return Boolean.TRUE.equals(
        Camera2CameraInfo.from(cameraInfo)
            .getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE));
  }

  private void recordingQualityApplied(long cameraId, @NonNull MethodChannel.Result result) {
    waitForAppliedProfile(
        cameraId, result, SystemClock.elapsedRealtime() + APPLIED_PROFILE_TIMEOUT_MILLIS);
  }

  private void waitForAppliedProfile(
      long cameraId, @NonNull MethodChannel.Result result, long deadlineMillis) {
    final BoundRecordingCamera boundCamera;
    synchronized (this) {
      boundCamera = boundCameras.get(cameraId);
    }
    if (boundCamera == null) {
      result.error(
          "cameraNotBound",
          "Camera " + cameraId + " is not bound to a recording session.",
          null);
      return;
    }
    final VideoCapture<?> videoCapture = boundCamera.videoCapture;
    if (videoCapture == null) {
      result.error(
          "unsupportedRecordingProfile",
          "CameraX did not apply the requested recording profile.",
          null);
      return;
    }

    final ResolutionInfo resolutionInfo = videoCapture.getResolutionInfo();
    final Object output = videoCapture.getOutput();
    final int encoderFrameRate =
        output instanceof Recorder ? ((Recorder) output).getVideoEncodingFrameRate() : 0;
    if (resolutionInfo == null || encoderFrameRate <= 0) {
      if (SystemClock.elapsedRealtime() < deadlineMillis) {
        getMainHandler()
            .postDelayed(
                () -> waitForAppliedProfile(cameraId, result, deadlineMillis),
                APPLIED_PROFILE_POLL_MILLIS);
        return;
      }
      result.error(
          "unsupportedRecordingProfile",
          "CameraX did not finish applying the requested resolution and encoder frame rate.",
          null);
      return;
    }

    final Size resolution = resolutionInfo.getResolution();
    final Map<String, Object> applied = new HashMap<>();
    applied.put("width", resolution.getWidth());
    applied.put("height", resolution.getHeight());
    applied.put("fps", encoderFrameRate);
    // Recorder does not expose the selected encoder codec. Do not infer it
    // from the accepted preference; finalized container inspection is the
    // first authoritative readback point.
    applied.put("codec", null);
    applied.put("codecSource", "unavailableUntilFinalized");
    applied.put("stabilizationEnabled", isStabilizationEnabled(boundCamera, videoCapture));
    result.success(applied);
  }

  @NonNull
  private Handler getMainHandler() {
    if (mainHandler == null) {
      mainHandler = new Handler(Looper.getMainLooper());
    }
    return mainHandler;
  }

  private boolean isStabilizationEnabled(
      @NonNull BoundRecordingCamera boundCamera, @NonNull VideoCapture<?> videoCapture) {
    final Integer camera2Mode =
        Camera2CameraControl.from(boundCamera.camera.getCameraControl())
            .getCaptureRequestOptions()
            .getCaptureRequestOption(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE);
    if (camera2Mode != null) {
      return camera2Mode != CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF;
    }
    return videoCapture.isVideoStabilizationEnabled();
  }

  private void inspectRecordingMedia(
      @NonNull String path, @NonNull MethodChannel.Result result) {
    mediaExecutor.execute(
        () -> {
          try {
            final Map<String, Object> metadata = new RecordingMediaInspector().inspect(new File(path));
            ContextCompat.getMainExecutor(context).execute(() -> result.success(metadata));
          } catch (RecordingMediaInspector.MediaInspectionException exception) {
            ContextCompat.getMainExecutor(context)
                .execute(
                    () ->
                        result.error(
                            exception.code,
                            exception.getMessage(),
                            errorDetails(exception.getCause())));
          } catch (RuntimeException exception) {
            ContextCompat.getMainExecutor(context)
                .execute(
                    () ->
                        sendError(
                            result,
                            "recordingMediaInvalid",
                            "The finalized recording metadata could not be read.",
                            exception));
          }
        });
  }

  private void waitForRecordingFocus(long cameraId, @NonNull MethodChannel.Result result) {
    final BoundRecordingCamera boundCamera;
    synchronized (this) {
      boundCamera = boundCameras.get(cameraId);
    }
    if (boundCamera == null) {
      result.error(
          "cameraNotBound",
          "Camera " + cameraId + " is not bound to a recording session.",
          null);
      return;
    }

    if (!boundCamera.cameraInfo.isFocusMeteringSupported(createFocusCapabilityAction())) {
      result.success(false);
      return;
    }
    if (boundCamera.convergenceTracker == null) {
      result.success(false);
      return;
    }
    boundCamera.convergenceTracker.waitForConvergence(
        result,
        ContextCompat.getMainExecutor(context),
        focusTimeoutExecutor,
        FOCUS_TIMEOUT_SECONDS);
  }

  @NonNull
  private FocusMeteringAction createFocusCapabilityAction() {
    final SurfaceOrientedMeteringPointFactory pointFactory =
        new SurfaceOrientedMeteringPointFactory(1.0f, 1.0f);
    return new FocusMeteringAction.Builder(
            pointFactory.createPoint(0.5f, 0.5f), FocusMeteringAction.FLAG_AF)
        .build();
  }

  @NonNull
  private static String requireString(@NonNull MethodCall call, @NonNull String key) {
    final Object value = call.argument(key);
    if (!(value instanceof String) || ((String) value).isEmpty()) {
      throw new IllegalArgumentException(key + " must be a non-empty String.");
    }
    return (String) value;
  }

  private static long requireLong(@NonNull MethodCall call, @NonNull String key) {
    final Object value = call.argument(key);
    if (!(value instanceof Number)) {
      throw new IllegalArgumentException(key + " must be a number.");
    }
    return ((Number) value).longValue();
  }

  private static void sendError(
      @NonNull MethodChannel.Result result,
      @NonNull String code,
      @NonNull String message,
      @NonNull Throwable throwable) {
    result.error(code, message, errorDetails(throwable));
  }

  @NonNull
  private static Map<String, Object> errorDetails(@Nullable Throwable throwable) {
    final Map<String, Object> details = new HashMap<>();
    if (throwable != null) {
      details.put("type", throwable.getClass().getName());
      if (throwable.getMessage() != null) {
        details.put("cause", throwable.getMessage());
      }
    }
    return details;
  }

  private static final class BoundRecordingCamera {
    @NonNull final Camera camera;
    @NonNull final CameraInfo cameraInfo;
    @Nullable final VideoCapture<?> videoCapture;
    @Nullable final RecordingConvergenceTracker convergenceTracker;

    BoundRecordingCamera(
        @NonNull Camera camera,
        @NonNull CameraInfo cameraInfo,
        @Nullable VideoCapture<?> videoCapture,
        @Nullable RecordingConvergenceTracker convergenceTracker) {
      this.camera = camera;
      this.cameraInfo = cameraInfo;
      this.videoCapture = videoCapture;
      this.convergenceTracker = convergenceTracker;
    }
  }

  static final class RecordingConvergenceTracker
      extends CameraCaptureSession.CaptureCallback {
    @Nullable private Boolean focusConverged;
    @Nullable private Boolean exposureConverged;
    @NonNull private final List<ConvergenceWaiter> waiters = new ArrayList<>();

    @Override
    public void onCaptureCompleted(
        @NonNull CameraCaptureSession session,
        @NonNull CaptureRequest request,
        @NonNull TotalCaptureResult result) {
      final Integer afState = result.get(CaptureResult.CONTROL_AF_STATE);
      final Integer aeState = result.get(CaptureResult.CONTROL_AE_STATE);
      final List<ConvergenceWaiter> completedWaiters;
      synchronized (this) {
        if (afState != null) {
          focusConverged =
              afState == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED
                  || afState == CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED;
        }
        if (aeState != null) {
          exposureConverged =
              aeState == CaptureResult.CONTROL_AE_STATE_CONVERGED
                  || aeState == CaptureResult.CONTROL_AE_STATE_LOCKED
                  || aeState == CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED;
        }
        if (!isConverged()) {
          return;
        }
        completedWaiters = new ArrayList<>(waiters);
        waiters.clear();
      }
      for (ConvergenceWaiter waiter : completedWaiters) {
        waiter.complete(true);
      }
    }

    synchronized void reset() {
      focusConverged = null;
      exposureConverged = null;
    }

    void waitForConvergence(
        @NonNull MethodChannel.Result result,
        @NonNull java.util.concurrent.Executor resultExecutor,
        @NonNull ScheduledExecutorService timeoutExecutor,
        long timeoutSeconds) {
      final ConvergenceWaiter waiter = new ConvergenceWaiter(result, resultExecutor);
      synchronized (this) {
        if (isConverged()) {
          waiter.complete(true);
          return;
        }
        waiters.add(waiter);
      }
      waiter.timeout =
          timeoutExecutor.schedule(
              () -> {
                synchronized (RecordingConvergenceTracker.this) {
                  waiters.remove(waiter);
                }
                waiter.complete(false);
              },
              timeoutSeconds,
              TimeUnit.SECONDS);
    }

    private boolean isConverged() {
      return Boolean.TRUE.equals(focusConverged) && Boolean.TRUE.equals(exposureConverged);
    }
  }

  private static final class ConvergenceWaiter {
    @NonNull private final MethodChannel.Result result;
    @NonNull private final java.util.concurrent.Executor resultExecutor;
    private boolean completed;
    @Nullable private ScheduledFuture<?> timeout;

    ConvergenceWaiter(
        @NonNull MethodChannel.Result result,
        @NonNull java.util.concurrent.Executor resultExecutor) {
      this.result = result;
      this.resultExecutor = resultExecutor;
    }

    synchronized void complete(boolean converged) {
      if (completed) {
        return;
      }
      completed = true;
      if (timeout != null) {
        timeout.cancel(false);
      }
      resultExecutor.execute(() -> result.success(converged));
    }
  }
}
