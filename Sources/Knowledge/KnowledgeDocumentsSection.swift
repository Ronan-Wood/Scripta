import SwiftUI
import ScriptaCore

/// Imported files, newest first — click opens the original.
struct KnowledgeDocumentsSection: View {
    let docs: [(mdURL: URL, title: String, created: String, file: String)]
    @Binding var openDoc: OpenDocTarget?
    @Binding var deleteTarget: KnowledgeView.ItemTarget?
    let onRename: (KnowledgeView.ItemTarget) -> Void
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
                    ForEach(docs.prefix(6), id: \.mdURL) { doc in
                        HStack(spacing: Space.x3) {
                            CarbonIcon(name: "document", size: 14, color: Carbon.iconSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.title).font(CarbonFont.medium(13))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                Text(doc.created).font(CarbonFont.label(11))
                                    .foregroundStyle(Carbon.textHelper)
                            }
                            Spacer()
                            ItemMenu(
                                open: {
                                    // verifiedOriginalURL, not a raw folder.appendingPathComponent
                                    // (crosscheck) — matches the other three resolution call sites
                                    // in this feature instead of hand-rolling a fourth, unverified one.
                                    if let url = DocumentImporter.verifiedOriginalURL(atPath: doc.mdURL.path, group: model.activeGroup) {
                                        NSWorkspace.shared.open(url)
                                    }
                                },
                                openLabel: "Open original",
                                onRename: { onRename(.doc(mdURL: doc.mdURL, title: doc.title)) },
                                onDelete: { deleteTarget = .doc(mdURL: doc.mdURL, title: doc.title) })
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
                            if let meta = DocumentImporter.parse(doc.mdURL), meta.group == model.activeGroup {
                                openDoc = OpenDocTarget(meta: meta, mdURL: doc.mdURL)
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
