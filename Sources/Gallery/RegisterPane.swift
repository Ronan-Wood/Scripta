import AppKit
import SwiftUI

/// The three registers, side by side and in one sentence. Rule 1 is the one rule you cannot check
/// from a token table — it only shows up when speech, chrome and machine fact sit on one line.
struct RegisterPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            RegistersInOneLine()
            FontResolutionCard()
            RoleSpecimens(title: "UI register — chrome", roles: RegisterCatalog.uiRoles)
            RoleSpecimens(title: "Prose register — human language", roles: RegisterCatalog.proseRoles)
            RoleSpecimens(title: "Mono register — machine-generated fact", roles: RegisterCatalog.monoRoles)
            LeadingCard()
        }
    }
}

enum RegisterCatalog {
    struct Role: Identifiable {
        let name: String
        let face: Typeface
        let sample: String
        var id: String { name }
    }

    static let uiRoles: [Role] = [
        Role(name: "micro", face: Register.micro, sample: "Recent calls"),
        Role(name: "caption", face: Register.caption, sample: "Shows every call from the last 30 days"),
        Role(name: "ui", face: Register.ui, sample: "Rebuild index"),
        Role(name: "uiEmphasis", face: Register.uiEmphasis, sample: "Rebuild index"),
        Role(name: "bodyUI", face: Register.bodyUI, sample: "No calls match this scope yet"),
        Role(name: "title3", face: Register.title3, sample: "Weekly review"),
        Role(name: "title2", face: Register.title2, sample: "Knowledge"),
        Role(name: "title1", face: Register.title1, sample: "Scripta"),
    ]

    static let proseRoles: [Role] = [
        Role(name: "proseSm", face: Register.proseSm,
             sample: "Spoken words fly away, written words remain — the distinction this system makes structural."),
        Role(name: "prose", face: Register.prose,
             sample: "Spoken words fly away, written words remain — the distinction this system makes structural."),
        Role(name: "proseLg", face: Register.proseLg,
             sample: "Spoken words fly away, written words remain."),
    ]

    static let monoRoles: [Role] = [
        Role(name: "monoMicro", face: Register.monoMicro, sample: "idx v41 · 00:14:07 · scope=prism"),
        Role(name: "mono", face: Register.mono, sample: "idx v41 · 00:14:07 · scope=prism"),
        Role(name: "numeral", face: Register.numeral, sample: "1 284"),
    ]

    static let all: [Role] = uiRoles + proseRoles + monoRoles
}

private struct RegistersInOneLine: View {
    var body: some View {
        Card(title: "Rule 1 — one line, three registers",
             note: "Speech is prose, chrome is UI, anything the machine measured is mono. The register is the tell.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                MixedSentence()
                RowRule()
                WrongMixedSentence()
            }
        }
    }
}

private struct MixedSentence: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            // Monochrome, not green. `Ink.success` sits in Ink's "State — deviation only"
            // block: under rule 3 the case that behaved is the silent one, and the label
            // beside it says "wrong" in `danger` because that IS the departure.
            Text("correct").microLabel(Ink.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: Gap.s6) {
                Text("Ronan").typeface(Register.uiEmphasis, Ink.speaker.me)
                Text("at").typeface(Register.caption, Ink.textHelper)
                Text("00:14:07").typeface(Register.mono, Ink.textSecondary)
                Text("— \"we should ship the gate first\"").proseText(Register.prose, Ink.textPrimary)
            }
        }
    }
}

private struct WrongMixedSentence: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("wrong — one register for everything").microLabel(Ink.danger)
            Text("Ronan at 00:14:07 — \"we should ship the gate first\"")
                .typeface(Register.bodyUI, Ink.textSecondary)
        }
    }
}

/// The gallery is a second bundle, so `Register.registerFonts()` runs at launch here too. If that
/// ever fails, every specimen below silently becomes San Francisco and the type review reviews the
/// wrong typeface — which is worth one row to rule out.
///
/// It iterates `Register.Face.all`, which is the list the roles are built from. A local copy is
/// what this check cannot have: a face added to `Register.Face` and missing from the copy is
/// precisely the unresolvable name the card exists to catch, and it would have been the one row
/// that never appeared.
private struct FontResolutionCard: View {
    var body: some View {
        Card(title: "Face resolution",
             note: "PostScript names resolved against the bundled TTFs. Any NO here invalidates the specimens below.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(Register.Face.all, id: \.self) { face in
                    FaceRow(face: face)
                }
            }
        }
    }
}

private struct FaceRow: View {
    let face: String

    private var resolved: Bool { NSFont(name: face, size: 12) != nil }

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(face).typeface(Register.mono, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            Text(resolved ? "YES" : "NO")
                .typeface(Register.monoMicro, resolved ? Ink.textSecondary : Ink.danger)
        }
        .frame(minHeight: Density.pill)
    }
}

private struct RoleSpecimens: View {
    let title: String
    let roles: [RegisterCatalog.Role]

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: Gap.s8) {
                ForEach(roles) { role in
                    RoleSpecimen(role: role)
                }
            }
        }
    }
}

private struct RoleSpecimen: View {
    let role: RegisterCatalog.Role

    private var detail: String {
        String(format: "%.0fpt · %@", role.face.size, role.face.face)
    }

    var body: some View {
        SpecimenRow(name: role.name, detail: detail) {
            Text(role.sample).proseText(role.face, Ink.textPrimary)
        }
    }
}

/// `Typeface.lineSpacing` is derived, not declared — it converts a line-height *multiple* into the
/// extra leading SwiftUI wants. Showing the derived number is the only way to check the conversion
/// without measuring pixels.
private struct LeadingCard: View {
    var body: some View {
        Card(title: "Derived leading",
             note: "lineSpacing = size × multiple − natural line box. Prose 1.55, UI 1.35.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(RegisterCatalog.all) { role in
                    LeadingRow(role: role)
                }
            }
        }
    }
}

private struct LeadingRow: View {
    let role: RegisterCatalog.Role

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(role.name).typeface(Register.mono, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            Text(String(format: "×%.2f → +%.2fpt", role.face.lineHeightMultiple, role.face.lineSpacing))
                .typeface(Register.monoMicro, Ink.textHelper)
        }
        .frame(minHeight: Density.pill)
    }
}
