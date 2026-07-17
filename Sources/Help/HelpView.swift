import SwiftUI
import AppKit

/// Docs pane: how the app works and how to connect it to Claude. Carbon-styled to match the hub.
struct HelpView: View {
    @State private var mcpCopied = false
    @State private var skillStatus: String?
    @State private var desktopStatus: String?

    private var mcpBinaryPath: String {
        "\(Bundle.main.bundlePath)/Contents/MacOS/calltranscriber-mcp"
    }

    private var mcpCommand: String {
        "claude mcp add -s user calltranscriber -- \"\(mcpBinaryPath)\""
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
                Text("A built-in server lets Claude read, search, and reason over your calls. Move the app to Applications first — both setups point to where the app currently sits, so they break if it moves later.")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Claude Desktop and Cowork").font(CarbonFont.label(13)).foregroundStyle(Carbon.textPrimary)
                HStack(spacing: Space.x4) {
                    CarbonButton(title: "Add to Claude Desktop", kind: .primary, action: addToClaudeDesktop)
                    if let desktopStatus {
                        Text(desktopStatus).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    }
                }
                Text("You'll pick Claude's settings folder once to allow the change. Then quit Claude Desktop (⌘Q) and reopen it.")
                    .font(CarbonFont.body(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Claude Code (terminal)").font(CarbonFont.label(13)).foregroundStyle(Carbon.textPrimary)
                Text("Paste this once — it registers the server for every project:")
                    .font(CarbonFont.body(12)).foregroundStyle(Carbon.textSecondary)
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
                HStack(spacing: Space.x4) {
                    CarbonButton(title: "Install Claude skill", kind: .secondary, action: installSkill)
                    if let skillStatus {
                        Text(skillStatus).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    }
                }
                Text("The skill (Claude Code only) teaches Claude the playbooks — \"summarize my week\", \"action items across calls\". You'll pick your .claude folder once.")
                    .font(CarbonFont.body(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Good to know: Claude can read your calls only while this app is running, and only the workspace you're in — switch workspaces (or use Search All) in the sidebar.")
                    .font(CarbonFont.body(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Registers the MCP server in Claude Desktop's config (also covers Cowork). The config
    /// lives in the real ~/Library — outside our sandbox — so a one-time folder grant is
    /// needed; the existing file is backed up, then merged, never replaced.
    private func addToClaudeDesktop() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Select Claude's settings folder so the app can register itself."
        panel.directoryURL = realHome.appendingPathComponent("Library/Application Support/Claude",
                                                             isDirectory: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let configURL = dir.appendingPathComponent("claude_desktop_config.json")
        do {
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: configURL) {
                guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    desktopStatus = "That folder has a config file the app can't read safely."
                    return
                }
                try? FileManager.default.removeItem(at: configURL.appendingPathExtension("bak"))
                try? FileManager.default.copyItem(at: configURL, to: configURL.appendingPathExtension("bak"))
                root = existing
            }
            var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
            servers["calltranscriber"] = ["command": mcpBinaryPath]
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
            desktopStatus = "Added. Quit Claude Desktop (⌘Q) and reopen it."
        } catch {
            desktopStatus = "Couldn't update the config: \(error.localizedDescription)"
        }
    }

    private func installSkill() {
        guard let source = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            skillStatus = "Skill file not found in app."
            return
        }
        // Sandboxed, the app can't write into ~/.claude on its own — a one-time folder pick
        // grants it. The panel opens at the REAL home's .claude (homeDirectoryForCurrentUser
        // points inside the app container under the sandbox).
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Install"
        panel.message = "Select your .claude folder to install the skill into (usually hidden in your home folder)."
        panel.directoryURL = realHome.appendingPathComponent(".claude", isDirectory: true)
        guard panel.runModal() == .OK, let dotClaude = panel.url else { return }
        do {
            let destDir = dotClaude.appendingPathComponent("skills/call-transcriber", isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destFile = destDir.appendingPathComponent("SKILL.md")
            try? FileManager.default.removeItem(at: destFile)
            try FileManager.default.copyItem(at: source, to: destFile)
            skillStatus = "Installed to \(destDir.path.replacingOccurrences(of: realHome.path, with: "~"))"
        } catch {
            skillStatus = "Couldn't install: \(error.localizedDescription)"
        }
    }

    /// The user's actual home directory — under the sandbox, `homeDirectoryForCurrentUser`
    /// resolves inside the app container instead.
    private var realHome: URL {
        if let pw = getpwuid(getuid()), pw.pointee.pw_dir != nil {
            return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
