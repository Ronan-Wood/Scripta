import SubstrateKit
import SwiftUI
import ScriptaCore

/// One row on the Documents shelf, from either place a document can currently be.
///
/// TWO ORIGINS BECAUSE THERE ARE TWO INGEST PATHS, and this type exists to make the migration
/// between them non-atomic (Doc 4 Phase 4b). `AppModel.importDocument` writes to `Files/` and is
/// visible only to the local index; the Library rail runs the engine's `ingest` + `promote`, which
/// puts a document in the workspace vault where Ask and live recall can reach it. The shelf shows
/// BOTH while the second replaces the first, so no step of that replacement makes a document
/// disappear from view.
///
/// `.local` is the case that retires. When `DocumentImporter` goes, so does it — and the compiler
/// names every site that has to change, which is the point of modelling it this way rather than
/// merging both into one shape and losing the distinction.
struct DocumentRow: Identifiable {
    enum Origin {
        case local(mdURL: URL, file: String)
        case vault(VaultDocument)
    }

    let id: String
    let title: String
    let created: String
    let origin: Origin

    var isLocal: Bool { if case .local = origin { return true }; return false }
}

/// Imported files, newest first — click opens the original.
struct KnowledgeDocumentsSection: View {
    let docs: [DocumentRow]
    @Binding var openDoc: OpenDocTarget?
    @Binding var deleteTarget: KnowledgeView.ItemTarget?
    let onRename: (KnowledgeView.ItemTarget) -> Void
    /// Show a vault document. Passed in rather than resolved here so this view keeps drawing rows
    /// and the screen that owns the sheet keeps owning it.
    let openVaultDocument: (VaultDocument) -> Void
    // Observed here rather than passed down as values: the group and the job list are both read
    // at gesture time (see the live-group re-check below), and a snapshot taken when this row was
    // built is exactly the stale value that check exists to reject.
    @ObservedObject var model = AppModel.shared

    var body: some View {
        if !docs.isEmpty || !model.importJobs.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Documents")
                // In-flight / just-finished imports — the "is it done?" signal.
                ForEach(model.importJobs) { job in ImportJobRow(job: job) }
                VStack(spacing: 1) {
                    ForEach(docs.prefix(6)) { doc in
                        HStack(spacing: Space.x3) {
                            CarbonIcon(name: "document", size: 14, color: Carbon.iconSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.title).font(CarbonFont.medium(13))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                Text(doc.created).font(CarbonFont.label(11))
                                    .foregroundStyle(Carbon.textHelper)
                            }
                            Spacer()
                            // WHERE IT LIVES, said quietly. A document in the vault is reachable by
                            // Ask and one in `Files/` is not, which is the entire reason for the
                            // migration — so the shelf distinguishes them rather than presenting one
                            // undifferentiated list whose rows behave differently when clicked.
                            if !doc.isLocal {
                                Text(verbatim: "vault").typeface(Register.monoMicro, Ink.textHelper)
                            }
                            if case .local(let mdURL, _) = doc.origin {
                                ItemMenu(
                                    open: {
                                        // verifiedOriginalURL, not a raw folder.appendingPathComponent
                                        // (crosscheck) — matches the other three resolution call sites
                                        // in this feature instead of hand-rolling a fourth, unverified one.
                                        if let url = DocumentImporter.verifiedOriginalURL(atPath: mdURL.path, group: model.activeGroup) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    },
                                    openLabel: "Open original",
                                    onRename: { onRename(.doc(mdURL: mdURL, title: doc.title)) },
                                    onDelete: { deleteTarget = .doc(mdURL: mdURL, title: doc.title) })
                            }
                        }
                        .padding(Space.x4)
                        .background(Carbon.layer)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // M24: view in-app, matching notes/calls — was always-external-open.
                            // "•••" → "Open original" (untouched, just above) still opens
                            // externally for when the real file is actually what's wanted.
                            // Re-verify the LIVE group before opening (crosscheck): `docs` can
                            // still show the outgoing workspace's rows for the duration of
                            // reload()'s async re-fetch after a group switch, and a bare parse()
                            // here would let a stale row open another workspace's document inside
                            // this one's UI (and its delete button then feeds that same mdURL to a
                            // group-agnostic delete).
                            guard case .local(let mdURL, _) = doc.origin else {
                                // A vault document is read through the engine, in the Vault lens —
                                // the same reader every other vault note uses. Routing it into the
                                // local sheet would need a second reader for the same content.
                                if case .vault(let document) = doc.origin { openVaultDocument(document) }
                                return
                            }
                            if let meta = DocumentImporter.parse(mdURL), meta.group == model.activeGroup {
                                openDoc = OpenDocTarget(meta: meta, mdURL: mdURL)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            }
        }
    }
}

/// One import's live state: spinner while extracting, ✓ when added, error text if it failed.
private struct ImportJobRow: View {
    let job: AppModel.ImportJob
    @ObservedObject var model = AppModel.shared

    var body: some View {
        HStack(spacing: Space.x3) {
            switch job.state {
            case .processing:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Carbon.success)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Carbon.danger)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.filename).font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Text(statusText).font(CarbonFont.label(11))
                    .foregroundStyle(job.isFailed ? Carbon.danger : Carbon.textHelper)
                    .lineLimit(2)
            }
            Spacer()
            if case .failed = job.state {
                Button { model.dismissImportJob(job.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Carbon.iconSecondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
    }

    private var statusText: String {
        switch job.state {
        case .processing: return "Analyzing on-device…"
        case .done: return "Added — searchable everywhere"
        case .failed(let message): return message
        }
    }
}
