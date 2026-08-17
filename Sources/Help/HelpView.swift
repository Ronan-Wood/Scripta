import SwiftUI
import AppKit

/// Docs — the render's documentation page: title + sectioned content with an "On this page"
/// rail, the functional Connect-Claude controls embedded in their section, acknowledgements
/// at the end. Copy is verbatim from Ronan's Scripta.dc.html.
struct HelpView: View {
    @State private var mcpCopied = false
    @State private var skillStatus: String?
    @State private var desktopStatus: String?
    @State private var activeSection = "getting-started"


    /// Register the ENGINE, not a bundled helper. Scripta shipped its own MCP server until
    /// 2026-08-07; Doc 4 §7 moved calls into vaults the engine composes, so the two were answering
    /// the same questions differently and the app's was deleted. The engine serves every scope,
    /// including this app's workspaces.
    /// The registration command, pointing at the engine THIS app resolved.
    ///
    /// IT USED TO HARDCODE `~/.local/bin/substrate-mcp`, which is the developer shim — a path that
    /// does not exist on a machine that merely installed Scripta. A user following this pane got a
    /// registered MCP server pointing at nothing, and Claude reported a spawn failure rather than
    /// anything that named the cause.
    ///
    /// Asked rather than assumed: `discover()` already resolves the bundled helper first, and the
    /// helper is a binary inside the bundle, so it is spawnable whether or not Scripta is running.
    /// Deriving it here means the command is right for whichever tier actually answered, and cannot
    /// drift from the ladder again.
    private var mcpCommand: String {
        let helper = SubstrateEngine.resolved?.executable.path
            ?? Bundle.main.resourceURL?
                .appendingPathComponent("substrate-engine/bin/substrate-mcp").path
            ?? "substrate-mcp"
        return "claude mcp add -s user substrate -- \"\(helper)\""
    }

    private struct TOCEntry: Identifiable {
        let id: String
        let title: String
        let indented: Bool
    }

