// EXIF orientation of JPEG and WebP files, read from the bytes without decoding the image.

/// The EXIF orientation of a JPEG or WebP, 1 to 8; 1 when absent or unreadable.
internal func exifOrientation(_ bytes: [UInt8]) -> Int {
    let tiff = tiffStart(bytes)
    if tiff < 0 || tiff + 8 > bytes.count { return 1 }
    let little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49
    func u16(_ at: Int) -> Int {
        little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }
    func u32(_ at: Int) -> Int {
        little
            ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
            : Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
    }
    let directory = tiff + u32(tiff + 4)
    if directory + 2 > bytes.count { return 1 }
    let entries = u16(directory)
    for index in 0..<entries {
        let entry = directory + 2 + index * 12
        if entry + 12 > bytes.count { return 1 }
        // Tag 0x0112 is Orientation, a SHORT whose value sits in the entry.
        if u16(entry) == 0x0112 {
            let value = u16(entry + 8)
            return value >= 1 && value <= 8 ? value : 1
        }
    }
    return 1
}

/// Where the TIFF header of a JPEG's APP1 or a WebP's EXIF chunk starts; -1 when there is none.
private func tiffStart(_ bytes: [UInt8]) -> Int {
    if bytes.count >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8 {
        var offset = 2
        while offset + 4 <= bytes.count {
            if bytes[offset] != 0xff { return -1 }
            let marker = bytes[offset + 1]
            if marker == 0xff { offset += 1; continue }
            if marker == 0xe1 && isExifHeader(bytes, offset + 4) { return offset + 10 }
            offset += 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        return -1
    }
    if ascii(bytes, 0, "RIFF") && ascii(bytes, 8, "WEBP") {
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16
                | Int(bytes[offset + 7]) << 24
            // Some WebP files prefix the TIFF header with "Exif\0\0".
            if ascii(bytes, offset, "EXIF") { return isExifHeader(bytes, offset + 8) ? offset + 14 : offset + 8 }
            // RIFF chunks are padded to an even size.
            offset += 8 + size + size % 2
        }
    }
    return -1
}

private func isExifHeader(_ bytes: [UInt8], _ offset: Int) -> Bool {
    ascii(bytes, offset, "Exif") && offset + 5 < bytes.count && bytes[offset + 4] == 0 && bytes[offset + 5] == 0
}

private func ascii(_ bytes: [UInt8], _ offset: Int, _ text: String) -> Bool {
    let prefix = Array(text.utf8)
    return offset >= 0 && offset + prefix.count <= bytes.count && bytes[offset..<(offset + prefix.count)].elementsEqual(prefix)
}
