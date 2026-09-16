import AppKit
import UserNotifications

/// Owns transcript-completion notifications and their "Reveal in Finder" action.
/// Set as the `UNUserNotificationCenter` delegate at launch.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let categoryID = "TRANSCRIPT_READY"
    private let revealActionID = "REVEAL_IN_FINDER"
    private let pathKey = "transcriptPath"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reveal = UNNotificationAction(identifier: revealActionID,
                                          title: "Reveal in Finder",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [reveal],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyTranscriptReady(url: URL) {
        post(title: "Transcript ready", body: url.deletingPathExtension().lastPathComponent, revealing: url)
    }

    /// Fired when an imported document finishes extracting + indexing. Tapping reveals the
    /// original file in Finder (same action machinery as transcripts).
    func notifyDocumentReady(title: String, revealing url: URL) {
        post(title: "Document added", body: title, revealing: url)
    }

    /// A recording start was refused because the app is about to quit to install an update. A
    /// banner, not an alert: a modal alert would block the main run loop and hold up the very quit it
    /// is explaining. No category and no path, so tapping it does nothing.
    func notifyRecordingRefusedForUpdate() {
        postPlain(title: "Recording didn't start",
                  body: "Scripta is restarting to install an update. Start recording again once it reopens.")
    }

    /// An update install was refused because a recording is in progress. Refusing aborts Sparkle's
    /// install, so without this its window would disappear with no reason given.
    func notifyUpdateNotInstalledDuringRecording() {
        postPlain(title: "Update not installed",
                  body: "A recording is in progress, so Scripta didn't restart. Choose Check for Updates… after the call.")
    }

    /// A banner with no category and no path, so tapping it does nothing.
    private func postPlain(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func post(title: String, body: String, revealing url: URL) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryID
        content.userInfo = [pathKey: url.path]
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Tapping the notification body or the action reveals the file.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo[pathKey] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    // Show the banner even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
