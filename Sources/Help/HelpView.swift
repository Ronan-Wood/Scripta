import SwiftUI
import AppKit

/// Docs pane: how the app works and how to connect it to Claude. Carbon-styled to match the hub.
struct HelpView: View {
    @State private var mcpCopied = false
    @State private var skillStatus: String?

    private var mcpCommand: String {
        "claude mcp add calltranscriber -- \"\(Bundle.main.bundlePath)/Contents/MacOS/calltranscriber-mcp\""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                Text("Docs").font(CarbonFont.semibold(20)).foregroundStyle(Carbon.textPrimary)

                doc("Getting started", """
                Press Record on Home (or Start Recording in the menu bar) to capture a call. The first \
                time, macOS asks for Microphone and Screen Recording access — both are needed to capture \
                your side and the other participants. Grant them and record again.
                """)

                doc("Recording", """
                Everything runs locally: audio is transcribed on-device with Apple's Speech engine, your \
                mic and the system audio are transcribed separately for You/Them labels, then the raw \
                audio is deleted. When it finishes you can name the call and its participants.
                """)

                doc("Your calls", """
                Transcripts are Markdown files written to the folder you pick in Settings (point it at an \
                Obsidian vault to sync for free). Browse, search, and read them under Calls; ask questions \
                across them under Ask. Each note has a title, summary, topic tags, and timestamped text.
                """)

                claudeCard

                doc("Privacy", """
                On-device only: no login, no cloud, no servers. Raw audio and screenshots are deleted right \
                after processing — only text is kept. Nothing is ever sent anywhere.
                """)
            }
            .padding(Space.x7)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(Carbon.background)
    }

    private func doc(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            SectionHeader(title: title)
            Text(body).font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var claudeCard: some View {
        CarbonCard {
            VStack(alignment: .leading, spacing: Space.x4) {
                Text("Connect to Claude").font(CarbonFont.medium(16)).foregroundStyle(Carbon.textPrimary)
                Text("A built-in MCP server lets Claude (Code, Desktop, or Cowork) read, search, and reason over your calls. Move the app to Applications first — the command points to where the app currently sits.")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("1. Register the MCP server — paste this in your terminal:")
                    .font(CarbonFont.label(13)).foregroundStyle(Carbon.textPrimary)
                HStack(alignment: .top, spacing: Space.x3) {
                    Text(mcpCommand)
                        .font(CarbonFont.monospace(12)).foregroundStyle(Carbon.textPrimary)
                        .textSelection(.enabled)
                        .padding(Space.x3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Carbon.background, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
                    CarbonButton(title: mcpCopied ? "Copied" : "Copy", kind: .secondary) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpCommand, forType: .string)
                        mcpCopied = true
                    }
                }

                Text("2. Install the Claude skill (the playbook that teaches Claude how to use it):")
                    .font(CarbonFont.label(13)).foregroundStyle(Carbon.textPrimary)
                HStack(spacing: Space.x4) {
                    CarbonButton(title: "Install Claude skill", kind: .primary, action: installSkill)
                    if let skillStatus {
                        Text(skillStatus).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    }
                }
            }
        }
    }

    private func installSkill() {
        guard let source = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            skillStatus = "Skill file not found in app."
            return
        }
        let destDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/call-transcriber", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destFile = destDir.appendingPathComponent("SKILL.md")
            try? FileManager.default.removeItem(at: destFile)
            try FileManager.default.copyItem(at: source, to: destFile)
            skillStatus = "Installed to ~/.claude/skills"
        } catch {
            skillStatus = "Couldn't install: \(error.localizedDescription)"
        }
    }
}
