import Foundation

/// Limits an image the model sees must keep; the defaults below are the coding agent's.
public struct ImageLimits: Sendable, Equatable {
    /// Pixels. Default 2000.
    public var maxWidth: Int
    /// Pixels. Default 2000.
    public var maxHeight: Int
    /// Bytes of base64. Default 4.5 MiB, below Anthropic's 5 MB.
    public var maxBytes: Int
    /// Creates image limits in pixels and bytes of base64.
    public init(maxWidth: Int, maxHeight: Int, maxBytes: Int) {
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxBytes = maxBytes
    }
}

/// The limits `read` uses for each one the conversation model's `inputLimits.images.resize` leaves out.
public let defaultImageLimits = ImageLimits(maxWidth: 2000, maxHeight: 2000, maxBytes: 4_718_592)

/// A width and height in pixels.
public struct ImageSize: Sendable, Equatable {
    /// Pixels.
    public var width: Int
    /// Pixels.
    public var height: Int
    /// Creates a size in pixels.
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// An image the model can take: a supported format, within the limits, as base64.
public struct PreparedImage: Sendable, Equatable {
    /// An image's size before and after it was resized.
    public struct Resize: Sendable, Equatable {
        /// The size before resizing.
        public var from: ImageSize
        /// The size after resizing.
        public var to: ImageSize
        /// Creates a size change.
        public init(from: ImageSize, to: ImageSize) { self.from = from; self.to = to }
    }
    /// Standard base64 of the image bytes.
    public var data: String
    /// The MIME type of `data`.
    public var mimeType: String
    /// Set when the image was resized: its size before and after, for the model to map coordinates back.
    public var resized: Resize?
    /// The original format, set when it differs from `mimeType`: BMP becomes PNG, a large PNG may become JPEG.
    public var convertedFrom: String?
    /// Creates a prepared image.
    public init(data: String, mimeType: String, resized: Resize? = nil, convertedFrom: String? = nil) {
        self.data = data; self.mimeType = mimeType; self.resized = resized; self.convertedFrom = convertedFrom
    }
}

/// Decodes, orients, resizes, and re-encodes images so the model can take them. `read` uses one when given; without
/// one, it passes supported images within the byte limit through as they are. `createImageIOImages()` provides one on
/// ImageIO and Core Graphics.
public protocol ImageProcessor: Sendable {
    /// The image, prepared to fit `limits`, or nil when it cannot be decoded or made to fit. Async, so a processor can
    /// do the work off the caller's executor.
    func prepare(_ bytes: [UInt8], mimeType: String, limits: ImageLimits) async -> PreparedImage?
}

/// Formats every provider takes inline; others, such as BMP, need converting.
internal let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

/// Standard base64 of `bytes`, from Foundation's encoder. Upstream uses `btoa` over 8 KiB binary-string chunks.
internal func toBase64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

/// The length of the base64 of `byteLength` bytes.
internal func base64Length(_ byteLength: Int64) -> Int64 { (byteLength + 2) / 3 * 4 }
