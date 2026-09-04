import AppKit
import Foundation

// Opening a thread from the popover means handing its id back to the app that owns
// it. Each provider exposes a different door, and one has none at all:
//
//   Claude  — claude://resume?session=<uuid> hands the session to Claude Code in the
//             desktop app (its handler calls importCliSession), reading the same
//             ~/.claude/projects/<project>/<uuid>.jsonl the popover listed. The route
//             validates the id as a bare UUID, which is exactly the file's name.
//             Desktop-native sessions are named local_<…> instead and go through
//             claude://code/continue?session=<id>, the only route that accepts them.
//   Codex   — codex://threads/<id> opens the thread by the same id the ChatGPT app
//             stores in ~/.codex/state_5.sqlite.
//   Antigravity — no per-conversation URL route exists in the shipping app, so the
//             best available action is to bring the IDE forward and let the user
//             pick the conversation from its own list.
enum ThreadOpener {
    enum Provider {
        case claude
        case codex
        case antigravity
    }

    /// Whether clicking a row can do anything more than nothing. Antigravity still
    /// counts — activating the app is a weaker jump, but it is a jump.
    static func canOpen(_ provider: Provider) -> Bool {
        switch provider {
        case .claude, .codex:
            return true
        case .antigravity:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: antigravityBundleID) != nil
        }
    }

    static func open(_ provider: Provider, threadID: String) {
        switch provider {
        case .claude:
            if isUUID(threadID) {
                openURL("claude://resume?session=\(threadID)")
            } else if isDesktopSessionID(threadID) {
                openURL("claude://code/continue?session=\(threadID)")
            } else {
                // Neither route would accept this id (a sub-agent rollout, say), so
                // bring Claude forward rather than firing a URL it will refuse.
                activate(bundleID: claudeBundleID)
            }
        case .codex:
            guard let encoded = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { return }
            openURL("codex://threads/\(encoded)")
        case .antigravity:
            activate(bundleID: antigravityBundleID)
        }
    }

    // MARK: - Helpers

    private static let antigravityBundleID = "com.google.antigravity"
    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    private static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Sessions the desktop app created itself, which the resume route rejects —
    /// `claude://code/continue` is the one that takes them.
    private static func isDesktopSessionID(_ string: String) -> Bool {
        guard string.hasPrefix("local_"), string.count <= 70 else { return false }
        return string.dropFirst(6).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            && string.count > 6
    }

    private static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func isUUID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }
}
