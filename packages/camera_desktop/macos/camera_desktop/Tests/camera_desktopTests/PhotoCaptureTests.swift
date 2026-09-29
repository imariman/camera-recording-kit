// Copyright 2026 Teleprompter Studio. All rights reserved.

import CoreVideo
import XCTest
@testable import camera_desktop

final class PhotoCaptureTests: XCTestCase {
    func testPixelBufferCopyIsIndependentAndPreservesPixels() throws {
        let width = 64
        let height = 48
        var created: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created
            ),
            kCVReturnSuccess
        )
        let source = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(source, [])
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let sourceBase = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<(width * 4) {
                sourceBase[y * sourceBytesPerRow + x] = UInt8((x + y * 7) % 251)
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let copy = try XCTUnwrap(PixelBufferCopy.copy(source))
        XCTAssertFalse(copy === source)
        XCTAssertEqual(CVPixelBufferGetWidth(copy), width)
        XCTAssertEqual(CVPixelBufferGetHeight(copy), height)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), kCVPixelFormatType_32BGRA)

        // Overwrite the source: the copy must not share its memory.
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 0, sourceBytesPerRow * height)
        CVPixelBufferUnlockBaseAddress(source, [])

        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        let copyBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
        let copyBase = try XCTUnwrap(CVPixelBufferGetBaseAddress(copy))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<(width * 4) {
                XCTAssertEqual(copyBase[y * copyBytesPerRow + x], UInt8((x + y * 7) % 251))
            }
        }
    }

    func testPhotoPathsAreUniqueWithinTheSameMillisecond() {
        let paths = (0..<50).map { _ in PhotoHandler.generatePath(cameraId: 1) }
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix(".jpg") })
    }
}
