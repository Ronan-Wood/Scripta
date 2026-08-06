import Foundation

/// One note in a vault, as a reader browsing the corpus sees it.
///
/// THE SIBLING OF `Passage`, NOT A SUBSET OF IT. Both carry the spine, and they carry the SAME
/// spine — a note must not read as one thing in a search result and another in a list. What differs
/// is what each one is evidence of: a passage is evidence that something matched, and its snippet is
/// the matching part; a document is evidence only that something is in the corpus. So there is no
/// snippet here. `passageCount` stands in its place — a size, which cannot be mistaken for a summary
/// the way an arbitrary first sentence could.
///
/// `vault` is what makes this worth asking an engine for rather than reading a directory. An
/// inheriting scope composes notes from several vaults in several places, and which one a note came
/// from — the operator's own, or the tier they share with every project — is resolved by the
/// manifest chain and written nowhere on the workspace's own disk. Measured on the live `cbre`
/// scope 2026-08-06: 33 of its 62 notes are in a vault the workspace folder does not contain.
public struct VaultDocument: Identifiable {
    /// The engine's own id for the note. Stable across a recompose for an unchanged note.
    public let id: String
    /// The note's own title, or nothing. NOT defaulted to a filename here: a title is a claim the
    /// note makes about itself, and a path stem is a claim the filesystem makes. A surface that
    /// wants a fallback picks one visibly.
    public let title: String?
    /// The handle `expand` reads the whole note with.
    ///
    /// `nil` for a note with no passages, and the nil is REPORTED rather than repaired: an empty
    /// note is in the corpus — it is in this list, which is the point — and there is nothing to
    /// expand. A synthesised ref would fail one call later, further from the cause.
    public let expandRef: String?
    public let passageCount: Int
    /// Which vault in the inheritance chain composed this note. Empty when the index carries none,
    /// for the reason `Passage.vault` is empty rather than a stand-in word: provenance invented is
    /// worse than provenance absent.
    public let vault: String
    /// The vault layout's tier for this note — 1 operator, 2 reference, 3 everything else. `nil`
    /// when unrecorded.
    public let tier: Int?
    public let status: PassageStatus
    public let docType: PassageDocType
    public let confidence: PassageConfidence
    public let documentClass: PassageDocumentClass
    public let domains: [String]
    /// A LIST since schema v8 — one live note can consolidate several dead ones. `[]` when none.
    public let supersedes: [String]
    /// The live note that replaced this one, when this one is dead. Scalar: a dead note has exactly
    /// one replacement, and a list would invent a case that does not exist.
    public let supersededBy: String?

    public init(id: String, title: String?, expandRef: String?, passageCount: Int, vault: String,
                tier: Int?, status: PassageStatus, docType: PassageDocType,
                confidence: PassageConfidence, documentClass: PassageDocumentClass,
                domains: [String] = [], supersedes: [String] = [], supersededBy: String? = nil) {
        self.id = id
        self.title = title
        self.expandRef = expandRef
        self.passageCount = passageCount
        self.vault = vault
        self.tier = tier
        self.status = status
        self.docType = docType
        self.confidence = confidence
        self.documentClass = documentClass
        self.domains = domains
        self.supersedes = supersedes
        self.supersededBy = supersededBy
    }

    /// Which withheld classes this note is a member of.
    ///
    /// The same question `Passage.withheldAs` answers, delegated to it rather than reimplemented —
    /// the exhaustive `switch` over `RetrievalClass` that lives there is the gate that stops a class
    /// being added to the engine's default filter without every surface saying whether it can be
    /// one, and a second copy of that logic here would be a second place for it to be wrong.
    public var withheldAs: [RetrievalClass] {
        Passage(id: id, snippet: "", citation: "", vault: vault, status: status, docType: docType,
                confidence: confidence, documentClass: documentClass, domains: domains,
                supersedes: supersedes).withheldAs
    }
}
