import Foundation

// MARK: - A conversation, as it is kept between launches
//
// Doc 4 §2's Ask is "Clovis's generation, streaming and persisted conversations, carrying the vault
// Ask's disclosure contract". These are the persisted half, and they live in the PACKAGE rather
// than the app target because Doc 4 §6 says anything rebuilt lands here — `IndexBuilder` and
// `Retriever` sat in the app target where `swift test` cannot reach them, "which is why two of
// Phase 0's six defects survived as long as they did".
//
// THE ONE THING THIS FILE EXISTS TO GET RIGHT is that a passage kept on disk comes back carrying
// the same spine it went in with. An answer whose citations lost `confidence` and `document_class`
// on the way through JSON is the Boundary Principle's failure re-created one layer over: the
// history renders, looks identical to a healthy one, and quietly claims every past citation was
// settled knowledge. `StoredPassage` is therefore a TOTAL, INVERTIBLE projection — not a smaller
// passage — and `AskConversationTests` asserts the round trip rather than trusting this comment.

/// One passage as it survives a relaunch.
///
/// A PROJECTION WITH AN EXACT INVERSE, not a second passage type. Every spine axis is carried, and
/// each is stored as the token the ENGINE uses so a stored conversation and a live result speak one
/// vocabulary — the alias drift PRINCIPLES' third law records (`class:` written, `document_class:`
/// read, six conversations silently relabelled) was two names for one field, and this is where that
/// could happen again.
public struct StoredPassage: Codable, Equatable, Sendable {
    public let id: String
    public let snippet: String
    public let citation: String
    public let vault: String
    public let status: String
    public let docType: String
    public let confidence: String
    /// `nil` IS A VALUE HERE, and it is the one that needs saying. `PassageDocumentClass.unreported`
    /// deliberately has no wire token — it is a row that never went through the class gate — so it
    /// round-trips as an absent key rather than as a word. Writing a stand-in token would make an
    /// engine verdict out of the absence of one; reading an absent key as `unclassified` would make
    /// a *different* one. Absent in, absent out.
    public let documentClass: String?
    public let domains: [String]
    public let supersedes: [String]

    public init(id: String, snippet: String, citation: String, vault: String, status: String,
                docType: String, confidence: String, documentClass: String?,
                domains: [String], supersedes: [String]) {
        self.id = id
        self.snippet = snippet
        self.citation = citation
        self.vault = vault
        self.status = status
        self.docType = docType
        self.confidence = confidence
        self.documentClass = documentClass
        self.domains = domains
        self.supersedes = supersedes
    }

    /// TOLERANT FOR THE SAME REASON `AskMessage`'s IS, and it has to be or that one's tolerance is
    /// only half true: a throw in here propagates straight out through the array decode, past the
    /// hand-written decoder above it, into the `try?` that turns the whole store into `[]`. A
    /// synthesized decoder with eight required fields is one added field away from erasing every
    /// conversation on disk.
    ///
    /// It does NOT soften the spine. A missing token decodes to the empty string, which
    /// `PassageStatus(rawValue:)` and friends reject — so the citation is withheld by the existing
    /// refusal in `passage`, exactly as an unreadable token is. Absence is carried to the validator,
    /// never resolved before it (PRINCIPLES' third law).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        citation = try c.decodeIfPresent(String.self, forKey: .citation) ?? ""
        vault = try c.decodeIfPresent(String.self, forKey: .vault) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        docType = try c.decodeIfPresent(String.self, forKey: .docType) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        documentClass = try c.decodeIfPresent(String.self, forKey: .documentClass)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        supersedes = try c.decodeIfPresent([String].self, forKey: .supersedes) ?? []
    }
}

extension StoredPassage {
    /// A live passage, flattened for disk. Total: no axis is dropped and none is defaulted.
    public init(_ passage: Passage) {
        self.init(id: passage.id,
                  snippet: passage.snippet,
                  citation: passage.citation,
                  vault: passage.vault,
                  status: passage.status.rawValue,
                  docType: passage.docType.rawValue,
                  confidence: passage.confidence.rawValue,
                  documentClass: passage.documentClass.wireToken,
                  domains: passage.domains,
                  supersedes: passage.supersedes)
    }

