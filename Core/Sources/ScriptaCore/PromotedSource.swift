import CryptoKit
import Foundation

/// How a source the app promoted into a vault is NAMED, and how that name is recognised again.
///
/// ONE PLACE, BECAUSE A DESTRUCTIVE PATH READS IT. `SubstrateLibraryModel.remove(source:)`
/// recursively unlinks a directory with no trash and no backup, and the only thing standing between
/// it and the operator's own files is "does this name look like one `promote` wrote". Writing that
/// question and its answer in two places is how they come to disagree — and the way they disagree
/// is silent: a matcher that drifts narrow refuses the orphan-recovery the rail exists for, and one
/// that drifts wide admits something the app never wrote.
///
/// The recogniser therefore ROUND-TRIPS THROUGH THE WRITER rather than pattern-matching separately:
/// a readable half that `slug` would not have produced is not a name `directoryName` wrote. `slug`
/// is idempotent on its own output — including at the truncation boundary, where the separator and
/// the character after it are appended in one iteration before the length check, so re-slugging
/// reproduces the same cut — which is what makes that an equality rather than an approximation.
///
/// IT LIVES IN CORE SO IT CAN BE TESTED. It was written in the app target, which has no test
/// target, so the guard on the most destructive path in the app had no test at all.
public enum PromotedSource {

    /// Hex characters of the SHA-256 kept in a directory name — enough to key one operator's
    /// documents apart, short enough to leave the readable half readable.
    ///
    /// NAMED, NOT SPELLED THREE TIMES. The recogniser needs this length and the two offsets around
    /// it; hard-coding them meant changing the digest silently stopped every existing promoted
    /// directory from being recognised, and the failure surfaced as "that is not a source this app
    /// added" about a directory plainly inside the library.
    static let digestLength = 8

    /// The per-source metadata file. THE ENGINE'S CONVENTION, NOT THIS APP'S SIGNATURE — that
    /// distinction is the whole reason `authorshipLine` exists below.
    public static let markerFile = "_meta.md"

    /// The line `promote` writes inside `markerFile`, and the thing that actually identifies a
    /// source as this app's.
    ///
    /// ITS EXISTENCE PROVES NOTHING. `_meta.md` is `vault._source_meta` — the engine's mechanism
    /// for per-source metadata that passages inherit — so an operator building a source by hand
    /// writes one too. There is one on this machine right now
    /// (`core-vault/10-reference/frozen/software-dev/ddia-2e/`), which is what makes this a
    /// correction rather than a precaution: a guard that took the FILE as authorship would have
    /// called a hand-built source ours and recursively deleted it, and its comment would have said
    /// "proof this app made this directory" while proving nothing of the sort.
    ///
    /// The heading is written unconditionally by `SubstrateLibraryVault.meta(title:domains:origin:)`
    /// and appears in no engine-authored or hand-authored source, so it is the discriminator.
    public static let authorshipLine = "# Source metadata — written by Scripta"

    /// Whether `directory` is one this app actually wrote: the name looks right, AND the marker
    /// inside it carries our authorship line.
    ///
    /// BOTH HALVES, because neither is sufficient. The name is a shape an operator's directory can
    /// wear by accident — `backup-20250101` and `photos-20240704` both satisfy it — and the marker
    /// is a convention they may legitimately use. Only the two together say "we wrote this".
    ///
    /// Symlinks are not directories and have no inside; the caller handles those separately,
    /// because unlinking a link cannot touch what it points at.
    public static func isAuthoredDirectory(at directory: URL) -> Bool {
        guard isDirectoryName(directory.lastPathComponent) else { return false }
        let marker = directory.appendingPathComponent(markerFile, isDirectory: false)

        // A BOUNDED READ OF A REGULAR FILE, not `String(contentsOf:)`. This runs on the app's only
        // recursive trashless delete, so the marker is untrusted input from the operator's own
        // folder: `String(contentsOf:)` follows symlinks, reads the whole file into memory with no
        // ceiling, and BLOCKS FOREVER on a FIFO or a character device. A `_meta.md` that is a named
        // pipe would hang the removal task with no timeout; one that is a multi-gigabyte file would
        // spike memory. `lstat` first, insist on a regular file, then read a prefix.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: marker)
        else { return false }
        defer { try? handle.close() }

        // The line sits in the first few hundred bytes of what `promote` writes; 8 KB is generous
        // for a hand-edited one and small enough that a pathological file costs nothing. A marker
        // whose authorship line has been pushed past this reads as not-ours, which is the direction
        // that refuses rather than deletes.
        guard let head = try? handle.read(upToCount: 8 * 1024),
              let text = String(data: head, encoding: .utf8)
        else { return false }
        return text.contains(authorshipLine)
    }

    /// Eight hex characters of a SHA-256 — enough to key one operator's documents apart, short
    /// enough to leave a readable half readable.
    private static func digest(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }
            .joined().prefix(digestLength))
    }

    /// The directory `promote` writes for one origin.
    ///
    /// EVERY PART OF THE NAME IS THE KEY. Keyed on the ORIGIN PATH, not the content: re-ingesting an
    /// edited file has to land on the same directory and replace it, rather than mint a second one
    /// that answers queries beside the first.
    ///
    /// The readable half used to be the TITLE's slug — the engine's title, read back out of the
    /// artefact — so the key was stable and the NAME WAS NOT: editing the heading produced a second
    /// directory for one origin. Derived from the origin's filename instead; the title still
    /// declares itself inside the note, it no longer decides where the note lives.
    public static func directoryName(origin: URL) -> String {
        let readable = ScriptaVault.slug(origin.deletingPathExtension().lastPathComponent)
        return "\(readable.isEmpty ? "document" : readable)-\(digest(origin.standardizedFileURL.path))"
    }

    /// The suffix every directory written for `origin` carries, whichever tier it landed in — what a
    /// sweep for stale copies of one origin matches on.
    public static func digestSuffix(origin: URL) -> String {
        "-\(digest(origin.standardizedFileURL.path))"
    }

    /// Whether `name` is a directory `directoryName` wrote, and nothing else.
    ///
    /// THE SHAPE IS THE AUTHORISATION. `remove(source:)` admits only names that pass this, so the
    /// question it really answers is "may this be recursively deleted". A recorded call can never
    /// pass: capture writes `<Title> — <date> <time>.md`, and the `.md` puts a non-hex character
    /// inside the trailing digest. That is structural rather than incidental — any extension of six
    /// characters or fewer does it.
    public static func isDirectoryName(_ name: String) -> Bool {
        // One slug character, the separator, and the digest.
        guard name.count >= digestLength + 2,
              name.dropLast(digestLength).hasSuffix("-"),
              name.suffix(digestLength).allSatisfy({ digestCharacters.contains($0) })
        else { return false }
        let readable = String(name.dropLast(digestLength + 1))
        return !readable.isEmpty && readable == ScriptaVault.slug(readable)
    }

    /// The alphabet `digest` emits — `%02x`, so lowercase ASCII hex and nothing else. Spelled out
    /// rather than taken from `isHexDigit`, which also admits uppercase and the fullwidth forms.
    private static let digestCharacters = Set("0123456789abcdef")
}
