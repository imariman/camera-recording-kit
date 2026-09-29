// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.UseCase;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.List;
import java.util.concurrent.ExecutionException;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * ProxyApi implementation for {@link ProcessCameraProvider}. This class may handle instantiating
 * native object instances that are attached to a Dart instance or handle method calls on the
 * associated native class or an instance of that class.
 */
class ProcessCameraProviderProxyApi extends PigeonApiProcessCameraProvider {
  ProcessCameraProviderProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @Override
  public void getInstance(
      @NonNull Function1<? super Result<ProcessCameraProvider>, Unit> callback) {
    final ListenableFuture<ProcessCameraProvider> processCameraProviderFuture =
        ProcessCameraProvider.getInstance(getPigeonRegistrar().getContext());

    processCameraProviderFuture.addListener(
        () -> {
          try {
            // Camera provider is now guaranteed to be available.
            ResultCompat.success(processCameraProviderFuture.get(), callback);
          } catch (InterruptedException | ExecutionException e) {
            ResultCompat.failure(e, callback);
          }
        },
        ContextCompat.getMainExecutor(getPigeonRegistrar().getContext()));
  }

  @NonNull
  @Override
  public List<CameraInfo> getAvailableCameraInfos(ProcessCameraProvider pigeonInstance) {
    return pigeonInstance.getAvailableCameraInfos();
  }

  @NonNull
  @Override
  public Camera bindToLifecycle(
      @NonNull ProcessCameraProvider pigeonInstance,
      @NonNull CameraSelector cameraSelector,
      @NonNull List<? extends UseCase> useCases) {
    final LifecycleOwner lifecycleOwner = getPigeonRegistrar().getLifecycleOwner();
    if (lifecycleOwner != null) {
      try {
        final Camera camera =
            pigeonInstance.bindToLifecycle(
                lifecycleOwner, cameraSelector, useCases.toArray(new UseCase[0]));
        getPigeonRegistrar()
            .getRecordingQualityController()
            .registerBoundCamera(cameraSelector, useCases, camera);
        return camera;
      } catch (IllegalArgumentException exception) {
        if (containsVideoCapture(useCases)) {
          throw new CameraXError(
              "unsupportedRecordingProfile",
              "CameraX could not bind the requested recording profile.",
              exception.toString());
        }
        throw exception;
      }
    }

    throw new IllegalStateException(
        "LifecycleOwner must be set to get ProcessCameraProvider instance.");
  }

  private boolean containsVideoCapture(@NonNull List<? extends UseCase> useCases) {
    for (UseCase useCase : useCases) {
      if (useCase instanceof androidx.camera.video.VideoCapture<?>) {
        return true;
      }
    }
    return false;
  }

  @Override
  public boolean isBound(ProcessCameraProvider pigeonInstance, @NonNull UseCase useCase) {
    return pigeonInstance.isBound(useCase);
  }

  @Override
  public void unbind(
      ProcessCameraProvider pigeonInstance, @NonNull List<? extends UseCase> useCases) {
    pigeonInstance.unbind(useCases.toArray(new UseCase[0]));
    getPigeonRegistrar().getRecordingQualityController().onUseCasesUnbound(useCases);
  }

  @Override
  public void unbindAll(ProcessCameraProvider pigeonInstance) {
    pigeonInstance.unbindAll();
    getPigeonRegistrar().getRecordingQualityController().clearBoundCameras();
  }
}
