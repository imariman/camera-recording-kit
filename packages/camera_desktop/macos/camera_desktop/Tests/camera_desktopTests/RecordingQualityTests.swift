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
}