    private let toc: [TOCEntry] = [
        .init(id: "getting-started", title: "Getting started", indented: false),
        .init(id: "install", title: "Install Scripta", indented: true),
        .init(id: "permissions", title: "Permissions", indented: true),
        .init(id: "first-recording", title: "Your first recording", indented: true),
        .init(id: "where-files-go", title: "Where your files go", indented: true),
        .init(id: "recording-calls", title: "Recording calls", indented: false),
        .init(id: "call-vs-conference", title: "Call vs. conference", indented: true),
        .init(id: "screen-context", title: "Screen context", indented: true),
        .init(id: "notes-hotkeys", title: "Notes & hotkeys", indented: true),
        .init(id: "organizing", title: "Organizing", indented: false),
        .init(id: "workspaces", title: "Workspaces", indented: true),
        .init(id: "documents", title: "Adding documents", indented: true),
        .init(id: "search-topics", title: "Search & topics", indented: true),
        .init(id: "asking", title: "Asking questions", indented: false),
        .init(id: "ask-basics", title: "Ask", indented: true),
        .init(id: "better-answers", title: "Better answers, optionally", indented: true),
        .init(id: "claude-mcp", title: "Claude & MCP", indented: false),
        .init(id: "connect-claude", title: "Connect Claude", indented: true),
        .init(id: "what-claude-can-do", title: "What Claude can do", indented: true),
        .init(id: "privacy", title: "Privacy", indented: false),
        .init(id: "on-device", title: "Everything on-device", indented: true),
        .init(id: "retention", title: "Retention", indented: true),
        .init(id: "troubleshooting", title: "If something looks wrong", indented: false),
        .init(id: "engine-trouble", title: "The engine", indented: true),
        .init(id: "results-trouble", title: "Missing or stale results", indented: true),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Scripta documentation")
                            .font(CarbonFont.semibold(26)).foregroundStyle(Carbon.textPrimary)
                            .padding(.bottom, Space.x3)
                        body14("Private, on-device transcription for your calls and meetings. Every transcript is plain Markdown you own — nothing leaves your Mac.")

                        h2("Getting started", id: "getting-started")
                        h3("Install Scripta", id: "install")
                        body14("Scripta runs on macOS 26 or later on Apple Silicon. Download the app, drag it to Applications, and grant microphone and screen-recording access on first launch. No account, no sign-in.")
                        h3("Permissions", id: "permissions")
                        body14("macOS asks for three, and each one is asked for at the moment it is first needed rather than up front:")
                        body14("Microphone — your side of a call. Without it, only the other participants are transcribed.")
                        body14("Screen Recording — required by macOS to capture system audio, which is how the other participants are recorded. Without it a call transcribes your voice only. It is also what Screen context uses; nothing is stored either way, and screenshots are discarded immediately after the text is read.")
                        body14("Calendar — optional. It shows upcoming meetings and pre-fills a call's name. Scripta never modifies your calendar and never starts recording on its own.")

                        h3("Your first recording", id: "first-recording")
                        body14("Press ⌥⌘R from any app, or click Start recording on the Home screen. Scripta captures your microphone and system audio as separate tracks and labels them You and Them. Recording is always a manual choice.")

                        h3("Where your files go", id: "where-files-go")
                        body14("Transcripts are Markdown, written to a folder you choose — Settings → Output folder. The default is Documents/Scripta. Point it at an Obsidian vault if you keep one; Scripta only ever touches files it created, identified by a marker inside each file and its filename shape.")

                        h2("Recording calls", id: "recording-calls")
                        h3("Call vs. conference", id: "call-vs-conference")
                        body14("Call mode records both sides and attributes each line to a speaker. Conference mode records a single source, unlabeled — use it for hybrid meetings where you are in the room and joined online, so speech is not transcribed twice.")
                        h3("Screen context", id: "screen-context")
                        body14("Scripta can periodically read text from your frontmost window and fold meaningfully-changed content into the transcript, timestamped. Screenshots are discarded immediately — only text is kept.")
                        h3("Notes & hotkeys", id: "notes-hotkeys")
                        body14("Add a timestamped note at any point with ⌥⌘N. Notes are anchored to the moment in the call and written into the Markdown alongside the transcript.")

                        h2("Organizing", id: "organizing")
                        h3("Workspaces", id: "workspaces")
                        body14("Calendars map to workspaces such as Deals or Personal. Search, Ask, and the MCP server are hard-scoped to the active workspace; cross-workspace search is an explicit, non-sticky action.")
                        h3("Search & topics", id: "search-topics")
                        body14("Search is holistic — one query matches spoken passages and call topics, so searching “baseball” finds a call that only ever said “home runs.” Topics are generated on-device and power concept browsing. Vocabulary terms you teach in the Library expand searches too: “TIM” also matches “tenants in the market.”")

                        h3("Adding documents", id: "documents")
                        body14("The Library takes PDFs, Word, PowerPoint, Excel, web pages, plain text, subtitles and email files, extracts them on-device, and files them into the active workspace so they answer alongside your calls. Nothing is uploaded. A document that cannot be read cleanly is refused with the reason rather than filed half-extracted.")

                        h2("Asking questions", id: "asking")
                        h3("Ask", id: "ask-basics")
                        body14("Ask answers from your own material and cites what it used. Answers are scoped to the active workspace, and each one records what the engine actually did — which parts of the retrieval stack ran, and how well that combination is known to perform. When something was unavailable it says so instead of quietly returning a weaker answer.")
                        h3("Better answers, optionally", id: "better-answers")
                        body14("Everything works with nothing installed, using Apple's on-device models. If you run a local model server such as Ollama, Scripta will use it and answers to paraphrased questions get noticeably better — the difference is largest when your words do not match the words in the note. It stays entirely on your machine either way: loopback or LAN only, and public hosts are refused with no override.")

                        h2("Claude & MCP", id: "claude-mcp")
                        h3("Connect Claude", id: "connect-claude")
                        connectClaude
                        h3("What Claude can do", id: "what-claude-can-do")
                        body14("Through the MCP, Claude can list and read transcripts, search across your history, and retrieve ranked passages with call, timestamp, and speaker provenance — all scoped to the active workspace and refused on a stale heartbeat.")

                        h2("Privacy", id: "privacy")
                        h3("Everything on-device", id: "on-device")
                        body14("Transcription, enrichment, and Ask all run locally with Apple’s models. Raw audio and screenshots are always ephemeral; only text is kept. An optional local model endpoint is loopback or LAN only — public hosts are refused with no override.")
                        h3("Retention", id: "retention")
                        body14("Optional auto-delete removes only transcripts Scripta created, identified by a marker inside each file and its filename shape — never other files in your folder, even inside an Obsidian vault.")

                        h2("If something looks wrong", id: "troubleshooting")
                        h3("The engine", id: "engine-trouble")
                        body14("Scripta runs its own search engine as a background process and shows its state in Settings. It starts with the app and stops with it — if a card says it could not start, it carries the reason and a Restart control. Nothing is left running after you quit.")
                        h3("Missing or stale results", id: "results-trouble")
                        body14("Your index updates while Scripta is open — after a recording, after adding a document, and periodically. Notes you edit elsewhere while Scripta is closed are picked up the next time it runs, so a long gap can mean a search reflects last week's material.")
                        body14("If an answer seems to be missing a call, check whether calls are included: in Ask they are, but through Claude they are withheld by default and Claude has to ask for them explicitly. The reply always states what was left out.")

                        acknowledgements
                    }
                    .padding(.horizontal, Space.x8)
                    .padding(.vertical, Space.x7)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: activeSection) { _, id in
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
            }

            Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
            tocRail
        }
        .background(Carbon.background)
    }

    // MARK: - Content helpers

    private func h2(_ title: String, id: String) -> some View {
        Text(title).font(CarbonFont.semibold(19)).foregroundStyle(Carbon.textPrimary)
            .padding(.top, Space.x7).padding(.bottom, Space.x3)
            .id(id)
    }

    private func h3(_ title: String, id: String) -> some View {
        Text(title).font(CarbonFont.semibold(15)).foregroundStyle(Carbon.textPrimary)
            .padding(.top, Space.x5).padding(.bottom, Space.x2)
            .id(id)
    }

    private func body14(_ text: String) -> some View {
        Text(text).font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - "On this page" rail

    private var tocRail: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(spacing: Space.x3) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Carbon.iconSecondary)
                Text("On this page").font(CarbonFont.semibold(13)).foregroundStyle(Carbon.textPrimary)
            }
            .padding(.bottom, Space.x2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(toc) { entry in
                    Button {
                        activeSection = entry.id
                    } label: {
                        Text(entry.title)
                            .font(activeSection == entry.id ? CarbonFont.medium(12.5) : CarbonFont.body(12.5))
                            .foregroundStyle(activeSection == entry.id ? Carbon.interactive
                                             : entry.indented ? Carbon.textSecondary : Carbon.textPrimary)
                            .padding(.leading, entry.indented ? Space.x4 : 0)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, Space.x3)
            .overlay(alignment: .leading) { Rectangle().fill(Carbon.borderSubtle).frame(width: 2) }
            Spacer()
        }
        .padding(Space.x6)
        .frame(width: 240, alignment: .leading)
    }

    // MARK: - Connect Claude (the functional block, embedded in its docs section)

    @ViewBuilder private var connectClaude: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            body14("Your calls live in a vault the substrate engine composes, so Claude reads them through the engine — the same server that answers for every other vault you keep. Register it once:")
            body14("While Scripta is closed, this workspace's own calls are withheld and the engine says so; everything the workspace inherits keeps answering. Opening Scripta and selecting the workspace is what vouches for it.")

            HStack(alignment: .top, spacing: Space.x3) {
                Text(mcpCommand)
                    .font(CarbonFont.monospace(12)).foregroundStyle(Carbon.textPrimary)
                    .textSelection(.enabled)
                    .padding(Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
                CarbonButton(title: mcpCopied ? "Copied" : "Copy", kind: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpCommand, forType: .string)
                    mcpCopied = true
                }
            }

            HStack(spacing: Space.x4) {
                CarbonButton(title: "Add to Claude Desktop", kind: .primary, action: addToClaudeDesktop)
                if let desktopStatus {
                    Text(desktopStatus).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                }
            }
            body14("Covers Claude Desktop and Cowork — you'll pick Claude's settings folder once, then quit Claude Desktop (⌘Q) and reopen it.")

            HStack(spacing: Space.x4) {
                CarbonButton(title: "Install Claude skill", kind: .secondary, action: installSkill)
                if let skillStatus {
                    Text(skillStatus).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                }
            }
            body14("The skill (Claude Code only) teaches Claude the playbooks — “summarize my week”, “action items across calls”. You'll pick your .claude folder once. Claude can read your calls only while Scripta is running, and only the active workspace.")
        }
        .padding(.vertical, Space.x2)
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            h2("Acknowledgements", id: "acknowledgements")
            body14("Typefaces: IBM Plex Sans and IBM Plex Mono © IBM Corp., under the SIL Open Font License 1.1. Icons: IBM Carbon, under the Apache License 2.0. Both license texts are included in the app bundle (Contents/Resources).")
        }
    }

    // MARK: - Actions (unchanged mechanics)

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
            // The ENGINE, under its own name. Writing `scripta` here would register a helper this
            // app no longer ships, and Claude Desktop would fail to spawn it every launch.
            servers["substrate"] = ["command": "\(NSHomeDirectory())/.local/bin/substrate-mcp"]
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
            let destDir = dotClaude.appendingPathComponent("skills/scripta", isDirectory: true)
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
