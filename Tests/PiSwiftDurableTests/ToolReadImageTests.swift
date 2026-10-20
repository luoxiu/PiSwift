#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private typealias Rgb = [UInt8]

/// A `width` by `height` image of `block`-pixel squares coloured row by row from `colors`.
private func blocks(_ colors: [[Rgb]], block: Int) -> (rgba: [UInt8], width: Int, height: Int) {
    let width = colors[0].count * block
    let height = colors.count * block
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            rgba.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: colors[y / block][x / block] + [255])
        }
    }
    return (rgba, width, height)
}

/// RGBA pixels of a `width` by `height` image: red, with a green top-left pixel.
private func pixels(_ width: Int, _ height: Int) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<width * height { rgba[index * 4] = 255; rgba[index * 4 + 3] = 255 }
    rgba[0] = 0; rgba[1] = 255
    return rgba
}

private enum Format { case png, jpeg }

private func encodeRgba(_ rgba: [UInt8], _ width: Int, _ height: Int, _ format: Format) throws -> [UInt8] {
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let type = format == .png ? UTType.png : UTType.jpeg
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return [UInt8](data as Data)
}

private func encode(_ width: Int, _ height: Int, _ format: Format) throws -> [UInt8] {
    try encodeRgba(pixels(width, height), width, height, format)
}

/// Noise, which neither PNG nor JPEG compresses well, so the byte limit decides.
private func noisyPng(_ width: Int, _ height: Int) throws -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt32 = 1
    for index in rgba.indices {
        seed = seed &* 1_103_515_245 &+ 12345
        rgba[index] = index % 4 == 3 ? 255 : UInt8(seed >> 24)
    }
    return try encodeRgba(rgba, width, height, .png)
}

/// A 24-bit BMP, which providers do not take inline.
private func bmp(_ width: Int, _ height: Int) -> [UInt8] {
    let row = (width * 3 + 3) / 4 * 4
    var bytes = [UInt8](repeating: 0, count: 54 + row * height)
    func uint32(_ value: Int, at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * index)) & 255) }
    }
    bytes[0] = 0x42; bytes[1] = 0x4d
    uint32(bytes.count, at: 2); uint32(54, at: 10); uint32(40, at: 14)
    uint32(width, at: 18); uint32(height, at: 22)
    bytes[26] = 1; bytes[28] = 24
    uint32(row * height, at: 34)
    for y in 0..<height { for x in 0..<width { bytes[54 + y * row + x * 3 + 2] = 255 } }
    return bytes
}

private let gifData = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

/// A 1x1 GIF with its logical screen size set to `width` by `height`.
private func gif(_ width: Int = 1, _ height: Int = 1) -> [UInt8] {
    var bytes = [UInt8](Data(base64Encoded: gifData)!)
    bytes[6] = UInt8(width & 255); bytes[7] = UInt8(width >> 8)
    bytes[8] = UInt8(height & 255); bytes[9] = UInt8(height >> 8)
    return bytes
}

/// A TIFF header whose first directory holds only Orientation = `orientation`.
private func tiff(_ orientation: Int, littleEndian: Bool) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 26)
    func put(_ value: Int, at offset: Int, size: Int) {
        for index in 0..<size {
            let shift = 8 * (littleEndian ? index : size - 1 - index)
            bytes[offset + index] = UInt8((value >> shift) & 255)
        }
    }
    bytes[0] = littleEndian ? 0x49 : 0x4d; bytes[1] = bytes[0]
    put(42, at: 2, size: 2); put(8, at: 4, size: 4); put(1, at: 8, size: 2)
    put(0x0112, at: 10, size: 2); put(3, at: 12, size: 2); put(1, at: 14, size: 4)
    put(orientation, at: 18, size: 2)
    return bytes
}

private let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0]

