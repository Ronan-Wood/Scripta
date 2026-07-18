import Foundation
import Compression

/// A minimal zip reader — just enough for OOXML (.pptx/.docx are zips of XML with stored or
/// deflate entries). Written in-repo to keep the app dependency-free; no zip64, no encryption,
/// graceful errors on anything exotic. Apple's `COMPRESSION_ZLIB` is raw DEFLATE, which is
/// exactly what zip entries use.
///
/// Input is attacker-influenced (users import arbitrary documents), so every offset/length read
/// from the archive is bounds-checked before use and the decompression buffer is sized from the
/// compressed payload — never from the archive's self-declared uncompressed size.
enum MiniZip {
    enum ZipError: Error { case notAZip, entryNotFound, unsupported, corrupt }

    /// An opened archive. The file bytes are read and the central directory parsed ONCE; reuse the
    /// returned value to extract many entries without re-reading/re-parsing the whole file per entry.
    struct Archive {
        fileprivate let data: Data
        fileprivate let entries: [Entry]
        fileprivate let index: [String: Int]   // name → entries index (first occurrence wins), O(1) lookup

        /// All entry names in the archive.
        var names: [String] { entries.map(\.name) }

        /// Decompressed contents of one entry.
        func read(_ name: String) throws -> Data {
            guard let i = index[name] else { throw ZipError.entryNotFound }
            return try MiniZip.extract(entries[i], from: data)
        }
    }

    /// Reads + parses the archive once. Reuse the returned `Archive` to extract several entries.
    static func open(_ url: URL) throws -> Archive {
        let data = try Data(contentsOf: url)
        let entries = try centralDirectory(of: data)
        var index = [String: Int](minimumCapacity: entries.count)
        for (i, e) in entries.enumerated() where index[e.name] == nil { index[e.name] = i }
        return Archive(data: data, entries: entries, index: index)
    }

    // MARK: - Internals

    fileprivate struct Entry {
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
            guard offset >= 0, offset + 46 <= data.count,
                  data[offset] == 0x50, data[offset + 1] == 0x4b,
                  data[offset + 2] == 0x01, data[offset + 3] == 0x02 else { throw ZipError.corrupt }
            let method = UInt16(u16(data, offset + 10))
            let compressed = u32(data, offset + 20)
            let uncompressed = u32(data, offset + 24)
            let nameLen = u16(data, offset + 28)
            let extraLen = u16(data, offset + 30)
            let commentLen = u16(data, offset + 32)
            let localOffset = u32(data, offset + 42)
            // The variable-length name/extra/comment are attacker-controlled: confirm the whole
            // record lies within the buffer before slicing the name or advancing to the next record.
            let recordEnd = offset + 46 + nameLen + extraLen + commentLen
            guard recordEnd <= data.count else { throw ZipError.corrupt }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            out.append(Entry(name: name, method: method, compressedSize: compressed,
                             uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            offset = recordEnd
        }
        return out
    }

    fileprivate static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let lo = entry.localHeaderOffset
        guard lo >= 0, lo + 30 <= data.count,
              data[lo] == 0x50, data[lo + 1] == 0x4b,
              data[lo + 2] == 0x03, data[lo + 3] == 0x04 else { throw ZipError.corrupt }
        // Sizes come from the CENTRAL entry (the local header may defer to a data descriptor);
        // name/extra lengths must come from the LOCAL header.
        let nameLen = u16(data, lo + 26)
        let extraLen = u16(data, lo + 28)
        let start = lo + 30 + nameLen + extraLen
        guard entry.compressedSize >= 0, start >= 0, start + entry.compressedSize <= data.count else {
            throw ZipError.corrupt
        }
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
        guard !payload.isEmpty else { throw ZipError.corrupt }
        // `expected` (the entry's declared uncompressed size) is attacker-controlled — never trust it
        // to size the buffer (a tiny entry could declare ~4 GB and exhaust memory, or under-declare
        // and silently truncate). DEFLATE tops out ~1032:1, so the TRUE upper bound is the payload's
        // plausible inflate size, capped absolutely. Start from `expected`, but if a decode fills the
        // buffer exactly (which may mean truncation), grow toward that bound and re-decode — so an
        // under-declared size can't silently truncate the extracted text (audit L12).
        let maxInflate = 512 * 1024 * 1024   // no OOXML text part is remotely this large
        let ratio = payload.count.multipliedReportingOverflow(by: 1100)
        let ratioCap = min(ratio.overflow ? maxInflate : ratio.partialValue &+ 4096, maxInflate)
        var capacity = max(64, min(expected > 0 ? expected : ratioCap, ratioCap))
        while true {
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
            if written < capacity {   // decode finished with room to spare → complete
                out.removeSubrange(written..<out.count)
                return out
            }
            // Buffer filled exactly: possibly truncated. A real DEFLATE stream can't exceed ratioCap,
            // so filling that means a corrupt/over-ratio (or over-ceiling) entry — refuse. Else grow.
            guard capacity < ratioCap else { throw ZipError.corrupt }
            capacity = min(capacity * 2, ratioCap)
        }
    }
}
