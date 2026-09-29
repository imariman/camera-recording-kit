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
import android.media.MediaFormat;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Range;
import android.util.Size;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.annotation.VisibleForTesting;
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
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
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
  // Camera ids of VideoCapture use cases that were bound together with a Preview.
  // Lets a later bind that carries only the VideoCapture (setDescription while
  // the preview is paused) resolve the same camera id.
  @NonNull private final Map<VideoCapture<?>, Long> videoCaptureIds = new IdentityHashMap<>();
  @NonNull private final Map<CameraSelector, CameraInfo> selectedCameraInfos = new IdentityHashMap<>();
  @NonNull
  private final Map<VideoCapture<?>, RecordingConvergenceTracker> convergenceTrackers =
      new IdentityHashMap<>();
  @NonNull
  private final Map<CameraControl, RecordingConvergenceTracker> cameraControlTrackers =
      new IdentityHashMap<>();
  @NonNull private final Map<Long, BoundRecordingCamera> boundCameras = new HashMap<>();
  // recordingQualityApplied calls waiting for a poll callback on the main handler.
  @NonNull
  private final Set<MethodChannel.Result> pendingAppliedProfileResults =
      Collections.newSetFromMap(new IdentityHashMap<>());

  // Installed video encoders, enumerated once on mediaExecutor by buildCapabilities.
  @Nullable private List<VideoEncoderInfo> cachedVideoEncoders;
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
    final Set<RecordingConvergenceTracker> trackers =
        Collections.newSetFromMap(new IdentityHashMap<>());
    final List<MethodChannel.Result> pendingAppliedResults;
    synchronized (this) {
      trackers.addAll(convergenceTrackers.values());
      trackers.addAll(cameraControlTrackers.values());
      pendingAppliedResults = new ArrayList<>(pendingAppliedProfileResults);
      pendingAppliedProfileResults.clear();
      previewIds.clear();
      videoCaptureIds.clear();
      selectedCameraInfos.clear();
      convergenceTrackers.clear();
      cameraControlTrackers.clear();
      boundCameras.clear();
    }
    if (mainHandler != null) {
      mainHandler.removeCallbacksAndMessages(null);
      mainHandler = null;
    }
    // Answer callers whose poll callback or focus timeout is dropped below, so
    // their Dart futures do not stay pending.
    for (MethodChannel.Result result : pendingAppliedResults) {
      result.error(
          "recordingQualityFailure",
          "The recording quality extension was torn down before the applied profile was read.",
          null);
    }
    for (RecordingConvergenceTracker tracker : trackers) {
      tracker.cancelWaiters();
    }
    mediaExecutor.shutdownNow();
    focusTimeoutExecutor.shutdownNow();
  }

  synchronized void registerPreview(@NonNull Preview preview, long cameraId) {
    if (boundCameras.isEmpty()) {
      previewIds.clear();
      videoCaptureIds.clear();
      convergenceTrackers.clear();
      cameraControlTrackers.clear();
    }
    previewIds.put(preview, cameraId);
  }

  synchronized void unregisterPreview(@NonNull Preview preview) {
    final Long cameraId = previewIds.remove(preview);
    if (cameraId != null) {
      videoCaptureIds.values().removeAll(Collections.singleton(cameraId));
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

  @VisibleForTesting
  synchronized boolean hasSelectedCameraInfo(@NonNull CameraSelector selector) {
    return selectedCameraInfos.containsKey(selector);
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
    boolean bindsPreview = false;
    for (UseCase useCase : useCases) {
      if (useCase instanceof Preview) {
        bindsPreview = true;
        cameraId = previewIds.get((Preview) useCase);
      } else if (useCase instanceof VideoCapture<?>) {
        videoCapture = (VideoCapture<?>) useCase;
      }
    }
    if (!bindsPreview && videoCapture != null) {
      // No Preview in this bind (for example setDescription while the preview
      // is paused): fall back to the camera the VideoCapture was last bound
      // with alongside a Preview. A bind whose Preview is unknown to
      // previewIds is not a paused-preview bind and keeps the early return.
      cameraId = videoCaptureIds.get(videoCapture);
    }
    if (cameraId == null) {
      return;
    }
    if (videoCapture != null) {
      videoCaptureIds.put(videoCapture, cameraId);
    }
    // Only a bind that (re)attaches the VideoCapture starts a new recording
    // session. A Preview-only rebind keeps the existing session, so its capture
    // results stay valid for the applied-profile readback.
    final boolean bindsVideoCapture = videoCapture != null;
    final CameraInfo selectedCameraInfo = selectedCameraInfos.get(selector);
    final BoundRecordingCamera previousCamera = boundCameras.get(cameraId);
    final RecordingConvergenceTracker convergenceTracker;
    if (videoCapture != null) {
      convergenceTracker = convergenceTrackers.get(videoCapture);
    } else if (previousCamera != null) {
      // A Preview-only rebind (for example resumePreview) leaves the
      // VideoCapture bound alongside it in place, so keep its registration and
      // only refresh the camera.
      videoCapture = previousCamera.videoCapture;
      convergenceTracker = previousCamera.convergenceTracker;
    } else {
      convergenceTracker = null;
    }
    if (previousCamera != null
        && previousCamera.camera.getCameraControl() != camera.getCameraControl()) {
      // The rebind moved this camera id to another CameraControl (for example a lens switch);
      // focus metering on the old one no longer concerns this recording session.
      cameraControlTrackers.remove(previousCamera.camera.getCameraControl());
    }
    if (convergenceTracker != null) {
      if (bindsVideoCapture) {
        // Applied-profile readback must come from capture results of this binding.
        convergenceTracker.resetCaptureResultReadback();
      }
      cameraControlTrackers.put(camera.getCameraControl(), convergenceTracker);
    }
    boundCameras.put(
        cameraId,
        new BoundRecordingCamera(
            camera,
            selector,
            selectedCameraInfo == null ? camera.getCameraInfo() : selectedCameraInfo,
            videoCapture,
            convergenceTracker));
    pruneSelectedCameraInfos();
  }

  /**
   * Forgets camera infos of selectors that no bound camera uses. Every camera creation and switch
   * registers a new selector, so without pruning the map grows until {@link #tearDown}.
   */
  private void pruneSelectedCameraInfos() {
    final Set<CameraSelector> boundSelectors =
        Collections.newSetFromMap(new IdentityHashMap<>());
    for (BoundRecordingCamera boundCamera : boundCameras.values()) {
      boundSelectors.add(boundCamera.selector);
    }
    selectedCameraInfos.keySet().retainAll(boundSelectors);
  }

  synchronized void clearBoundCameras() {
    boundCameras.clear();
    cameraControlTrackers.clear();
  }

  /**
   * Keeps the registration in sync after {@code ProcessCameraProvider.unbind(useCases)}.
   *
   * <p>Unbinding a {@link VideoCapture} detaches the capture callback that feeds the
   * applied-profile readback and the focus wait, so the camera it was bound to no longer has a
   * recording session: readback fails fast instead of polling results that will not arrive. The
   * VideoCapture's camera id is kept, so binding it again (with or without a Preview) restores the
   * registration. Unbinding only a Preview (pausePreview) keeps the recording session, because the
   * VideoCapture stays bound.
   */
  synchronized void onUseCasesUnbound(@NonNull List<? extends UseCase> useCases) {
    for (Map.Entry<Long, BoundRecordingCamera> entry : boundCameras.entrySet()) {
      final BoundRecordingCamera boundCamera = entry.getValue();
      if (boundCamera.videoCapture == null
          || !containsInstance(useCases, boundCamera.videoCapture)) {
        continue;
      }
      cameraControlTrackers.remove(boundCamera.camera.getCameraControl());
      entry.setValue(
          new BoundRecordingCamera(
              boundCamera.camera, boundCamera.selector, boundCamera.cameraInfo, null, null));
    }
  }

  private static boolean containsInstance(
      @NonNull List<? extends UseCase> useCases, @NonNull UseCase useCase) {
    for (UseCase candidate : useCases) {
      if (candidate == useCase) {
        return true;
      }
    }
    return false;
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
    final Executor mainExecutor = ContextCompat.getMainExecutor(context);
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
            // Enumerating qualities, frame rates, sensor durations and encoders is too slow for
            // the main thread on low-end devices; the result is still delivered on it.
            mediaExecutor.execute(() -> deliverCapabilities(cameraInfo, result, mainExecutor));
          } catch (RejectedExecutionException exception) {
            sendError(
                result,
                "recordingQualityFailure",
                "The recording quality extension was torn down.",
                exception);
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

  private void deliverCapabilities(
      @NonNull CameraInfo cameraInfo,
      @NonNull MethodChannel.Result result,
      @NonNull Executor resultExecutor) {
    try {
      final Map<String, Object> capabilities = buildCapabilities(cameraInfo);
      resultExecutor.execute(() -> result.success(capabilities));
    } catch (RuntimeException exception) {
      resultExecutor.execute(
          () ->
              sendError(
                  result,
                  "recordingQualityFailure",
                  "CameraX could not inspect recording capabilities.",
                  exception));
    }
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

  /** Builds the capabilities of {@code cameraInfo}. Runs on {@link #mediaExecutor}. */
  @NonNull
  Map<String, Object> buildCapabilities(@NonNull CameraInfo cameraInfo) {
    if (cachedVideoEncoders == null) {
      // The installed codecs do not change at runtime; enumerate them once.
      cachedVideoEncoders = installedVideoEncoders();
    }
    return buildCapabilities(cameraInfo, cachedVideoEncoders);
  }

  @NonNull
  Map<String, Object> buildCapabilities(
      @NonNull CameraInfo cameraInfo, @NonNull List<VideoEncoderInfo> videoEncoders) {
    final Recorder capabilityRecorder = new Recorder.Builder().build();
    final int capabilitiesSource = capabilityRecorder.getVideoCapabilitiesSource();
    final VideoCapabilities videoCapabilities =
        capabilityRecorder.getMediaCapabilities(cameraInfo, capabilitiesSource);
    final EncoderProfilesResolver profilesResolver =
        capabilityRecorder.getEncoderProfilesResolver(cameraInfo, capabilitiesSource);
    final Set<Range<Integer>> cameraFrameRateRanges = cameraInfo.getSupportedFrameRateRanges();
    final StreamConfigurationMap configurationMap =
        Camera2CameraInfo.from(cameraInfo)
            .getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    final List<Map<String, Object>> profiles = new ArrayList<>();

    for (Quality quality : videoCapabilities.getSupportedQualities(DynamicRange.SDR)) {
      final Size resolution = videoCapabilities.getResolution(quality, DynamicRange.SDR);
      final EncoderProfilesProxy encoderProfiles =
          profilesResolver.getProfiles(quality, DynamicRange.SDR);
      if (resolution == null || encoderProfiles == null) {
        continue;
      }
      for (int fps : RECORDING_FRAME_RATES) {
        if (!hasFixedFrameRateRange(cameraFrameRateRanges, fps)
            || !sensorSupportsFrameRate(configurationMap, resolution, fps)
            || !hasCompatibleAvcEncoderProfile(encoderProfiles, resolution, fps, videoEncoders)) {
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

  /**
   * Whether the camera offers the fixed range {@code [fps, fps]}.
   *
   * <p>The preview requests exactly that range and {@code recordingQualityApplied} only accepts a
   * fixed AE target range, so a range that merely contains {@code fps} (for example {@code [15,
   * 60]}) would advertise a profile that the readback then rejects.
   */
  static boolean hasFixedFrameRateRange(@NonNull Set<Range<Integer>> availableRanges, int fps) {
    for (Range<Integer> range : availableRanges) {
      if (range.getLower() == fps && range.getUpper() == fps) {
        return true;
      }
    }
    return false;
  }

  /**
   * Whether the sensor exposes {@code resolution} for {@link MediaRecorder} output with a minimum
   * frame duration short enough for {@code fps}.
   */
  static boolean sensorSupportsFrameRate(
      @Nullable StreamConfigurationMap configurationMap, @NonNull Size resolution, int fps) {
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

  private static long getMinimumRecordingFrameDuration(
      @NonNull StreamConfigurationMap configurationMap, @NonNull Size resolution) {
    try {
      return configurationMap.getOutputMinFrameDuration(MediaRecorder.class, resolution);
    } catch (IllegalArgumentException exception) {
      return 0L;
    }
  }

  /**
   * Whether the encoder profiles hold an H.264 ({@code video/avc}) profile of {@code resolution}
   * that an installed encoder accepts at {@code fps}.
   *
   * <p>Only AVC profiles count because the extension advertises {@code h264} only: a size whose
   * only profile is HEVC must not be advertised as H.264.
   */
  private static boolean hasCompatibleAvcEncoderProfile(
      @NonNull EncoderProfilesProxy encoderProfiles,
      @NonNull Size resolution,
      int fps,
      @NonNull List<VideoEncoderInfo> videoEncoders) {
    for (EncoderProfilesProxy.VideoProfileProxy videoProfile : encoderProfiles.getVideoProfiles()) {
      if (videoProfile.getWidth() != resolution.getWidth()
          || videoProfile.getHeight() != resolution.getHeight()
          || !MediaFormat.MIMETYPE_VIDEO_AVC.equalsIgnoreCase(videoProfile.getMediaType())) {
        continue;
      }
      if (encoderAccepts(
          videoEncoders,
          MediaFormat.MIMETYPE_VIDEO_AVC,
          resolution.getWidth(),
          resolution.getHeight(),
          fps)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Whether an encoder for {@code mimeType} accepts {@code width}x{@code height} at {@code fps}.
   *
   * <p>Hardware encoders are preferred: when the device has any hardware encoder for the type, only
   * hardware encoders count, because a software encoder that nominally accepts the size and rate
   * cannot sustain it in practice. Software encoders count only on devices without a hardware
   * encoder for the type (for example emulators).
   */
  static boolean encoderAccepts(
      @NonNull List<VideoEncoderInfo> videoEncoders,
      @NonNull String mimeType,
      int width,
      int height,
      int fps) {
    boolean hasHardwareEncoder = false;
    boolean softwareEncoderAccepts = false;
    for (VideoEncoderInfo encoder : videoEncoders) {
      if (!encoder.supportsType(mimeType)) {
        continue;
      }
      final boolean accepts = encoder.acceptsSizeAndRate(mimeType, width, height, fps);
      if (encoder.isSoftwareOnly()) {
        softwareEncoderAccepts |= accepts;
        continue;
      }
      hasHardwareEncoder = true;
      if (accepts) {
        return true;
      }
    }
    return !hasHardwareEncoder && softwareEncoderAccepts;
  }

  /**
   * Returns the installed encoders. Enumerating the codec list is slow, so this runs off the main
   * thread.
   */
  @NonNull
  private static List<VideoEncoderInfo> installedVideoEncoders() {
    final List<VideoEncoderInfo> encoders = new ArrayList<>();
    for (MediaCodecInfo codecInfo : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
      if (codecInfo.isEncoder()) {
        encoders.add(new MediaCodecVideoEncoderInfo(codecInfo));
      }
    }
    return encoders;
  }

  /** The encoder facts {@link #encoderAccepts} needs. */
  interface VideoEncoderInfo {
    boolean supportsType(@NonNull String mimeType);

    /** Whether this encoder runs in software only, as opposed to a hardware (vendor) encoder. */
    boolean isSoftwareOnly();

    /** Whether this encoder accepts {@code mimeType} at the given size and frame rate. */
    boolean acceptsSizeAndRate(@NonNull String mimeType, int width, int height, int fps);
  }

  /** {@link VideoEncoderInfo} backed by an installed {@link MediaCodecInfo} encoder. */
  private static final class MediaCodecVideoEncoderInfo implements VideoEncoderInfo {
    @NonNull private final MediaCodecInfo codecInfo;

    MediaCodecVideoEncoderInfo(@NonNull MediaCodecInfo codecInfo) {
      this.codecInfo = codecInfo;
    }

    @Override
    public boolean supportsType(@NonNull String mimeType) {
      return findSupportedType(mimeType) != null;
    }

    @Override
    public boolean isSoftwareOnly() {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        return codecInfo.isSoftwareOnly();
      }
      final String name = codecInfo.getName().toLowerCase(Locale.ROOT);
      return name.startsWith("omx.google.") || name.startsWith("c2.android.");
    }

    @Override
    public boolean acceptsSizeAndRate(@NonNull String mimeType, int width, int height, int fps) {
      final String supportedType = findSupportedType(mimeType);
      if (supportedType == null) {
        return false;
      }
      try {
        final MediaCodecInfo.VideoCapabilities videoCapabilities =
            codecInfo.getCapabilitiesForType(supportedType).getVideoCapabilities();
        return videoCapabilities != null
            && videoCapabilities.areSizeAndRateSupported(width, height, fps);
      } catch (IllegalArgumentException | IllegalStateException exception) {
        // Failure to verify encoder constraints means this combination must not
        // be advertised as supported.
        return false;
      }
    }

    @Nullable
    private String findSupportedType(@NonNull String mimeType) {
      for (String supportedType : codecInfo.getSupportedTypes()) {
        if (mimeType.equalsIgnoreCase(supportedType)) {
          return supportedType;
        }
      }
      return null;
    }
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
    final RecordingConvergenceTracker captureResults = boundCamera.convergenceTracker;
    if (videoCapture == null || captureResults == null) {
      result.error(
          "unsupportedRecordingProfile",
          "CameraX did not apply the requested recording profile.",
          null);
      return;
    }

    final boolean beforeDeadline = SystemClock.elapsedRealtime() < deadlineMillis;
    final ResolutionInfo resolutionInfo = videoCapture.getResolutionInfo();
    // Native readback: the capture cadence and stabilization mode the camera
    // HAL reported in its latest TotalCaptureResult, not the values requested.
    final Range<Integer> observedFpsRange = captureResults.getObservedAeTargetFpsRange();
    final Integer observedStabilizationMode = captureResults.getObservedVideoStabilizationMode();
    if (resolutionInfo == null
        || observedFpsRange == null
        || !observedFpsRange.getLower().equals(observedFpsRange.getUpper())) {
      if (beforeDeadline) {
        pollAppliedProfile(cameraId, result, deadlineMillis);
        return;
      }
      result.error(
          "unsupportedRecordingProfile",
          resolutionInfo == null
              ? "CameraX did not finish applying the requested resolution."
              : "The camera did not report a fixed capture frame rate for the recording session.",
          null);
      return;
    }
    final int observedFps = observedFpsRange.getUpper();

    // Sanity checks only: give capture results until the deadline to reflect
    // the latest request (the encoder's declared frame rate and the requested
    // stabilization mode). The reported values always come from the capture
    // result, so a request the HAL silently downgraded is reported as such.
    final int encoderFrameRate = getEncoderFrameRate(videoCapture);
    final Integer requestedStabilizationMode = getRequestedStabilizationMode(boundCamera);
    final boolean fpsMatchesEncoder = encoderFrameRate <= 0 || observedFps == encoderFrameRate;
    final boolean stabilizationMatchesRequest =
        requestedStabilizationMode == null
            || isStabilizationActive(requestedStabilizationMode)
                == isStabilizationActive(observedStabilizationMode);
    if (beforeDeadline && (!fpsMatchesEncoder || !stabilizationMatchesRequest)) {
      pollAppliedProfile(cameraId, result, deadlineMillis);
      return;
    }

    final Size resolution = resolutionInfo.getResolution();
    final Map<String, Object> applied = new HashMap<>();
    applied.put("width", resolution.getWidth());
    applied.put("height", resolution.getHeight());
    applied.put("fps", observedFps);
    // Recorder does not expose the selected encoder codec. Do not infer it
    // from the accepted preference; finalized container inspection is the
    // first authoritative readback point.
    applied.put("codec", null);
    applied.put("codecSource", "unavailableUntilFinalized");
    // A HAL that omits CONTROL_VIDEO_STABILIZATION_MODE has not confirmed
    // stabilization, so it is reported inactive.
    applied.put("stabilizationEnabled", isStabilizationActive(observedStabilizationMode));
    result.success(applied);
  }

  private void pollAppliedProfile(
      long cameraId, @NonNull MethodChannel.Result result, long deadlineMillis) {
    synchronized (this) {
      pendingAppliedProfileResults.add(result);
    }
    getMainHandler()
        .postDelayed(
            () -> {
              synchronized (this) {
                if (!pendingAppliedProfileResults.remove(result)) {
                  // Already answered by tearDown.
                  return;
                }
              }
              waitForAppliedProfile(cameraId, result, deadlineMillis);
            },
            APPLIED_PROFILE_POLL_MILLIS);
  }

  @NonNull
  private Handler getMainHandler() {
    if (mainHandler == null) {
      mainHandler = new Handler(Looper.getMainLooper());
    }
    return mainHandler;
  }

  private static int getEncoderFrameRate(@NonNull VideoCapture<?> videoCapture) {
    final Object output = videoCapture.getOutput();
    return output instanceof Recorder ? ((Recorder) output).getVideoEncodingFrameRate() : 0;
  }

  @Nullable
  private static Integer getRequestedStabilizationMode(@NonNull BoundRecordingCamera boundCamera) {
    return Camera2CameraControl.from(boundCamera.camera.getCameraControl())
        .getCaptureRequestOptions()
        .getCaptureRequestOption(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE);
  }

  private static boolean isStabilizationActive(@Nullable Integer stabilizationMode) {
    return stabilizationMode != null
        && stabilizationMode != CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF;
  }

  @NonNull
  RecordingMediaInspector createMediaInspector() {
    return new RecordingMediaInspector();
  }

  private void inspectRecordingMedia(
      @NonNull String path, @NonNull MethodChannel.Result result) {
    try {
      mediaExecutor.execute(() -> inspectRecordingMediaInBackground(path, result));
    } catch (RejectedExecutionException exception) {
      sendError(
          result,
          "recordingQualityFailure",
          "The recording quality extension was torn down.",
          exception);
    }
  }

  /** Reads the media metadata on {@link #mediaExecutor} and answers on the main thread. */
  private void inspectRecordingMediaInBackground(
      @NonNull String path, @NonNull MethodChannel.Result result) {
    final Executor mainExecutor = ContextCompat.getMainExecutor(context);
    try {
      final Map<String, Object> metadata = createMediaInspector().inspect(new File(path));
      mainExecutor.execute(() -> result.success(metadata));
    } catch (RecordingMediaInspector.MediaInspectionException exception) {
      mainExecutor.execute(
          () ->
              result.error(
                  exception.code, exception.getMessage(), errorDetails(exception.getCause())));
    } catch (RuntimeException exception) {
      mainExecutor.execute(
          () ->
              sendError(
                  result,
                  "recordingMediaInvalid",
                  "The finalized recording metadata could not be read.",
                  exception));
    }
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
    @NonNull final CameraSelector selector;
    @NonNull final CameraInfo cameraInfo;
    @Nullable final VideoCapture<?> videoCapture;
    @Nullable final RecordingConvergenceTracker convergenceTracker;

    BoundRecordingCamera(
        @NonNull Camera camera,
        @NonNull CameraSelector selector,
        @NonNull CameraInfo cameraInfo,
        @Nullable VideoCapture<?> videoCapture,
        @Nullable RecordingConvergenceTracker convergenceTracker) {
      this.camera = camera;
      this.selector = selector;
      this.cameraInfo = cameraInfo;
      this.videoCapture = videoCapture;
      this.convergenceTracker = convergenceTracker;
    }
  }

  /**
   * Session capture callback registered on the recording {@link VideoCapture}.
   *
   * <p>Tracks AF/AE convergence for {@code waitForRecordingFocus} and keeps the latest capture
   * cadence and video stabilization mode the camera HAL reported in a {@link TotalCaptureResult},
   * which is the native readback used by {@code recordingQualityApplied}.
   */
  static final class RecordingConvergenceTracker
      extends CameraCaptureSession.CaptureCallback {
    @Nullable private Boolean focusConverged;
    @Nullable private Boolean exposureConverged;
    @Nullable private Range<Integer> observedAeTargetFpsRange;
    @Nullable private Integer observedVideoStabilizationMode;
    @NonNull private final List<ConvergenceWaiter> waiters = new ArrayList<>();

    @Override
    public void onCaptureCompleted(
        @NonNull CameraCaptureSession session,
        @NonNull CaptureRequest request,
        @NonNull TotalCaptureResult result) {
      final Integer afState = result.get(CaptureResult.CONTROL_AF_STATE);
      final Integer aeState = result.get(CaptureResult.CONTROL_AE_STATE);
      final Range<Integer> aeTargetFpsRange =
          result.get(CaptureResult.CONTROL_AE_TARGET_FPS_RANGE);
      final Integer videoStabilizationMode =
          result.get(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE);
      final List<ConvergenceWaiter> completedWaiters;
      synchronized (this) {
        if (aeTargetFpsRange != null) {
          observedAeTargetFpsRange = aeTargetFpsRange;
        }
        if (videoStabilizationMode != null) {
          observedVideoStabilizationMode = videoStabilizationMode;
        }
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

    /** Answers every pending {@link #waitForConvergence} call with {@code false}. */
    void cancelWaiters() {
      final List<ConvergenceWaiter> cancelledWaiters;
      synchronized (this) {
        cancelledWaiters = new ArrayList<>(waiters);
        waiters.clear();
      }
      for (ConvergenceWaiter waiter : cancelledWaiters) {
        waiter.complete(false);
      }
    }

    /**
     * Forgets capture results from an earlier binding so the next applied-profile readback only
     * reflects the camera session that is currently configured.
     */
    synchronized void resetCaptureResultReadback() {
      observedAeTargetFpsRange = null;
      observedVideoStabilizationMode = null;
    }

    /** Latest {@link CaptureResult#CONTROL_AE_TARGET_FPS_RANGE}, or null before any result. */
    @Nullable
    synchronized Range<Integer> getObservedAeTargetFpsRange() {
      return observedAeTargetFpsRange;
    }

    /** Latest {@link CaptureResult#CONTROL_VIDEO_STABILIZATION_MODE}, or null if never reported. */
    @Nullable
    synchronized Integer getObservedVideoStabilizationMode() {
      return observedVideoStabilizationMode;
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
