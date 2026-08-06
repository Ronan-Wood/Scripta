import Foundation
import OSLog

// MARK: - The substrate CLI, as a subprocess
//
// EVERY WRITE THE APP MAKES GOES THROUGH HERE, AND NONE OF THEM GOES OVER THE TRANSPORT. Doc 3 §3
// is not a preference: `--read-only` defaults ON and `ingest` is refused at HTTP dispatch, because
// any local process can reach a loopback port and `ingest` writes notes into real vaults that the
// next refresh serves back as settled knowledge. App-hosting narrows the window to "while Scripta
// is open"; it does not make the primitive safe, so the primitive is not exposed. The app owns the
// engine PROCESS (Doc 3 §2), which is exactly what makes a subprocess the natural call — the read
// path is a socket, the write path is a fork.
//
// The consequence, stated once here rather than rediscovered per call site: there is no
// `SubstrateCall` for any of this. A CLI run has an exit status, a stdout and a stderr, and those
// three are what the surface renders. Nothing below promotes them into a refusal vocabulary — the
// engine already writes an actionable sentence on stderr (`FATAL (export): …`,
// `FATAL (class policy): …`) and paraphrasing it here would be the client re-deciding what the
// engine said.

/// One finished CLI run, verbatim.
struct SubstrateRun: Sendable {
    /// The command as the operator would have to type it. Shown, and copyable, because every one of
    /// these is a thing they can re-run themselves — which is the difference between a surface that
    /// wraps a tool and one that hides it.
    let line: String
    /// The process's own exit status. `nil` when it never ran, or was killed rather than exiting.
    let status: Int32?
    let stdout: String
    let stderr: String
    /// The APP's reason the process never started — a missing CLI, a refused exec. Distinct from a
    /// non-zero status, which is the engine's own verdict about the work.
    let launchFailure: String?
    let cancelled: Bool

    var succeeded: Bool { launchFailure == nil && !cancelled && status == 0 }

    /// Everything the process said, in the order a terminal would have shown it. Kept as one block
    /// because splitting the streams in the UI puts a warning that arrived DURING a successful run
    /// somewhere the reader is not looking — `export-transcripts` writes its synced-source warning
    /// to stderr and still exits 0.
    var transcript: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum SubstrateCLI {

    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "SubstrateCLI")

