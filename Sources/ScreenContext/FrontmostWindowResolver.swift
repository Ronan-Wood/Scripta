import AppKit
import ScreenCaptureKit

/// Resolves the frontmost app's frontmost on-screen window to an `SCWindow`. Re-evaluated
/// on every capture tick so it follows the user across app switches, rather than locking
/// onto whatever was frontmost when recording started.
enum FrontmostWindowResolver {

    static func currentWindow(in content: SCShareableContent) -> SCWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let targetPID = frontApp.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard targetPID != ownPID else { return nil }   // never capture ourselves

        // CGWindowList returns windows front-to-back in z-order.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == targetPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,  // normal windows only
                  let number = info[kCGWindowNumber as String] as? Int
            else { continue }

            if let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }) {
                return window
            }
        }
        return nil
    }
}
