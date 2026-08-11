import Foundation

/// The applied filter, over `RetrievalClass` — the same list `Passage.withheldAs` answers for. The
/// client half of `render.applied_filters`.
///
/// Typed rather than stringly BECAUSE of what a string set cost: the exclusion bar modelled
/// conversation sources as a first-class axis while the passage had no such field, and nothing could
/// notice, because "sources" was a string here and nothing at all there. One enum makes the two
/// halves of the disclosure the same list.
///
/// The sentences live here rather than in the view, and that is the one judgement call in this file:
/// they are not a drawing decision, they are `RetrievalClass.gloss` assembled into the claim the
/// engine's `statuses_excluded` / `sources_excluded` fields make. Splitting them from the set they
/// describe would put "nothing withheld is silent" in two modules, which is how the axis got lost
/// the first time.
public struct ExclusionFilter {
    /// What default retrieval searches.
    public static let defaultClasses: Set<RetrievalClass> =
        Set(RetrievalClass.allCases.filter(\.isDefault))

    /// The classes this result set actually searched.
    public var searched: Set<RetrievalClass>
    /// Anything else that narrowed this result set — a clamped `k`, today. Mirrors the engine's
    /// `filters.notes`, which is always present and empty when there is nothing to say.
    public var notes: [String]

    /// WHICH TIERS OF THE COMPOSED CHAIN ANSWERED. `nil` is every vault the scope composes; a list
    /// is the narrowing that was applied. The engine has always sent this
    /// (`WireAppliedFilters.vaults`) and this type dropped it, which was harmless only while the
    /// tier chips re-ran the query on every toggle — the selection on screen and the result on
    /// screen were then in sync by construction. Ask's thread broke that sync deliberately (a
    /// filter describes the NEXT question), so the axis has to travel with the RESULT or a turn
    /// narrowed to one vault is indistinguishable from one that searched the whole chain. The
    /// engine's own words for why: "a reader who cannot see that only one tier answered reads a
    /// partial corpus as the whole one."
    public var vaults: [String]?

    public init(searched: Set<RetrievalClass>, notes: [String] = [], vaults: [String]? = nil) {
        self.searched = searched
        self.notes = notes
        self.vaults = vaults
    }

    public static let standard = ExclusionFilter(searched: defaultClasses)

    /// Canonical order, so a chip does not move when an unrelated one is toggled.
    public var withheld: [RetrievalClass] {
        RetrievalClass.allCases.filter { !searched.contains($0) }
    }

    /// What the reader asked for beyond the default. This is the deviation set, and the only part
    /// of the disclosure that is allowed to carry colour.
    public var included: [RetrievalClass] {
        RetrievalClass.allCases.filter { searched.contains($0) && !$0.isDefault }
    }

    public mutating func toggle(_ klass: RetrievalClass) {
        if searched.contains(klass) { searched.remove(klass) } else { searched.insert(klass) }
    }

    /// The sentence that prevents the wrong conclusion. Names the classes in human terms and then
    /// says what their absence does NOT mean, which is the half a filter readout usually omits.
    public var withheldSentence: String {
        let named = withheld.map(\.gloss)
        guard !named.isEmpty else {
            return "Nothing was withheld. These results are the whole corpus — archived notes, "
                + "superseded notes and call transcripts included."
        }
        let one = named.count == 1
        return "\(Self.sentenceCase(Self.list(named))) \(one ? "was" : "were") not searched. "
            + "\(one ? "Its" : "Their") absence from these results is not evidence "
            + "\(one ? "it does not" : "they do not") exist."
    }

    /// What the reader opened up, said back to them. `nil` at the default, which is what keeps the
    /// quiet case quiet.
    public var inclusionSentence: String? {
        guard !included.isEmpty else { return nil }
        return "Asked for: \(Self.list(included.map(\.gloss))) can appear in these results."
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
