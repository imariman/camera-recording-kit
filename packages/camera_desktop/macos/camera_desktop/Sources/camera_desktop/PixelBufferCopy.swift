import CoreVideo
import Foundation

/// Copies a pixel buffer into a new, independently allocated buffer.
///
/// Used where a frame outlives the capture callback (photo encoding), so the
/// source can return to its bounded pool (the capture output's or the
/// stabilizer's) immediately instead of being held for the whole operation.
enum PixelBufferCopy {
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &destination
        ) == kCVReturnSuccess, let destination else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            guard planeCount == CVPixelBufferGetPlaneCount(destination) else { return nil }
            for plane in 0..<planeCount {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    return nil
                }
                copyRows(
                    from: sourceBase,
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    to: destinationBase,
                    destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                    rows: CVPixelBufferGetHeightOfPlane(source, plane)
                )
            }
        } else {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
                return nil
            }
            copyRows(
                from: sourceBase,
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                to: destinationBase,
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                rows: height
            )
        }

        // Keep color space and other propagatable metadata for encoding.
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private static func copyRows(
        from source: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        to destination: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        rows: Int
    ) {
        if sourceBytesPerRow == destinationBytesPerRow {
            memcpy(destination, source, sourceBytesPerRow * rows)
            return
        }
        let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in 0..<rows {
            memcpy(
                destination.advanced(by: row * destinationBytesPerRow),
                source.advanced(by: row * sourceBytesPerRow),
                rowBytes
            )
        }
    }
}
