// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.video.VideoRecordEvent;

/**
 * ProxyApi implementation for {@link VideoRecordEvent.Finalize}.
 *
 * <p>Carries the finalize error code and output URI to Dart so a recording that CameraX finalized
 * with an error is not reported as a successful file.
 */
class VideoRecordEventFinalizeProxyApi extends PigeonApiVideoRecordEventFinalize {
  VideoRecordEventFinalizeProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @Override
  public long error(@NonNull VideoRecordEvent.Finalize pigeonInstance) {
    return pigeonInstance.getError();
  }

  @Nullable
  @Override
  public String outputUri(@NonNull VideoRecordEvent.Finalize pigeonInstance) {
    final Uri outputUri = pigeonInstance.getOutputResults().getOutputUri();
    if (outputUri == null || Uri.EMPTY.equals(outputUri)) {
      return null;
    }
    final String value = outputUri.toString();
    return value.isEmpty() ? null : value;
  }
}
