import Foundation
import Compression

/// A minimal zip reader — just enough for OOXML (.pptx/.docx are zips of XML with stored or
/// deflate entries). Written in-repo to keep the app dependency-free; no zip64, no encryption,
/// graceful errors on anything exotic. Apple's `COMPRESSION_ZLIB` is raw DEFLATE, which is
/// exactly what zip entries use.
enum MiniZip {
    enum ZipError: Error { case notAZip, entryNotFound, unsupported, corrupt }

    /// All entry names in the archive.
    static func entries(of url: URL) throws -> [String] {
        try centralDirectory(of: try Data(contentsOf: url)).map(\.name)
    }

    /// Decompressed contents of one entry.
    static func read(_ name: String, from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let entry = try centralDirectory(of: data).first(where: { $0.name == name }) else {
            throw ZipError.entryNotFound
        }
        return try extract(entry, from: data)
    }

    // MARK: - Internals

    private struct Entry {
        let name: String
        let method: UInt16          // 0 = stored, 8 = deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func u16(_ d: Data, _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    private static func u32(_ d: Data, _ i: Int) -> Int {
        Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
    }

    private static func centralDirectory(of data: Data) throws -> [Entry] {
        // End-of-central-directory record: scan backward for its signature (0x06054b50)
        // within the last 64KB + 22 bytes (max comment length).
        guard data.count >= 22 else { throw ZipError.notAZip }
        let scanStart = max(0, data.count - 65_557)
        var eocd = -1
        var i = data.count - 22
        while i >= scanStart {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i; break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let count = u16(data, eocd + 10)
        var offset = u32(data, eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  data[offset] == 0x50, data[offset + 1] == 0x4b,
                  data[offset + 2] == 0x01, data[offset + 3] == 0x02 else { throw ZipError.corrupt }
            let method = UInt16(u16(data, offset + 10))
            let compressed = u32(data, offset + 20)
            let uncompressed = u32(data, offset + 24)
            let nameLen = u16(data, offset + 28)
            let extraLen = u16(data, offset + 30)
            let commentLen = u16(data, offset + 32)
            let localOffset = u32(data, offset + 42)
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            out.append(Entry(name: name, method: method, compressedSize: compressed,
                             uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    private static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let lo = entry.localHeaderOffset
        guard lo + 30 <= data.count,
              data[lo] == 0x50, data[lo + 1] == 0x4b,
              data[lo + 2] == 0x03, data[lo + 3] == 0x04 else { throw ZipError.corrupt }
        // Sizes come from the CENTRAL entry (the local header may defer to a data descriptor);
        // name/extra lengths must come from the LOCAL header.
        let nameLen = u16(data, lo + 26)
        let extraLen = u16(data, lo + 28)
        let start = lo + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expected: entry.uncompressedSize)
        default:
            throw ZipError.unsupported
        }
    }

    private static func inflate(_ payload: Data, expected: Int) throws -> Data {
        let capacity = max(expected, 64)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ZipError.corrupt }
        out.removeSubrange(written..<out.count)
        return out
    }
}
