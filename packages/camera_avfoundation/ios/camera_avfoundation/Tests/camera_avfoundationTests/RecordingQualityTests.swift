// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation
import XCTest

@testable import camera_avfoundation

final class RecordingQualityTests: XCTestCase {
  private let encodeEverything: (Int32, Int32, Int, RecordingQuality.VideoCodec) -> Bool = {
    _, _, _, _ in true
  }

  private func profiles(_ capabilities: [String: Any]) -> [[String: AnyHashable]] {
    return (capabilities["profiles"] as? [[String: Any]] ?? []).map { profile in
      profile.compactMapValues { $0 as? AnyHashable }
    }
  }

  func testCapabilitiesListRequestedProfilesSortedWithTheirCodecs() {
    let device = FakeCaptureDevice(formats: [
      FakeCaptureDeviceFormat(width: 3840, height: 2160, frameRates: [(1, 30)]),
      FakeCaptureDeviceFormat(width: 1280, height: 720, frameRates: [(1, 60)]),
      FakeCaptureDeviceFormat(width: 1024, height: 768, frameRates: [(1, 60)]),
    ])

    let capabilities = RecordingQuality.capabilities(
      device: device,
      codecs: [.h264, .hevc],
      videoDimensionsConverter: fakeDimensionsConverter,
      supportsEncoding: encodeEverything)

    XCTAssertEqual(
      profiles(capabilities),
      [
        ["width": 1280, "height": 720, "fps": 30, "codecs": ["h264", "hevc"]],
        ["width": 1280, "height": 720, "fps": 60, "codecs": ["h264", "hevc"]],
        ["width": 3840, "height": 2160, "fps": 30, "codecs": ["h264", "hevc"]],
      ])
    XCTAssertEqual(capabilities["supportsFocusLock"] as? Bool, true)
    XCTAssertEqual(capabilities["supportsExposureLock"] as? Bool, true)
  }

  func testCapabilitiesSkipProfilesOnlyAvailableInBtp2OrSquareFormats() {
    let device = FakeCaptureDevice(formats: [
      FakeCaptureDeviceFormat(width: 1920, height: 1080, frameRates: [(1, 30)]),
      FakeCaptureDeviceFormat(
        width: 1920, height: 1080, subType: btp2SubType, frameRates: [(1, 60)]),
      FakeCaptureDeviceFormat(
        width: 3840, height: 2160, subType: btp2SubType, frameRates: [(1, 30)]),
    ])

    let capabilities = RecordingQuality.capabilities(
      device: device,
      codecs: [.h264],
      videoDimensionsConverter: fakeDimensionsConverter,
      supportsEncoding: encodeEverything)

    XCTAssertEqual(
      profiles(capabilities),
      [["width": 1920, "height": 1080, "fps": 30, "codecs": ["h264"]]])
  }

  func testCapabilitiesListPerProfileCodecsTheEncoderAccepts() {
    let device = FakeCaptureDevice(formats: [
      FakeCaptureDeviceFormat(width: 1920, height: 1080, frameRates: [(1, 60)]),
      FakeCaptureDeviceFormat(width: 3840, height: 2160, frameRates: [(1, 60)]),
    ])
    device.supportedFocusModes = []

    let capabilities = RecordingQuality.capabilities(
      device: device,
      codecs: [.h264, .hevc],
      videoDimensionsConverter: fakeDimensionsConverter,
      supportsEncoding: { width, _, fps, codec in
        // HEVC only at 4K; H.264 everywhere except 4K60.
        codec == .hevc ? width == 3840 : !(width == 3840 && fps == 60)
      })

    XCTAssertEqual(
      profiles(capabilities),
      [
        ["width": 1920, "height": 1080, "fps": 30, "codecs": ["h264"]],
        ["width": 1920, "height": 1080, "fps": 60, "codecs": ["h264"]],
        ["width": 3840, "height": 2160, "fps": 30, "codecs": ["h264", "hevc"]],
        ["width": 3840, "height": 2160, "fps": 60, "codecs": ["hevc"]],
      ])
    XCTAssertEqual(capabilities["supportsFocusLock"] as? Bool, false)
  }

  func testAvailableCodecsFollowTheCaptureOutputWhenItReportsCodecs() {
    let noEncoderCheck: (RecordingQuality.VideoCodec) -> Bool = { _ in
      XCTFail("The encoder must not be consulted when the output lists its codecs")
      return true
    }

    XCTAssertEqual(
      RecordingQuality.availableCodecs(writerCodecs: [.h264], encoderAvailable: noEncoderCheck),
      [.h264])
    XCTAssertEqual(
      RecordingQuality.availableCodecs(
        writerCodecs: [.hevc, .h264, .jpeg], encoderAvailable: noEncoderCheck),
      [.h264, .hevc])
    XCTAssertEqual(
      RecordingQuality.availableCodecs(writerCodecs: [.hevc], encoderAvailable: noEncoderCheck),
      [.hevc])
  }

  func testAvailableCodecsFallBackToTheEncoderCheckForHevcOnly() {
    var askedCodecs: [RecordingQuality.VideoCodec] = []

    let withoutHevc = RecordingQuality.availableCodecs(writerCodecs: nil) { codec in
      askedCodecs.append(codec)
      return false
    }
    XCTAssertEqual(withoutHevc, [.h264])
    XCTAssertEqual(askedCodecs, [.hevc])

    XCTAssertEqual(
      RecordingQuality.availableCodecs(writerCodecs: [], encoderAvailable: { _ in true }),
      [.h264, .hevc])
  }

  func testVideoCodecIsReadFromWriterSettings() {
    XCTAssertEqual(
      RecordingQuality.VideoCodec(writerSettings: [AVVideoCodecKey: AVVideoCodecType.hevc]),
      .hevc)
    XCTAssertEqual(
      RecordingQuality.VideoCodec(writerSettings: [AVVideoCodecKey: "avc1"]), .h264)
    XCTAssertNil(
      RecordingQuality.VideoCodec(writerSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg]))
    XCTAssertNil(RecordingQuality.VideoCodec(writerSettings: [:]))
    XCTAssertNil(RecordingQuality.VideoCodec(writerSettings: nil))
  }
}
