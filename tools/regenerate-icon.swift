#!/usr/bin/env swift
// Removes the white halo around OSToolbar's app icon by flood-filling the
// connected white region from each corner with transparency. Interior whites
// (the clipboard glyph, the corner brackets) are surrounded by blue and stay
// opaque. Then re-emits the icon at every required size.
//
// Usage: tools/regenerate-icon.swift (from the os-toolbar/ project root)

import AppKit
import Foundation

let assetsDir = "OSToolbar/Assets.xcassets/AppIcon.appiconset"
let srcURL = URL(fileURLWithPath: "\(assetsDir)/icon_1024.png")

guard let nsImage = NSImage(contentsOf: srcURL),
      let source = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  FileHandle.standardError.write(Data("could not load icon_1024.png\n".utf8))
  exit(1)
}

let w = source.width, h = source.height
let stride = source.bytesPerRow
let bpp = source.bitsPerPixel / 8

guard let provider = source.dataProvider, let cfData = provider.data else {
  FileHandle.standardError.write(Data("no pixel data\n".utf8))
  exit(1)
}
let length = CFDataGetLength(cfData)
var pixels = [UInt8](repeating: 0, count: length)
CFDataGetBytes(cfData, CFRange(location: 0, length: length), &pixels)

// Flood-fill mask: 1 means keep, 0 means make transparent (background).
var mask = [UInt8](repeating: 1, count: w * h)
let whiteThresh: Int = 230  // R, G, and B all above this counts as "white-ish".

func isWhitish(at index: Int) -> Bool {
  // Already-transparent pixels are part of the "background" the flood can pass
  // through to reach any remaining inner white frame around the blue shape.
  let alpha = bpp >= 4 ? Int(pixels[index + 3]) : 255
  if alpha < 8 { return true }
  let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
  return r >= whiteThresh && g >= whiteThresh && b >= whiteThresh
}

var stack: [(Int, Int)] = []
stack.reserveCapacity(w * 4)
for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
  stack.append(corner)
}

while let (x, y) = stack.popLast() {
  if x < 0 || y < 0 || x >= w || y >= h { continue }
  let mi = y * w + x
  if mask[mi] == 0 { continue }
  let pi = y * stride + x * bpp
  if !isWhitish(at: pi) { continue }
  mask[mi] = 0
  stack.append((x + 1, y))
  stack.append((x - 1, y))
  stack.append((x, y + 1))
  stack.append((x, y - 1))
}

// Build the new RGBA bitmap: copy RGB, multiply alpha by mask.
var out = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h {
  for x in 0..<w {
    let pi = y * stride + x * bpp
    let oi = (y * w + x) * 4
    out[oi] = pixels[pi]
    out[oi + 1] = pixels[pi + 1]
    out[oi + 2] = pixels[pi + 2]
    let alpha = bpp >= 4 ? Int(pixels[pi + 3]) : 255
    let keep = Int(mask[y * w + x])
    out[oi + 3] = UInt8((alpha * keep) / 1)  // keep is 0 or 1
  }
}

let space = CGColorSpaceCreateDeviceRGB()
let provider2 = CGDataProvider(data: NSData(bytes: out, length: out.count) as CFData)!
guard let cleaned = CGImage(
  width: w, height: h,
  bitsPerComponent: 8, bitsPerPixel: 32,
  bytesPerRow: w * 4,
  space: space,
  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
  provider: provider2, decode: nil,
  shouldInterpolate: false, intent: .defaultIntent
) else {
  FileHandle.standardError.write(Data("could not build cleaned CGImage\n".utf8))
  exit(1)
}

func writePNG(_ cg: CGImage, to url: URL) {
  let rep = NSBitmapImageRep(cgImage: cg)
  if let data = rep.representation(using: .png, properties: [:]) {
    try? data.write(to: url)
  }
}

func resample(_ cg: CGImage, to size: Int) -> CGImage? {
  guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: size * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }
  ctx.interpolationQuality = .high
  ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
  return ctx.makeImage()
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
  let img = size == 1024 ? cleaned : (resample(cleaned, to: size) ?? cleaned)
  let name = size == 1024 ? "icon_1024.png" : "icon_\(size).png"
  let url = URL(fileURLWithPath: "\(assetsDir)/\(name)")
  writePNG(img, to: url)
  print("wrote \(name) (\(size)×\(size))")
}
print("done")