    /// Run one CLI subcommand to completion.
    ///
    /// `nonisolated` and free-standing so a `@MainActor` model can await it without the fork, the
    /// pipe drains and a multi-minute docling run happening on the main actor.
    ///
    /// The parent-death shim is `SubstrateEngine.shim`, reused rather than reimplemented: a docling
    /// ingest holds a torch stack for minutes, and the three exits it covers (quit, force-quit,
    /// crash) are the same three here. Cancellation lands as `terminate()` on the shell, whose trap
    /// group-kills the child — the one thing a bare `Process.terminate()` cannot do when `uv run`
    /// sits in the middle and forks python as a grandchild.
    static func run(_ command: SubstrateEngine.Command, _ arguments: [String]) async -> SubstrateRun {
        let line = displayLine(command, arguments)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", SubstrateEngine.shim, "substrate-cli", command.executable.path]
            + command.arguments + arguments
        if let directory = command.workingDirectory { child.currentDirectoryURL = directory }

        let input = Pipe()
        let out = Pipe()
        let err = Pipe()
        child.standardInput = input
        child.standardOutput = out
        child.standardError = err

        // DRAINED CONTINUOUSLY, not read at exit. A 64 KB pipe nobody empties blocks the writer, and
        // a compose over ~700 notes prints a line per note — so "read it when it finishes" is a
        // deadlock that only shows up on the corpus that matters.
        let stdout = OutputSink()
        let stderr = OutputSink()
        out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        // INSTALLED BEFORE `run()`, and the ordering is the bug it avoids rather than a style. A
        // handler attached after the process has already exited is never called — and `ingest
        // --help`, which the capability probe runs twice on every appearance, is exactly the
        // subprocess fast enough to lose that race. It would present as the Library hanging on a
        // command that had already finished.
        let waiter = Waiter()
        child.terminationHandler = { finished in
            // The shim exits with the child's own status, so this is the ENGINE's verdict rather
            // than the wrapping shell's. A signalled process reports no status at all.
            waiter.finish(finished.terminationReason == .exit ? finished.terminationStatus : nil)
        }

        do {
            try child.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            child.terminationHandler = nil
            return SubstrateRun(line: line, status: nil, stdout: "", stderr: "",
                                launchFailure: "\(error)", cancelled: false)
        }
        log.info("running \(line, privacy: .public)")

        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                waiter.wait(continuation)
            }
        } onCancel: {
            // Both halves of the same stop, because either alone can be the one that lands: SIGTERM
            // trips the shell's trap, and closing our write end trips the shim's EOF watchdog.
            child.terminate()
            try? input.fileHandleForWriting.close()
        }

        // THE TAIL IS READ AFTER THE EXIT, and dropping this loses the one line that matters.
        // `readabilityHandler` is asynchronous: the process can exit with bytes still sitting in
        // the pipe, and clearing the handler at that moment discards them. The bytes at risk are
        // always the LAST ones — which is where `compose` prints "scope 'x' registered" (parsed
        // below to report what the engine actually named) and where every `FATAL` sentence lands.
        // Both write ends are closed by now, so this drains what is left and returns at EOF.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdout.append(out.fileHandleForReading.readDataToEndOfFile())
        stderr.append(err.fileHandleForReading.readDataToEndOfFile())
        try? input.fileHandleForWriting.close()

        let cancelled = Task.isCancelled
        return SubstrateRun(line: line, status: status, stdout: stdout.text, stderr: stderr.text,
                            launchFailure: nil, cancelled: cancelled)
    }

    /// What the operator would type. `~` is folded back so a path they recognise is what they read.
    static func displayLine(_ command: SubstrateEngine.Command, _ arguments: [String]) -> String {
        ([command.executable.path] + command.arguments + arguments)
            .map { quoted(abbreviated($0)) }
            .joined(separator: " ")
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// POSIX single-quoting. Every displayed command is one the operator can paste, so a path with a
    /// space in it has to survive the trip — Scripta's own transcripts folder routinely has one.
    static func quoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./=:~@+,")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The join between a `terminationHandler` that may fire first and a continuation that may be
/// registered first. Whichever arrives second resumes; neither can be dropped, and resuming twice
/// is a crash rather than a possibility.
private final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32?, Never>?
    /// Nested on purpose: the outer optional is "has it finished", the inner is the status, which is
    /// legitimately nil for a signalled process.
    private var finished: Int32??

    func finish(_ status: Int32?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        if waiting == nil { finished = .some(status) }
        lock.unlock()
        waiting?.resume(returning: status)
    }

    func wait(_ continuation: CheckedContinuation<Int32?, Never>) {
        lock.lock()
        let already = finished
        if already == nil { self.continuation = continuation }
        finished = nil
        lock.unlock()
        if let already { continuation.resume(returning: already) }
    }
}

/// A pipe's accumulated bytes. Locked rather than actor-isolated because the writer is a
/// `readabilityHandler` on Foundation's own queue, which cannot await.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - What ingest accepts, ASKED rather than assumed
//
// THERE IS NO FORMAT LIST IN THIS APP, and the day this was written proved why. The surface was
// first read out of `ingest --help`, against an `ingest` that took `--pdf`. Within the hour the
// engine had grown a positional `path`, fourteen detected formats and a REFUSED table — and a
// client carrying `["pdf"]` would have refused a `.docx` the engine now takes, with the engine's
// own answer never asked for. That is the worst failure available here: the client inventing a
// verdict the engine was willing to give.
//
// So the engine is asked, through the entry point it added for exactly this: `substrate formats`.
// It names every accepted format with its extensions and its doc-class rule, AND every refused one
// with the reason it is refused — which is what lets this surface tell an operator "legacy Office
// binary, re-save as .docx" before they spend a minute-long conversion finding out.
//
// The parse is of a text table, and that is a real cost rather than a hidden one. What makes it
// survivable is that every unreadable part degrades to a STATE the UI renders rather than to a
// default it invents: an unparsed table is "the engine did not enumerate its formats" and the file
// is handed over anyway; an unrecognised doc-class rule is `unstated` and nothing is required on
// the operator's behalf. The engine decides in every case; this only ever decides what to say
// while it is deciding.

