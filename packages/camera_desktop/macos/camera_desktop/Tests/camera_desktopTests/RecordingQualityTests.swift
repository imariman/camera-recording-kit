// Copyright 2026 Teleprompter Studio. All rights reserved.

import AVFoundation
import XCTest
@testable import camera_desktop

final class RecordingQualityTests: XCTestCase {
    func testPresetMappingUsesExactAppProfiles() {
        XCTAssertEqual(RecordingQuality.requestedDimensions(for: 0)?.width, 640)
        XCTAssertEqual(RecordingQuality.requestedDimensions(for: 1)?.height, 480)
        XCTAssertEqual(RecordingQuality.requestedDimensions(for: 2)?.height, 720)
        XCTAssertEqual(RecordingQuality.requestedDimensions(for: 3)?.height, 1080)
        XCTAssertEqual(RecordingQuality.requestedDimensions(for: 4)?.height, 2160)
        XCTAssertNil(RecordingQuality.requestedDimensions(for: 5))
        XCTAssertNil(RecordingQuality.requestedDimensions(for: 99))
    }

    func testAdvertisedProfilesAreBoundedToThirtyOrSixtyFpsAnd4K() {
        XCTAssertFalse(RecordingQuality.requestedProfiles.isEmpty)
        for profile in RecordingQuality.requestedProfiles {
            XCTAssertTrue(profile.framesPerSecond == 30 || profile.framesPerSecond == 60)
            XCTAssertLessThanOrEqual(profile.width, 3840)
            XCTAssertLessThanOrEqual(profile.height, 2160)
        }
    }

    func testFrameDurationReadbackReturnsConfiguredRate() throws {
        let duration = CMTime(value: 1, timescale: 60)
        let fps = try XCTUnwrap(RecordingQuality.framesPerSecond(for: duration))
        XCTAssertEqual(fps, 60, accuracy: 0.001)
        XCTAssertNil(RecordingQuality.framesPerSecond(for: .invalid))
    }

    func testCodecCapabilityDiscoveryOnlyReturnsKnownWriterCodecs() {
        let profile = RecordingQuality.Profile(
            width: 640,
            height: 480,
            framesPerSecond: 30
        )
        let codecs = RecordingQuality.supportedCodecs(for: profile)
        XCTAssertTrue(codecs.allSatisfy {
            $0 == .h264 || $0 == .hevc
        })
        XCTAssertEqual(
            codecs,
            RecordingQuality.VideoCodec.allCases.filter {
                RecordingQuality.supportsEncoding(profile: profile, codec: $0)
            }
        )
    }

    func testFrameRateSupportToleratesRoundedUvcRates() {
        // 29.97 and 30.00003 FPS modes are the 30 FPS profile.
        XCTAssertTrue(RecordingQuality.supports(frameRate: 30, minFrameRate: 29.97, maxFrameRate: 29.97))
        XCTAssertTrue(RecordingQuality.supports(frameRate: 30, minFrameRate: 30.00003, maxFrameRate: 30.00003))
        XCTAssertTrue(RecordingQuality.supports(frameRate: 60, minFrameRate: 1, maxFrameRate: 59.94))
        XCTAssertTrue(RecordingQuality.supports(frameRate: 30, minFrameRate: 5, maxFrameRate: 60))
        XCTAssertFalse(RecordingQuality.supports(frameRate: 30, minFrameRate: 25, maxFrameRate: 29.5))
        XCTAssertFalse(RecordingQuality.supports(frameRate: 60, minFrameRate: 1, maxFrameRate: 30))
        XCTAssertTrue(RecordingQuality.matches(frameRate: 29.97, requested: 30))
        XCTAssertTrue(RecordingQuality.matches(frameRate: 60.0001, requested: 60))
        XCTAssertFalse(RecordingQuality.matches(frameRate: 25, requested: 30))
    }

    func testFrameDurationIsClampedIntoTheSupportedRange() {
        let requested = CMTime(value: 1, timescale: 30)
        let ntsc = CMTime(value: 1001, timescale: 30000)
        // A 29.97-only range rejects exactly 1/30 s; the bound is applied instead.
        XCTAssertEqual(RecordingQuality.clamp(requested, minimum: ntsc, maximum: ntsc), ntsc)
        XCTAssertEqual(
            RecordingQuality.clamp(requested, minimum: CMTime(value: 1, timescale: 60), maximum: CMTime(value: 1, timescale: 5)),
            requested
        )
        let fast = CMTime(value: 1, timescale: 31)
        XCTAssertEqual(RecordingQuality.clamp(requested, minimum: CMTime(value: 1, timescale: 60), maximum: fast), fast)
    }

    func testVideoCodecNamesMatchTheDartChannelContract() {
        XCTAssertEqual(RecordingQuality.VideoCodec.h264.rawValue, "h264")
        XCTAssertEqual(RecordingQuality.VideoCodec.hevc.rawValue, "hevc")
        XCTAssertNil(RecordingQuality.VideoCodec(rawValue: "vp9"))
    }
}
