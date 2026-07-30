import SwiftUI

/// Colored initials disc, Carbon-blue family.
struct InitialsBadge: View {
    let name: String
    var body: some View {
        Text(initials)
            .font(CarbonFont.medium(10))
            .foregroundStyle(Carbon.interactive)
            .frame(width: 24, height: 24)
            .background(Carbon.interactive.opacity(0.14), in: Circle())
    }
    private var initials: String {
        let words = name.components(separatedBy: " @ ").first?
            .components(separatedBy: CharacterSet(charactersIn: " ,")).filter { !$0.isEmpty } ?? []
        let letters = words.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}
