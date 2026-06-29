import Foundation
import ServiceManagement

// Launch at login via SMAppService (macOS 13+; the modern replacement for the
// deprecated SMLoginItemSetEnabled). Works for a non-sandboxed Developer ID app with
// no helper plist; the first registration shows the system "login item added" note,
// and the user can also toggle it in System Settings, General, Login Items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func enable() throws {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
    }
    static func disable() throws {
        if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
    }
}