/// `jpeg` with an APP1 segment whose EXIF says `orientation`, after an APP0 segment when `app0`.
private func withOrientation(_ jpeg: [UInt8], _ orientation: Int, little: Bool = false, app0: Bool = false) -> [UInt8] {
    let exif = exifHeader + tiff(orientation, littleEndian: little)
    let app1: [UInt8] = [0xff, 0xe1, UInt8((exif.count + 2) >> 8), UInt8((exif.count + 2) & 255)] + exif
    let app0Segment: [UInt8] = app0 ? [0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0] : []
    return Array(jpeg[0..<2]) + app0Segment + app1 + Array(jpeg[2...])
}

/// A RIFF WebP with a dummy `VP8 ` chunk and an `EXIF` chunk saying `orientation`, its TIFF data bare or prefixed.
private func webpWithOrientation(_ orientation: Int, prefixed: Bool) -> [UInt8] {
    func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let size = data.count
        return Array(type.utf8) + [UInt8(size & 255), UInt8((size >> 8) & 255), 0, 0] + data + (size % 2 == 1 ? [0] : [])
    }
    let exif = (prefixed ? exifHeader : []) + tiff(orientation, littleEndian: true)
    let body = Array("WEBP".utf8) + chunk("VP8 ", [1, 2, 3]) + chunk("EXIF", exif)
    return Array("RIFF".utf8) + [UInt8(body.count & 255), UInt8((body.count >> 8) & 255), 0, 0] + body
}

private func decodedImage(_ data: String) throws -> (width: Int, height: Int, rgba: [UInt8]) {
    let bytes = try #require(Data(base64Encoded: data))
    let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    #expect(drawn)
    return (image.width, image.height, rgba)
}

/// A conversation's model, whatever is asked for.
private struct ImageTestModels: DurableModels {
    let model: Model
    let base = FakeDurableModels()
    func getModel(provider: String, modelId: String) -> Model? { model }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        base.streamSimple(model: model, context: context, options: options)
    }
    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        await base.completeSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await base.fetchDeferred(model: model, handle: handle, options: options)
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}

/// The tool API of a conversation whose model takes `input`, with `resize` as its image limits.
private func imageApi(env: any ExecutionEnv, input: [ModelInput] = [.text, .image],
                      resize: ModelImageResizeOptions? = nil) throws -> ToolExecutionApi {
    let model = Model(id: "test", name: "test", api: .openAICompletions, provider: "test", baseUrl: "http://localhost:0",
        reasoning: false, input: input, cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1000, maxTokens: 100,
        inputLimits: resize.map { ModelInputLimits(images: ModelImageInputLimits(resize: $0)) })
    return ToolExecutionApi(taskId: try TaskID(2), conversationId: rootConversationID, callId: "tool-test",
        registry: .init(), models: ImageTestModels(model: model), env: env,
        agent: { _ in Agent(model: ModelRef(provider: "test", modelId: "test")) })
}

/// One positional read of an opened file.
private struct PositionalRead: Equatable {
    var offset: Int64
    var length: Int
}

/// An opened file whose positional reads are recorded; `onRead` sees each one, after it, with the reads before it.
private actor RecordingReader: BinaryReader {
    private let base: any BinaryReader
    private let onRead: @Sendable (PositionalRead, [PositionalRead]) -> Void
    private(set) var reads: [PositionalRead] = []
    private(set) var closed = false
    init(_ base: any BinaryReader, onRead: @escaping @Sendable (PositionalRead, [PositionalRead]) -> Void = { _, _ in }) {
        self.base = base; self.onRead = onRead
    }
    var largest: Int { reads.map(\.length).max() ?? 0 }
    func info(context: ChordContext) async -> Result<FileInfo, FileError> { await base.info(context: context) }
    func read(offset: Int64, length: Int, context: ChordContext) async -> Result<[UInt8], FileError> {
        let result = await base.read(offset: offset, length: length, context: context)
        let read = PositionalRead(offset: offset, length: length)
        onRead(read, reads)
        reads.append(read)
        return result
    }
    func scanLines(options: ScanLinesOptions, context: ChordContext) async -> Result<LineScan, FileError> {
        await base.scanLines(options: options, context: context)
    }
    func close(context: ChordContext) async { closed = true; await base.close(context: context) }
}

private func messages(_ result: ToolExecutionResult) -> [String] { (result.diagnostics ?? []).map(\.message) }

