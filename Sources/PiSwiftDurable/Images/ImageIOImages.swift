#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEG qualities tried in order, out of 100.
private let jpegQualities = [80, 70, 55, 40]

/// An `ImageProcessor` on ImageIO and Core Graphics, for `createCodingTools(options: .init(images:))`. Upstream's is on
/// Photon (`createPhotonImages(wasm)`, Rust compiled to WebAssembly); this one does the same work with the system
/// codecs, so there is nothing to load.
///
/// An image already upright, in a format providers take inline, and within the limits is returned as it is, once it
/// decodes. Otherwise it is turned upright by its EXIF orientation, scaled to the maximum width and height, and encoded
/// as PNG or JPEG at falling qualities (JPEG first for JPEG sources), then at smaller dimensions, 3/4 at a time, until
/// the base64 fits. Formats providers do not take inline (BMP) become PNG.
///
/// The work runs on the calling task's thread. Decoding takes the image's RGBA size in memory until `prepare` returns.
public func createImageIOImages() -> any ImageProcessor { ImageIOImages() }

private struct ImageIOImages: ImageProcessor {
    func prepare(_ bytes: [UInt8], mimeType: String, limits: ImageLimits) async -> PreparedImage? {
        do { return try prepareImage(bytes, mimeType: mimeType, limits: limits) }
        // ImageIO and Core Graphics fail for bytes they cannot decode or images they cannot draw.
        catch { return nil }
    }
}

/// A decode, draw, or encode that ImageIO or Core Graphics refused.
private struct ImageIOFailure: Error {}

private func prepareImage(_ bytes: [UInt8], mimeType: String, limits: ImageLimits) throws -> PreparedImage? {
    let orientation = exifOrientation(bytes)
    let inline = inlineImageTypes.contains(mimeType)
    // Decoded even when it is returned as it is: a damaged file is an error, not an image the provider rejects.
    var image = try decode(bytes)
    if inline && orientation == 1 && image.width <= limits.maxWidth && image.height <= limits.maxHeight
        && base64Length(Int64(bytes.count)) <= Int64(limits.maxBytes) {
        return PreparedImage(data: toBase64(bytes), mimeType: mimeType)
    }
    if orientation != 1 { image = try upright(image, orientation: orientation) }
    let width = image.width
    let height = image.height
    let scale = min(1, Double(limits.maxWidth) / Double(width), Double(limits.maxHeight) / Double(height))
    var target = ImageSize(width: max(1, Int((Double(width) * scale).rounded())),
                           height: max(1, Int((Double(height) * scale).rounded())))
    while true {
        if let encoded = try encodeWithin(image, size: target, maxBytes: limits.maxBytes, jpegFirst: mimeType == "image/jpeg") {
            let from = ImageSize(width: width, height: height)
            return PreparedImage(data: encoded.data, mimeType: encoded.mimeType,
                                 resized: target == from ? nil : .init(from: from, to: target),
                                 convertedFrom: encoded.mimeType == mimeType ? nil : mimeType)
        }
        if target.width == 1 && target.height == 1 { return nil }
        target = ImageSize(width: max(1, Int(Double(target.width) * 0.75)), height: max(1, Int(Double(target.height) * 0.75)))
    }
}

/// The first image in `bytes`, decoded now rather than when first drawn.
private func decode(_ bytes: [UInt8]) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil), CGImageSourceGetCount(source) > 0,
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw ImageIOFailure() }
    return image
}

/// `image` at `size` in the first encoding whose base64 fits `maxBytes`: PNG, then JPEG at falling qualities, or the
/// JPEG qualities first when `jpegFirst`; nil if none fits.
private func encodeWithin(_ image: CGImage, size: ImageSize, maxBytes: Int,
                          jpegFirst: Bool) throws -> (data: String, mimeType: String)? {
    let same = size.width == image.width && size.height == image.height
    let scaled = same ? image : try resized(image, to: size)
    let png: (mimeType: String, type: UTType, quality: Int?) = ("image/png", .png, nil)
    let jpegs = jpegQualities.map { (mimeType: "image/jpeg", type: UTType.jpeg, quality: Optional($0)) }
    for candidate in jpegFirst ? jpegs + [png] : [png] + jpegs {
        let bytes = try encoded(scaled, type: candidate.type, quality: candidate.quality)
        if base64Length(Int64(bytes.count)) <= Int64(maxBytes) { return (toBase64(bytes), candidate.mimeType) }
    }
    return nil
}

/// `image` encoded as `type`, at `quality` out of 100 for a lossy type.
private func encoded(_ image: CGImage, type: UTType, quality: Int?) throws -> [UInt8] {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
    else { throw ImageIOFailure() }
    var properties: [CFString: Any] = [:]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100 }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageIOFailure() }
    return [UInt8](data as Data)
}

/// `image` drawn at `size`.
private func resized(_ image: CGImage, to size: ImageSize) throws -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: rgbaBitmapInfo)
    else { throw ImageIOFailure() }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    guard let scaled = context.makeImage() else { throw ImageIOFailure() }
    return scaled
}

/// `image` turned upright for EXIF `orientation` 2 to 8: mirrored (2), turned half way (3), flipped (4), or, for 5 to
/// 8, the orientations that swap width and height, transposed. The pixels are moved one by one, as upstream moves them.
private func upright(_ image: CGImage, orientation: Int) throws -> CGImage {
    let width = image.width
    let height = image.height
    let source = try rgbaPixels(image)
    var pixels = [UInt8](repeating: 0, count: source.count)
    let swaps = orientation >= 5
    let outWidth = swaps ? height : width
    for y in 0..<height {
        for x in 0..<width {
            // Where (x, y) lands in the upright image. Upstream flips horizontally unless 4 and vertically unless 2.
            let outX = swaps ? (orientation == 5 || orientation == 8 ? y : height - 1 - y) : (orientation == 4 ? x : width - 1 - x)
            let outY = swaps ? (orientation == 5 || orientation == 6 ? x : width - 1 - x) : (orientation == 2 ? y : height - 1 - y)
            let from = (y * width + x) * 4
            let to = (outY * outWidth + outX) * 4
            pixels[to] = source[from]; pixels[to + 1] = source[from + 1]
            pixels[to + 2] = source[from + 2]; pixels[to + 3] = source[from + 3]
        }
    }
    return try rgbaImage(pixels, width: outWidth, height: swaps ? width : height)
}

private let rgbaBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

/// The RGBA pixels of `image`, rows from the top.
private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ImageIOFailure() }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: rgbaBitmapInfo)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { throw ImageIOFailure() }
    return pixels
}

/// An image of RGBA `pixels`, rows from the top.
private func rgbaImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: space, bitmapInfo: CGBitmapInfo(rawValue: rgbaBitmapInfo), provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw ImageIOFailure() }
    return image
}
#endif
