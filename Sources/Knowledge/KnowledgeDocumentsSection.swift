import SubstrateKit
import SwiftUI
import ScriptaCore

/// One document in the workspace vault.
///
/// It briefly carried a second `.local` origin — the app's own `Files/` store — so the migration
/// off it could happen in steps without a document ever disappearing from view (Doc 4 Phase 4b).
/// That origin is gone with `DocumentImporter`: there is one ingest path now, and a document is
/// wherever the engine put it.
struct DocumentRow: Identifiable {
    let id: String
    let title: String
    let created: String
    let document: VaultDocument
}

/// Imported files, newest first — click opens the original.
struct KnowledgeDocumentsSection: View {
    let docs: [DocumentRow]
    @Binding var deleteTarget: KnowledgeView.ItemTarget?
    /// Show a document. Passed in rather than resolved here so this view keeps drawing rows and
    /// the screen that owns the sheet keeps owning it.
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
                            // DELETE ONLY. "Open original" is gone with the local store: a promoted
                            // document's origin is the path it was ingested FROM, which may not
                            // exist any more, and an action that silently does nothing is worse
                            // than an absent one. Rename is gone because the title is the engine's
                            // extraction, not the app's to redeclare.
                            Button {
                                deleteTarget = .vaultDoc(doc.document)
                            } label: {
                                CarbonIcon(name: "trash", size: 13, color: Carbon.iconSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from this workspace's vault")
                        }
                        .padding(Space.x4)
                        .background(Carbon.layer)
                        .contentShape(Rectangle())
                        .onTapGesture { openVaultDocument(doc.document) }
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
