import XCTest
import Compression

/// Covers the hand-rolled ZIP reader used to extract text from user-imported .pptx/.docx — an
/// attacker-influenced parser. Regressions here mean a crash on a crafted file, a memory bomb, or
/// silently truncated text (audit L14; locks in the H2/M5/L12 fixes).
final class MiniZipTests: XCTestCase {

    // MARK: - fixture builder (a minimal single-entry zip; sizes/nameLen overridable for the bad cases)

    private func rawDeflate(_ data: Data) -> Data {
        var dst = [UInt8](repeating: 0, count: data.count + 128)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&dst, dst.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        return Data(dst.prefix(n))
    }

    /// method 0 = stored, 8 = deflate. `declaredUncompressed`/`cdNameLen` override the central-dir
    /// fields for the malformed/under-declared cases (default = the true values).
    private func makeZip(name: String, content: Data, method: UInt16,
                         declaredUncompressed: UInt32? = nil, cdNameLen: UInt16? = nil) -> Data {
        let payload = method == 8 ? rawDeflate(content) : content
        let uncompressed = declaredUncompressed ?? UInt32(content.count)
        var out = Data()
        func u16(_ v: UInt16) { out.append(UInt8(v & 0xff)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        let nameBytes = Array(name.utf8)

        // Local file header (30 bytes + name + payload)
        out.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        u16(20); u16(0); u16(method); u16(0); u16(0)             // ver, flags, method, time, date
        u32(0); u32(UInt32(payload.count)); u32(uncompressed)    // crc, comp, uncomp
        u16(UInt16(nameBytes.count)); u16(0)                     // nameLen, extraLen
        out.append(contentsOf: nameBytes)
        out.append(payload)

        // Central directory
        let cdOffset = out.count
        out.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
        u16(20); u16(20); u16(0); u16(method); u16(0); u16(0)    // verMade, verNeed, flags, method, time, date
        u32(0); u32(UInt32(payload.count)); u32(uncompressed)    // crc, comp, uncomp
        u16(cdNameLen ?? UInt16(nameBytes.count)); u16(0); u16(0) // nameLen, extraLen, commentLen
        u16(0); u16(0); u32(0)                                    // diskStart, intAttrs, extAttrs
        u32(0)                                                    // local header offset
        out.append(contentsOf: nameBytes)
        let cdSize = out.count - cdOffset

        // End of central directory
        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        u16(0); u16(0); u16(1); u16(1)                           // disk, cdDisk, entriesThisDisk, entriesTotal
        u32(UInt32(cdSize)); u32(UInt32(cdOffset)); u16(0)
        return out
    }

    private func write(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mz-\(UUID()).zip")
        try data.write(to: url)
        return url
    }

    // MARK: - tests

    func testDeflateEntryReadsFully() throws {
        let body = Data("Hello Scripta ".utf8.map { $0 }) + Data(String(repeating: "content ", count: 300).utf8)
        let url = try write(makeZip(name: "word/document.xml", content: body, method: 8))
        let archive = try MiniZip.open(url)
        XCTAssertEqual(archive.names, ["word/document.xml"])
        XCTAssertEqual(try archive.read("word/document.xml"), body)
    }

    func testStoredEntryReadsFully() throws {
        let body = Data("plain stored bytes".utf8)
        let url = try write(makeZip(name: "a.txt", content: body, method: 0))
        XCTAssertEqual(try MiniZip.open(url).read("a.txt"), body)
    }

    func testMissingEntryThrows() throws {
        let url = try write(makeZip(name: "a.txt", content: Data("x".utf8), method: 0))
        XCTAssertThrowsError(try MiniZip.open(url).read("nope"))
    }

    func testOversizedCentralDirNameLenThrowsNotCrash() throws {
        // A central-directory nameLen that runs past EOF must throw ZipError.corrupt, not trap (H2).
        let url = try write(makeZip(name: "a.txt", content: Data("x".utf8), method: 0, cdNameLen: 0xFFFF))
        XCTAssertThrowsError(try MiniZip.open(url))
    }

    func testUnderDeclaredUncompressedSizeDecodesFully() throws {
        // A lying (too-small) uncompressed size must NOT silently truncate the extracted text (L12).
        let body = Data(String(repeating: "the quick brown fox ", count: 500).utf8)
        let url = try write(makeZip(name: "d.xml", content: body, method: 8, declaredUncompressed: 5))
        XCTAssertEqual(try MiniZip.open(url).read("d.xml"), body)
    }

    func testNotAZipThrows() throws {
        let url = try write(Data("this is definitely not a zip file at all".utf8))
        XCTAssertThrowsError(try MiniZip.open(url))
    }
}