extension SubstrateCLI {

    /// One format `substrate formats` accepts.
    struct IngestFormat: Sendable, Equatable, Identifiable {
        /// The engine's stable token — `pdf`, `docx`, `image`. Written to `run.json`.
        let token: String
        /// Lowercase, leading dot: `.docx`.
        let extensions: [String]
        let classRule: ClassRule
        /// The engine's own sentence about this format. Carried verbatim; it is where the real
        /// caveats live ("a `#` line is read as structure it may not have meant").
        let note: String

        var id: String { token }
    }

    /// Whether a document class must be declared for this format.
    ///
    /// TRI-STATE, and the third case is the point. `pdf` requires one; every detected format
    /// defaults to absence, because a file EXTENSION is evidence about the container and not about
    /// the document — `.docx` does not mean "a published edition that will not change". A rule this
    /// parser could not read is neither, and must not be silently resolved into either: requiring a
    /// class the engine does not want invents a declaration, and waiving one it does require turns
    /// a legible refusal into a puzzling one.
    enum ClassRule: Sendable, Equatable {
        case required
        case absence
        case unstated
    }

    /// One format the engine will NOT attempt, with its reason.
    struct RefusedFormat: Sendable, Equatable {
        let extensions: [String]
        /// The engine's sentence, verbatim. Every one of them names a remedy or says plainly that
        /// the stack is not installed, which is exactly what a client cannot write for itself.
        let reason: String
    }

    /// The ingest surface of one engine build.
    struct IngestSurface: Sendable, Equatable {
        /// `substrate ingest <path>` — the general entry point. False for an engine that predates
        /// it, where the input goes to a flag instead.
        let usesPositionalPath: Bool
        /// Every flag that can carry the input. Two jobs, which is why it is a list: the FIRST is
        /// what an engine predating the positional needs the file on, and `--md` is the escape
        /// hatch a current one offers — "read PATH as markdown whatever it is named", which is the
        /// remedy the engine's own unknown-extension refusal recommends.
        let inputFlags: [String]
        /// `classes.DECLARABLE_CLASSES`, in the engine's own words.
        let docClasses: [String]
        /// EMPTY IS A STATE — "this engine did not enumerate them" — never "it accepts nothing".
        let formats: [IngestFormat]
        let refused: [RefusedFormat]
        /// `substrate formats`, verbatim, for the disclosure. The parse above is an interpretation;
        /// this is the thing itself, so a reader can check the interpretation.
        let table: String

        /// The format the engine would read this file as, if it named one.
        func format(for file: URL) -> IngestFormat? {
            let ext = "." + file.pathExtension.lowercased()
            return formats.first { $0.extensions.contains(ext) }
        }

        /// The engine's own refusal for this file, BEFORE anything is run. `.tar.gz` is matched on
        /// the full name because that is how the engine matches it — `suffix` alone would see
        /// `.gz`, which is not in either table, and the operator would get "unknown extension"
        /// instead of "METS/Google-Books archive, not verified in this engine".
        func refusal(for file: URL) -> RefusedFormat? {
            let name = file.lastPathComponent.lowercased()
            let ext = "." + file.pathExtension.lowercased()
            return refused.first { $0.extensions.contains { name.hasSuffix($0) || $0 == ext } }
        }

        /// Whether the operator must declare a class before this file can be handed over.
        /// `unstated` requires nothing: see `ClassRule`.
        func requiresClass(for file: URL) -> Bool {
            format(for: file)?.classRule == .required
        }

        /// The flag that reads any file as markdown, when this engine has one.
        var markdownFlag: String? { inputFlags.first { $0 == "--md" } }

        /// How the input reaches the engine when it is not being forced to markdown.
        var acceptsAnyFile: Bool { usesPositionalPath || !inputFlags.isEmpty }
    }

