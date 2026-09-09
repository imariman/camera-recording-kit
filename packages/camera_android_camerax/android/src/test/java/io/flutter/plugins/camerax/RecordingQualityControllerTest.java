// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.annotation.Config;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
public class RecordingQualityControllerTest {
  private RecordingQualityController controller;

  @Before
  public void setUp() {
    final Context context = mock(Context.class);
    when(context.getApplicationContext()).thenReturn(context);
    controller = new RecordingQualityController(context);
  }

  @After
  public void tearDown() {
    controller.tearDown();
  }

  @Test
  public void supportedRecordingCodecs_returnsOnlyH264() {
    assertEquals(Collections.singletonList("h264"), controller.supportedRecordingCodecs());
  }

  @Test
  public void setRecordingVideoCodec_acceptsH264() {
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(codecCall("h264"), result);

    verify(result).success(null);
  }

  @Test
  public void setRecordingVideoCodec_rejectsHevcAsUnsupported() {
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(codecCall("hevc"), result);

    verify(result)
        .error(
            "unsupportedVideoCodec",
            "CameraX Recorder does not expose a public API for selecting HEVC video.",
            null);
  }

  @Test
  public void setRecordingVideoCodec_rejectsUnknownCodecAsInvalidArgument() {
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(codecCall("vp9"), result);

    verify(result)
        .error(eq("invalidArguments"), eq("codec must be h264 or hevc."), any());
  }

  private MethodCall codecCall(String codec) {
    final Map<String, Object> arguments = new HashMap<>();
    arguments.put("codec", codec);
    return new MethodCall("setRecordingVideoCodec", arguments);
  }
}