    /// Back to a passage, or `nil` when this build has no vocabulary for a token it wrote earlier.
    ///
    /// REFUSES RATHER THAN DEFAULTS, which is the same stance `WirePassage.mapped()` takes on the
    /// live path and is here for a sharper reason: an unreadable stored token means the app was
    /// DOWNGRADED past a spine value it had already written, and the honest reading of that is "this
    /// build cannot show you that citation", not a plausible substitute. A dropped citation is
    /// visible; a relabelled one is not.
    public var passage: Passage? {
        guard let status = PassageStatus(rawValue: status),
              let docType = PassageDocType(rawValue: docType),
              let confidence = PassageConfidence(rawValue: confidence),
              let documentClass = Self.documentClass(from: documentClass)
        else { return nil }
        return Passage(id: id, snippet: snippet, citation: citation, vault: vault,
                       status: status, docType: docType, confidence: confidence,
                       documentClass: documentClass, domains: domains, supersedes: supersedes)
    }

    /// The inverse of `PassageDocumentClass.wireToken`, absence included. Split out because the
    /// `nil`-means-`unreported` arm is the half a `compactMap` would silently get wrong.
    static func documentClass(from token: String?) -> PassageDocumentClass? {
        guard let token else { return .unreported }
        return PassageDocumentClass.named(token)
    }
}

/// One turn. A user's question, or an answer with everything that stood behind it.
public struct AskMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public let fromUser: Bool
    public var text: String
    /// The passages this answer was generated over — the spine intact, per Doc 4 §2's direction
    /// rule. Empty on a user turn.
    public var passages: [StoredPassage]
    /// Which generator produced it (the badge under the bubble); `nil` for a user turn.
    public var engineLabel: String?
    /// `index_version` — the value Doc 3 §6 asks an in-app answer and a CLI answer to agree on.
    /// Kept per ANSWER rather than per conversation: a scope is recomposed between turns, and a
    /// version stamped once at the top would claim two answers came off one index.
    public var indexVersion: String?

    /// Written before the engine answered Ask, so its citations were local call chunks and cannot
    /// be reconstituted as passages.
    ///
    /// A FLAG RATHER THAN AN EMPTY LIST, because those two are the same shape on screen and are not
    /// the same claim: an answer that cited nothing and an answer whose citations this build can no
    /// longer express render identically, and the second one silently understates what it stood on.
    /// The surface says so; the Boundary Principle's cure is a field on the thing that crosses.
    public var citationsNotCarried: Bool

    public init(id: UUID = UUID(), fromUser: Bool, text: String,
                passages: [StoredPassage] = [], engineLabel: String? = nil,
                indexVersion: String? = nil, citationsNotCarried: Bool = false) {
        self.id = id
        self.fromUser = fromUser
        self.text = text
        self.passages = passages
        self.engineLabel = engineLabel
        self.indexVersion = indexVersion
        self.citationsNotCarried = citationsNotCarried
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromUser, text, passages, engineLabel, indexVersion, citationsNotCarried
        /// The pre-merge citation list. Decoded ONLY to learn whether there was one.
        case sources
    }

    /// TOLERANT ON PURPOSE, and the alternative is what makes it necessary: the store is one JSON
    /// array read with `try?`, so a single missing key throws and every conversation the operator
    /// has ever had is silently replaced by an empty list. That failure looks exactly like a first
    /// launch. Absent keys are therefore read as their absence rather than as a decode failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // `decodeIfPresent` DOWN TO THE LAST TWO. These were `decode`, which made the tolerance
        // above only partly true: one malformed message still threw, propagated through the array,
        // and hit the `try?` that turns the whole store into `[]`. A defence with a hole the size of
        // its own justification is not a defence. A message with no `fromUser` reads as an answer
        // (the safer of the two — a question attributed to the assistant is a lie about who spoke);
        // absent text reads as empty, which the surface already draws as a turn with nothing in it.
        fromUser = try c.decodeIfPresent(Bool.self, forKey: .fromUser) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        passages = try c.decodeIfPresent([StoredPassage].self, forKey: .passages) ?? []
        engineLabel = try c.decodeIfPresent(String.self, forKey: .engineLabel)
        indexVersion = try c.decodeIfPresent(String.self, forKey: .indexVersion)
        if let flag = try c.decodeIfPresent(Bool.self, forKey: .citationsNotCarried) {
            citationsNotCarried = flag
        } else {
            // An answer written by the old model that HAD citations. `sources` is read as an opaque
            // array — its element type is gone and nothing here wants it, only whether it was there.
            let had = (try? c.decodeIfPresent([AnyCodableSource].self, forKey: .sources))??.isEmpty == false
            citationsNotCarried = had && passages.isEmpty
        }
    }

    /// Explicit because `sources` is a read-only key: it exists to be understood on the way in and
    /// must not be written back, or the retired shape would be re-emitted forever.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fromUser, forKey: .fromUser)
        try c.encode(text, forKey: .text)
        try c.encode(passages, forKey: .passages)
        try c.encodeIfPresent(engineLabel, forKey: .engineLabel)
        try c.encodeIfPresent(indexVersion, forKey: .indexVersion)
        try c.encode(citationsNotCarried, forKey: .citationsNotCarried)
    }
}

