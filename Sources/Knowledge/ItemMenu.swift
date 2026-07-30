import SwiftUI

/// The visible "•••" actions menu used on note cards and document rows (Open / Rename / Delete),
/// so those actions don't require right-clicking.
struct ItemMenu: View {
    let open: () -> Void
    let openLabel: String
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(openLabel, action: open)
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Carbon.iconSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}