private func onlyImage(_ result: ToolExecutionResult) throws -> (data: String, mimeType: String) {
    let blocks = toolResultBlocks(result)
    try #require(blocks.count == 1)
    guard case .image(let data, let mimeType) = blocks[0] else { throw ImageTestError.notAnImage }
    return (data, mimeType)
}

private enum ImageTestError: Error { case notAnImage }

@Suite struct ToolReadImageTests {
    private let context = ChordContext.background
    private let processor = createImageIOImages()

    /// Run `read` on `bytes` written to `name`, for a conversation whose model takes `input`.
    private func read(_ name: String, _ bytes: [UInt8], in directory: URL, images: (any ImageProcessor)? = nil,
                      input: [ModelInput] = [.text, .image], resize: ModelImageResizeOptions? = nil,
                      tool: ToolRegistration? = nil) async throws -> ToolExecutionResult {
        try Data(bytes).write(to: directory.appendingPathComponent(name))
        let api = try imageApi(env: LocalExecutionEnv(cwd: directory.path), input: input, resize: resize)
        let tool = try tool ?? createReadTool(options: .init(images: images))
        return try await tool.execute(["path": .string(name)], api, context)
    }

    /// Run `read` on `bytes` written to `name` through a `RecordingReader`.
    private func readRecorded(_ name: String, _ bytes: [UInt8], in directory: URL,
                              onRead: @escaping @Sendable (PositionalRead, [PositionalRead]) -> Void = { _, _ in })
        async throws -> (result: ToolExecutionResult, reader: RecordingReader) {
        try Data(bytes).write(to: directory.appendingPathComponent(name))
        let env = LocalExecutionEnv(cwd: directory.path)
        let opened = try await env.openBinaryReader(directory.appendingPathComponent(name).path, options: nil, context: context).get()
        let reader = RecordingReader(opened, onRead: onRead)
        let result = try await executeReadReader(reader, args: .init(path: name), api: imageApi(env: env), context: context)
        return (result, reader)
    }

    // MARK: read of images, without an image processor

