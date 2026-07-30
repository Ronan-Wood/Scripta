import SwiftUI
import ScriptaCore

/// Vocabulary — the correction loop's front door: the terms the registry already knows, the
/// acronyms mined from your calls that it doesn't, and the add-a-term dialog both routes into.
/// The registry write itself stays with the presenter (`onAddTerm`), which owns the index sync
/// and the reload that follows it.
struct VocabularySection: View {
    let vocabTerms: [EntityRegistry.Entity]
    let suggestions: [String]
    @Binding var entitySheetTarget: EntitySheetTarget?
    @Binding var addingTerm: Bool
    @Binding var termCanonical: String
    @Binding var termAliases: String
    @Binding var termGloss: String
    let onAddTerm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Vocabulary")
                Spacer()
                Button {
                    termCanonical = ""; termAliases = ""; termGloss = ""
                    addingTerm = true
                } label: {
                    Text("Add term").font(CarbonFont.label(12)).foregroundStyle(Carbon.interactive)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if vocabTerms.isEmpty {
                Text("Teach Scripta your jargon once — it biases transcription, and searching a term finds its expansions too (\"TIM\" finds \"tenants in the market\").")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlexWrap(spacing: Space.x2) {
                    ForEach(vocabTerms, id: \.id) { term in
                        CarbonChip(text: term.name) { entitySheetTarget = EntitySheetTarget(id: term.id, fallbackName: term.name) }
                            .help(term.gloss?.isEmpty == false ? term.gloss!
                                  : term.aliases.joined(separator: ", "))
                    }
                }
            }
            if !suggestions.isEmpty {
                Text("Suggested from your calls — tap to teach:")
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                FlexWrap(spacing: Space.x2) {
                    ForEach(suggestions, id: \.self) { word in
                        Button {
                            termCanonical = word; termAliases = ""; termGloss = ""
                            addingTerm = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                Text(word).font(CarbonFont.label(12))
                            }
                            .foregroundStyle(Carbon.interactive)
                            .padding(.horizontal, Space.x4).padding(.vertical, Space.x2)
                            .background(Carbon.blueSoft, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .alert("Add vocabulary term", isPresented: $addingTerm) {
            TextField("Term (e.g. TIM)", text: $termCanonical)
            TextField("Aliases, comma-separated (e.g. tenants in the market)", text: $termAliases)
            TextField("Meaning (optional)", text: $termGloss)
            Button("Add", action: onAddTerm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Feeds transcription biasing and search — a search for the term also matches its aliases, everywhere.")
        }
    }
}
