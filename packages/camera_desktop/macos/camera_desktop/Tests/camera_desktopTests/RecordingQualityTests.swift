// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

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

    func testVideoCodecNamesMatchTheDartChannelContract() {
        XCTAssertEqual(RecordingQuality.VideoCodec.h264.rawValue, "h264")
        XCTAssertEqual(RecordingQuality.VideoCodec.hevc.rawValue, "hevc")
        XCTAssertNil(RecordingQuality.VideoCodec(rawValue: "vp9"))
    }
}
