import AppKit.NSImage

extension NSImage {
  // Resize to fit `newSize` (preserving aspect, never upscaling) and RASTERIZE the
  // result to a concrete bitmap via Core Graphics.
  //
  // The previous implementation returned an NSImage with a drawing handler, which
  // re-drew the full-resolution source on every render (with high interpolation).
  // With image-heavy histories that caused severe hangs while scrolling/navigating.
  // A CGImage-backed bitmap costs one downscale here, then renders cheaply.
  func resized(to newSize: NSSize) -> NSImage {
    let ratioX = newSize.width / size.width
    let ratioY = newSize.height / size.height
    let ratio = min(ratioX, ratioY)

    // Don't attempt to size up.
    if ratio >= 1 {
      return self
    }

    let targetWidth = size.width * ratio
    let targetHeight = size.height * ratio
    let pixelWidth = max(1, Int(targetWidth.rounded()))
    let pixelHeight = max(1, Int(targetHeight.rounded()))

    guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
      return self
    }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

    guard let resizedCGImage = context.makeImage() else {
      return self
    }

    return NSImage(cgImage: resizedCGImage, size: NSSize(width: targetWidth, height: targetHeight))
  }
}