    /// Ask this build what it takes.
    ///
    /// Two calls, both read-only and both milliseconds. `formats` carries the table; `ingest
    /// --help` carries the two things the table does not — the declarable class vocabulary as
    /// argparse's own `choices`, and whether the input goes positionally or on a flag.
    static func ingestSurface(_ cli: SubstrateEngine.Command) async -> IngestSurface {
        async let table = run(cli, ["formats"])
        async let help = run(cli, ["ingest", "--help"])
        let (formats, refused, listing) = parseFormats(await table)
        let (positional, flags, classes) = parseIngestHelp(await help)
        return IngestSurface(usesPositionalPath: positional, inputFlags: flags, docClasses: classes,
                             formats: formats, refused: refused, table: listing)
    }

    /// The `substrate formats` table.
    ///
    /// Parsed by SHAPE rather than by column offset: the token, then a run of dot-prefixed
    /// extensions, then a doc-class field whose three known forms are matched positively, then the
    /// rest as the note. Column widths move when a format with a longer name is added; the shape
    /// does not.
    static func parseFormats(_ run: SubstrateRun) -> ([IngestFormat], [RefusedFormat], String) {
        guard run.succeeded else { return ([], [], "") }
        var accepted: [IngestFormat] = []
        var refused: [RefusedFormat] = []
        for line in run.stdout.components(separatedBy: "\n") {
            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let token = fields.first, token != "format" else { continue }
            // The trailing prose block after the table has no dot-prefixed second field.
            fields.removeFirst()
            var extensions: [String] = []
            while let next = fields.first, next.hasPrefix(".") {
                extensions.append(next.lowercased())
                fields.removeFirst()
            }
            guard !extensions.isEmpty else { continue }
            let rest = fields.joined(separator: " ")
            if token == "REFUSED" {
                refused.append(RefusedFormat(extensions: extensions,
                                             reason: after("—", in: rest) ?? rest))
                continue
            }
            let rule: ClassRule
            let note: String
            if let tail = after("required)", in: rest) {
                (rule, note) = (.required, tail)
            } else if let tail = after("unclassified", in: rest) {
                (rule, note) = (.absence, tail)
            } else {
                (rule, note) = (.unstated, rest)
            }
            accepted.append(IngestFormat(token: token, extensions: extensions, classRule: rule,
                                         note: note))
        }
        return (accepted, refused, run.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func after(_ needle: String, in text: String) -> String? {
        guard let range = text.range(of: needle) else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// `ingest --help`, for the two facts the format table does not carry.
    ///
    /// The positional is detected from argparse's own `positional arguments:` section rather than
    /// from the usage line, because an OPTIONAL positional prints as `[path]` — indistinguishable
    /// from an optional flag once brackets are stripped, which is precisely how the first version
    /// of this parser lost the input argument the moment `ingest` grew one.
    static func parseIngestHelp(_ run: SubstrateRun) -> (Bool, [String], [String]) {
        let help = run.succeeded ? run.stdout : ""
        let positional = section("positional arguments:", of: help)
            .flatMap { $0.split(separator: "\n").first }
            .map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false

        // A flag with an ALL-CAPS metavar that is not the destination. Kept for an engine that
        // predates the positional, and for `--md`'s "read it as markdown whatever it is named".
        // Deduplicated because argparse prints each flag twice — once in the usage line and once
        // in the options block — and `inputFlags.first` would otherwise depend on which came first.
        var seen = Set<String>()
        let flags = matches(in: help, pattern: "--([a-z][a-z0-9-]*)\\s+[A-Z][A-Z0-9_]*")
            .map { $0[1] }
            .filter { $0 != "out" && $0 != "pages" && $0 != "batch" && seen.insert($0).inserted }
        let classes = matches(in: help, pattern: "--doc-class\\s+\\{([^}]+)\\}")
            .first?[1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return (positional, flags.map { "--" + $0 }, classes)
    }

    /// One indented block of an argparse help, from its heading to the next blank line.
    private static func section(_ heading: String, of help: String) -> String? {
        guard let start = help.range(of: heading) else { return nil }
        let rest = help[start.upperBound...].drop(while: { $0 == "\n" })
        guard let end = rest.range(of: "\n\n") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// Capture groups for every match, group 0 included.
    private static func matches(in text: String, pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let r = Range(match.range(at: index), in: text) else { return "" }
                return String(text[r])
            }
        }
    }
}