/// A pre-merge `Source` row, decoded for its EXISTENCE and nothing else. Every field is optional
/// because none is read: the type exists so `sources: [...]` counts rather than throws.
struct AnyCodableSource: Codable {
    var title: String?
}

/// What becomes of the answer a Stop landed on.
///
/// IN THE PACKAGE BECAUSE IT IS A RULE, NOT A GESTURE. Doc 4 §6: anything rebuilt lands where
/// `swift test` can reach it. The decision — keep and mark, or remove — is the whole of what Stop
/// means for the transcript, and leaving it inline in an app-target `@MainActor` method would put
/// it exactly where this project has already recorded that two defects survived for want of a test.
public enum InterruptedTurn {

    public enum Outcome: Equatable {
        /// The thread does not end on an answer — a Stop during retrieval, before any placeholder.
        case nothingToClose
        /// No token had arrived. The empty placeholder is removed; its id is returned so the caller
        /// can drop the disclosure recorded against it.
        case removed(UUID)
        /// Text had arrived and is KEPT, with the marker appended.
        case marked(UUID)
    }

    /// Close the trailing assistant turn.
    ///
    /// The two outcomes are two different states and must not collapse: partial text is an answer
    /// the reader may want and is kept, while an empty bubble is not a partial answer — it is a
    /// claim that the model replied with nothing. Marking the first is what stops a truncated
    /// answer reading as a complete one once `thinking` and `running` are cleared and no spinner
    /// distinguishes them.
    public static func close(_ messages: inout [AskMessage], marker: String) -> Outcome {
        guard let last = messages.indices.last, !messages[last].fromUser else { return .nothingToClose }
        let id = messages[last].id
        if messages[last].text.isEmpty {
            messages.remove(at: last)
            return .removed(id)
        }
        messages[last].text += marker
        return .marked(id)
    }
}

/// A thread, listed only inside the workspace it happened in.
public struct AskConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var created: Date
    /// The workspace this happened in — the privacy wall applies to chat history too.
    ///
    /// THE WORKSPACE, NOT THE SCOPE, and the choice is deliberate now that Ask reads a bound scope.
    /// Two workspaces can be bound to one scope, and their threads must still not see each other;
    /// keying on the scope would merge them the day that happened. The workspace is the partition
    /// everything else in this app already walls on.
    public var workspace: String
    public var messages: [AskMessage]

    public init(id: UUID = UUID(), title: String = "New conversation", created: Date = Date(),
                workspace: String, messages: [AskMessage] = []) {
        self.id = id
        self.title = title
        self.created = created
        self.workspace = workspace
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, created, workspace, messages
        /// What the field was called before Doc 4 §7 retired the word. Read, never written.
        case group
    }

    /// Reads `workspace`, falling back to the older `group`, and writes only `workspace` — so the
    /// rename migrates on the next save rather than through a migration step, and an install that
    /// never asks anything keeps its history either way.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New conversation"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
            ?? c.decodeIfPresent(String.self, forKey: .group)
            ?? ""
        messages = try c.decodeIfPresent([AskMessage].self, forKey: .messages) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(created, forKey: .created)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(messages, forKey: .messages)
    }
}
