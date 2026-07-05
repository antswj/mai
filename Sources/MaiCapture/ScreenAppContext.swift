import AppKit
import Foundation
import MaiCore

struct ScreenAppContext: Sendable, Equatable {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?

    var isEmpty: Bool {
        (appName ?? "").isEmpty && (bundleIdentifier ?? "").isEmpty && (windowTitle ?? "").isEmpty
    }

    var promptLine: String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append("active app: \(appName)") }
        if let bundleIdentifier, !bundleIdentifier.isEmpty { parts.append("bundle: \(bundleIdentifier)") }
        if let windowTitle, !windowTitle.isEmpty { parts.append("window: \(windowTitle)") }
        return parts.joined(separator: ", ")
    }

    static func current() -> ScreenAppContext {
        let app = NSWorkspace.shared.frontmostApplication
        if let app, CaptureSelfWindowMatcher.isSelf(ownerBundleIdentifier: app.bundleIdentifier,
                                                    ownerProcessID: app.processIdentifier,
                                                    currentBundleIdentifier: Bundle.main.bundleIdentifier,
                                                    currentProcessID: ProcessInfo.processInfo.processIdentifier),
           let fallback = topNonSelfWindowContext() {
            return fallback
        }
        let pid = app?.processIdentifier
        let title = pid.flatMap { frontWindowTitle(processID: $0) }
        return ScreenAppContext(
            appName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            windowTitle: title)
    }

    func event(content: String, subject: String?, at: Date = Date()) -> ScreenContentEvent {
        ScreenContentEvent(content: content, timestamp: at, isChange: true, subject: subject,
                           appName: appName, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
    }

    private static func topNonSelfWindowContext() -> ScreenAppContext? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleID = Bundle.main.bundleIdentifier
        for item in raw {
            guard (item[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            let running = NSRunningApplication(processIdentifier: pid)
            let bundle = running?.bundleIdentifier
            guard !CaptureSelfWindowMatcher.isSelf(ownerBundleIdentifier: bundle,
                                                   ownerProcessID: pid,
                                                   currentBundleIdentifier: currentBundleID,
                                                   currentProcessID: currentPID) else { continue }
            let title = (item[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ScreenAppContext(appName: running?.localizedName ?? (item[kCGWindowOwnerName as String] as? String),
                                    bundleIdentifier: bundle,
                                    windowTitle: title?.isEmpty == false ? title : nil)
        }
        return nil
    }

    private static func frontWindowTitle(processID: pid_t) -> String? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for item in raw {
            if let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber {
                guard pid_t(pidNumber.int32Value) == processID else { continue }
            } else {
                continue
            }
            guard (item[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let title = (item[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title?.isEmpty == false { return title }
        }
        return nil
    }
}