    @Test("returns a supported image within the limits as it is")
    func passThrough() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try encode(8, 6, .png)
        let result = try await read("a.png", png, in: directory)
        #expect(toolResultBlocks(result) == [.image(data: toBase64(png), mimeType: "image/png")])
        #expect(messages(result) == ["Read image file [image/png]."])
        let tiny = try await read("a.gif", gif(), in: directory)
        #expect(try onlyImage(tiny) == (toBase64(gif()), "image/gif"))
    }

    @Test("refuses an image too large to send without reading it")
    func tooLarge() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (result, reader) = try await readRecorded("big.png", noisyPng(1100, 1100), in: directory)
        #expect(result.isError == true && toolResultBlocks(result).isEmpty)
        #expect(messages(result).first?.wholeMatch(of: /big\.png is an image \(image\/png\) of .*, too large to send.*/) != nil)
        // Only the header and the chunk walk, in blocks of at most 64 KiB.
        #expect(await reader.largest <= 64 * 1024)
    }

    @Test("refuses an image wider or taller than the limits, by its header")
    func tooWideOrTall() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wide = try await read("wide.png", encode(2001, 2, .png), in: directory)
        #expect(wide.isError == true && toolResultBlocks(wide).isEmpty)
        #expect(messages(wide) == [
            "wide.png is an image (image/png) of 2001x2, larger than 2000x2000, and no image processor is configured to shrink it"
        ])
        let tall = try await read("tall.gif", gif(1, 3000), in: directory)
        #expect(messages(tall).first?.hasPrefix("tall.gif is an image (image/gif) of 1x3000, larger than 2000x2000") == true)
    }

    @Test("refuses a format that needs converting")
    func needsConverting() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await read("a.bmp", bmp(4, 4), in: directory)
        #expect(result.isError == true && toolResultBlocks(result).isEmpty)
        #expect(messages(result) == ["a.bmp is an image (image/bmp) that needs converting, and no image processor is configured"])
    }

    @Test("says when the model sees a placeholder instead of the image")
    func placeholder() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await read("a.png", encode(4, 4, .png), in: directory, input: [.text])
        #expect(toolResultBlocks(result).count == 1)
        #expect(messages(result) == [
            "Read image file [image/png]. The current model does not support images; it sees a placeholder instead."
        ])
    }

    @Test("applies the model's image limits instead of the defaults")
    func modelLimits() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try encode(8, 6, .png)
        let refused = try await read("a.png", png, in: directory, resize: .init(maxWidth: 4))
        #expect(messages(refused).first?.contains("of 8x6, larger than 4x2000,") == true)
        let resized = try await read("a.png", png, in: directory, images: processor, resize: .init(maxWidth: 4))
        let image = try decodedImage(onlyImage(resized).data)
        #expect(image.width == 4 && image.height == 3)
    }

    @Test("lists bmp in the description only with a processor")
    func description() throws {
        #expect(try createReadTool().declaration.description.contains("(jpg, png, gif, webp)"))
        #expect(try createReadTool(options: .init(images: processor)).declaration.description.contains("(jpg, png, gif, webp, bmp)"))
    }

    // MARK: read of an image that changes while it is read

    @Test("reads it again rather than return a cut-off image, even when it grew")
    func grownImage() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try encode(8, 6, .png)
        let file = directory.appendingPathComponent("growing.png")
        let (result, reader) = try await readRecorded("growing.png", png, in: directory) { read, earlier in
            // A writer appends during the first read of the whole file; the second read sees it all.
            guard read.offset == 0 && read.length >= png.count else { return }
            if !earlier.contains(where: { $0.offset == 0 && $0.length >= png.count }) { append(16, to: file) }
        }
        let wholeReads = await reader.reads.filter { $0.offset == 0 && $0.length >= png.count }.map(\.length)
        #expect(wholeReads == [png.count, png.count + 16])
        #expect(try onlyImage(result).data == toBase64(png + [UInt8](repeating: 0, count: 16)))
        #expect(await reader.closed)
    }

    @Test("fails when it changes during the second read too")
    func busyImage() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try encode(8, 6, .png)
        let file = directory.appendingPathComponent("busy.png")
        do {
            _ = try await readRecorded("busy.png", png, in: directory) { read, _ in
                if read.offset == 0 && read.length >= png.count { append(1, to: file) }
            }
            Issue.record("Expected a changed-file error")
        } catch { #expect(String(describing: error) == "busy.png changed while it was read") }
    }

    // MARK: read of images, with the ImageIO image processor

    @Test("passes an image that needs no change through untouched")
    func untouched() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try encode(8, 6, .png)
        let result = try await read("a.png", png, in: directory, images: processor)
        #expect(toolResultBlocks(result) == [.image(data: toBase64(png), mimeType: "image/png")])
        #expect(try onlyImage(await read("a.gif", gif(), in: directory, images: processor)).mimeType == "image/gif")
    }

    @Test("scales an image down to the maximum size, and says how to map coordinates back")
    func scalesDown() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await read("wide.png", encode(4000, 1000, .png), in: directory, images: processor)
        let block = try onlyImage(result)
        let image = try decodedImage(block.data)
        #expect(image.width == 2000 && image.height == 500)
        #expect(messages(result) == [
            "Read image file [\(block.mimeType)]. Resized from 4000x1000 to 2000x500. Multiply coordinates by 2.00 to map them to the original."
        ])
    }

    @Test("rounds the coordinate factor halfway up, as JavaScript's toFixed does")
    func coordinateFactor() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 4250 / 2000 is 2.125 exactly; `%.2f` alone would give 2.12.
        let result = try await read("wide.png", encode(4250, 2, .png), in: directory, images: processor)
        #expect(messages(result).first?.hasSuffix("Resized from 4250x2 to 2000x1. Multiply coordinates by 2.13 to map them to the original.") == true)
    }

    @Test("re-encodes a PNG too large for the byte limit as JPEG at its size, and shrinks it when that is not enough")
    func reencodes() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await read("big.png", noisyPng(1100, 1100), in: directory, images: processor)
        let jpeg = try onlyImage(result)
        #expect(jpeg.mimeType == "image/jpeg")
        #expect(messages(result) == ["Read image file [image/jpeg]. Converted from image/png to image/jpeg."])
        #expect(jpeg.data.utf8.count <= defaultImageLimits.maxBytes)
        let image = try decodedImage(jpeg.data)
        #expect(image.width == 1100 && image.height == 1100)
        var tight = defaultImageLimits
        tight.maxBytes = 200_000
        let shrunk = try #require(await processor.prepare(noisyPng(2000, 2000), mimeType: "image/png", limits: tight))
        #expect(shrunk.data.utf8.count <= tight.maxBytes)
        #expect(shrunk.resized?.from == ImageSize(width: 2000, height: 2000))
        let shrunkTo = try #require(shrunk.resized).to
        #expect(shrunkTo.width < 2000)
    }

    @Test("keeps at least one pixel on each side of an extreme aspect ratio")
    func extremeAspect() async throws {
        let result = await processor.prepare(try encode(6000, 2, .png), mimeType: "image/png", limits: defaultImageLimits)
        #expect(result?.resized == .init(from: .init(width: 6000, height: 2), to: .init(width: 2000, height: 1)))
        // A side that scales below half a pixel still keeps one.
        let thin = await processor.prepare(try encode(8000, 1, .png), mimeType: "image/png", limits: defaultImageLimits)
        #expect(thin?.resized?.to == .init(width: 2000, height: 1))
    }

    @Test("gives up when not even one pixel fits the byte limit")
    func givesUp() async throws {
        var limits = defaultImageLimits
        limits.maxBytes = 8
        #expect(await processor.prepare(try encode(4, 4, .png), mimeType: "image/png", limits: limits) == nil)
    }

    @Test("keeps a JPEG that must be re-encoded a JPEG")
    func jpegStaysJpeg() async throws {
        let result = await processor.prepare(withOrientation(try encode(40, 30, .jpeg), 3), mimeType: "image/jpeg",
                                             limits: defaultImageLimits)
        #expect(result?.mimeType == "image/jpeg")
    }

    @Test("converts a format providers do not take inline to PNG")
    func bmpToPng() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await read("a.bmp", bmp(4, 4), in: directory, images: processor)
        #expect(try onlyImage(result).mimeType == "image/png")
        #expect(messages(result) == ["Read image file [image/png]. Converted from image/bmp to image/png."])
    }

    @Test("reports bytes it cannot decode as an error")
    func undecodable() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = Array(try encode(4, 4, .png).prefix(40))
        let result = try await read("broken.png", broken, in: directory, images: processor)
        #expect(result.isError == true && toolResultBlocks(result).isEmpty)
        #expect(messages(result) == ["broken.png is an image (image/png) that cannot be prepared for the model"])
    }

    @Test("is what createCodingTools(options: .init(images:)) gives read")
    func codingTools() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try createCodingTools(options: .init(images: processor)).tools
        let tool = try #require(tools.first { $0.declaration.name == "read" })
        let result = try await read("b.bmp", bmp(4, 4), in: directory, tool: tool)
        #expect(try onlyImage(result).mimeType == "image/png")
    }

    // MARK: EXIF orientation

    private static let stored: [[Rgb]] = [[[255, 0, 0], [0, 255, 0], [0, 0, 255]], [[255, 255, 255], [0, 0, 0], [255, 255, 0]]]
    private static func mirror<T>(_ grid: [[T]]) -> [[T]] { grid.map { $0.reversed() } }
    // A quarter turn clockwise: the left column, read bottom to top, becomes the top row.
    private static func turn<T>(_ grid: [[T]]) -> [[T]] { grid[0].indices.map { x in grid.map { $0[x] }.reversed() } }
    // What each orientation shows, from its EXIF definition: mirror, then turn clockwise.
    private static let upright: [Int: [[Rgb]]] = [
        1: stored, 2: mirror(stored), 3: turn(turn(stored)), 4: turn(turn(mirror(stored))),
        5: turn(turn(turn(mirror(stored)))), 6: turn(stored), 7: turn(mirror(stored)), 8: turn(turn(turn(stored)))
    ]

    @Test("turns each orientation upright", arguments: 1...8)
    func orientation(_ orientation: Int) async throws {
        let (rgba, width, height) = blocks(Self.stored, block: 16)
        let jpeg = withOrientation(try encodeRgba(rgba, width, height, .jpeg), orientation)
        let prepared = try #require(await processor.prepare(jpeg, mimeType: "image/jpeg", limits: defaultImageLimits))
        let image = try decodedImage(prepared.data)
        let expected = try #require(Self.upright[orientation])
        #expect(image.width == expected[0].count * 16 && image.height == expected.count * 16)
        // The colour at the centre of each block, rounded to full channels against JPEG noise.
        let seen = expected.indices.map { by in
            expected[by].indices.map { bx -> Rgb in
                let at = ((by * 16 + 8) * image.width + bx * 16 + 8) * 4
                return image.rgba[at..<at + 3].map { $0 > 127 ? 255 : 0 }
            }
        }
        #expect(seen == expected)
    }

    @Test("reads big- and little-endian JPEG EXIF, after an APP0 segment, and 1 when absent or out of range")
    func jpegExif() throws {
        let jpeg = try encode(2, 2, .jpeg)
        #expect(exifOrientation(withOrientation(jpeg, 6)) == 6)
        #expect(exifOrientation(withOrientation(jpeg, 8, little: true)) == 8)
        #expect(exifOrientation(withOrientation(jpeg, 5, app0: true)) == 5)
        #expect(exifOrientation(withOrientation(jpeg, 9)) == 1)
        #expect(exifOrientation(jpeg) == 1)
        #expect(exifOrientation(try encode(2, 2, .png)) == 1)
    }

    @Test("reads WebP EXIF chunks with and without the Exif prefix")
    func webpExif() {
        #expect(exifOrientation(webpWithOrientation(6, prefixed: false)) == 6)
        #expect(exifOrientation(webpWithOrientation(3, prefixed: true)) == 3)
    }

    // MARK: imageDimensions

    @Test("reads the size each format declares in its header")
    func dimensions() throws {
        let size = ImageSize(width: 7, height: 5)
        #expect(imageDimensions(try encode(7, 5, .png), mimeType: "image/png") == size)
        #expect(imageDimensions(try encode(7, 5, .jpeg), mimeType: "image/jpeg") == size)
        #expect(imageDimensions(withOrientation(try encode(7, 5, .jpeg), 6, app0: true), mimeType: "image/jpeg") == size)
        #expect(imageDimensions(gif(300, 200), mimeType: "image/gif") == ImageSize(width: 300, height: 200))
        func webp(_ type: String, _ data: [UInt8]) -> [UInt8] {
            Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array(type.utf8) + [0, 0, 0, 0] + data
                + [UInt8](repeating: 0, count: 16)
        }
        // VP8: frame tag, start code, then 14-bit width and height.
        #expect(imageDimensions(webp("VP8 ", [0, 0, 0, 0x9d, 0x01, 0x2a, 0x2c, 0x01, 0xc8, 0x00]), mimeType: "image/webp")
            == ImageSize(width: 300, height: 200))
        // VP8L: signature, then width - 1 and height - 1 in 14 bits each.
        let bits = 299 | (199 << 14)
        #expect(imageDimensions(webp("VP8L", [0x2f, UInt8(bits & 255), UInt8((bits >> 8) & 255), UInt8((bits >> 16) & 255),
                                              UInt8((bits >> 24) & 255)]), mimeType: "image/webp")
            == ImageSize(width: 300, height: 200))
        // VP8X: flags, then width - 1 and height - 1 in 24 bits each.
        #expect(imageDimensions(webp("VP8X", [0, 0, 0, 0, 0x2b, 0x01, 0, 0xc7, 0, 0]), mimeType: "image/webp")
            == ImageSize(width: 300, height: 200))
        #expect(imageDimensions([0xff, 0xd8, 0xff], mimeType: "image/jpeg") == nil)
    }
}

/// Appends `count` zero bytes to `file`.
private func append(_ count: Int, to file: URL) {
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(count: count))
}
#endif
