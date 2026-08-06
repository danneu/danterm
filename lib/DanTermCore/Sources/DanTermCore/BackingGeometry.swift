// Pure content-scale and backing-pixel size derivation for a Ghostty surface.

import Foundation

/// Geometry to push to a Ghostty surface: per-axis content scale plus backing pixels.
struct BackingGeometry: Equatable {
    let xScale: Double
    let yScale: Double
    let pixelWidth: UInt32
    let pixelHeight: UInt32
}

/// Derive Ghostty surface geometry from a logical point size and its backing-pixel size.
func backingGeometry(logicalSize: CGSize, backingSize: CGSize) -> BackingGeometry? {
    guard logicalSize.width > 0, logicalSize.height > 0,
          backingSize.width > 0, backingSize.height > 0 else {
        return nil
    }

    return BackingGeometry(
        xScale: Double(backingSize.width / logicalSize.width),
        yScale: Double(backingSize.height / logicalSize.height),
        pixelWidth: UInt32(backingSize.width),
        pixelHeight: UInt32(backingSize.height)
    )
}
