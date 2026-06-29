import AppKit
import Carbon.HIToolbox
import SwiftUI

// The configurable global summon hotkey, on Carbon RegisterEventHotKey directly: it
// is process-global, needs no Accessibility permission and no entitlement, and works
// in a menu bar agent with no window. (This is the same mechanism the KeyboardShortcuts
// package wraps; that package is avoided because its SwiftUI macros need full Xcode.)
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onFire: (() -> Void)?

    func register(keyCode: UInt32, carbonModifiers: UInt32) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onFire?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4D414948), id: 1)   // 'MAIH'
        RegisterEventHotKey(keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

// Persists the chosen shortcut and (re)registers it. Default: none (a public app
// should not claim a shortcut without the user choosing one).
enum HotKeyStore {
    private static let keyCodeKey = "mai.hotkey.keyCode"
    private static let modsKey = "mai.hotkey.modifiers"     // NSEvent.ModifierFlags rawValue
    private static let displayKey = "mai.hotkey.display"

    static var display: String { UserDefaults.standard.string(forKey: displayKey) ?? "Not set" }
    static var isSet: Bool { UserDefaults.standard.object(forKey: keyCodeKey) != nil }

    static func save(keyCode: UInt16, flags: NSEvent.ModifierFlags, display: String) {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: keyCodeKey)
        d.set(Int(flags.rawValue), forKey: modsKey)
        d.set(display, forKey: displayKey)
    }
    static func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: keyCodeKey); d.removeObject(forKey: modsKey); d.removeObject(forKey: displayKey)
    }

    @MainActor static func apply() {
        let d = UserDefaults.standard
        guard d.object(forKey: keyCodeKey) != nil else { GlobalHotKey.shared.unregister(); return }
        let keyCode = UInt32(d.integer(forKey: keyCodeKey))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: modsKey)))
        GlobalHotKey.shared.register(keyCode: keyCode, carbonModifiers: GlobalHotKey.carbonModifiers(from: flags))
    }
}

// A small recorder: click to capture the next key combo (must include a modifier),
// or clear it. Captures via a local key monitor; no Accessibility permission needed
// for that since the field is in our own (key) window while recording.
struct HotkeyRecorder: View {
    @State private var recording = false
    @State private var display = HotKeyStore.display
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(display).foregroundStyle(recording ? .secondary : .primary)
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Button(recording ? "Press keys\u{2026}" : "Record") { recording ? stop() : start() }
            Button("Clear") { HotKeyStore.clear(); GlobalHotKey.shared.unregister(); display = "Not set" }
                .disabled(!HotKeyStore.isSet && !recording)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return event }   // require a modifier to avoid stealing plain keys
            let glyphs = Self.glyphs(mods) + (event.charactersIgnoringModifiers?.uppercased() ?? "")
            HotKeyStore.save(keyCode: event.keyCode, flags: mods, display: glyphs)
            display = glyphs
            HotKeyStore.apply()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    static func glyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "\u{2303}" }
        if flags.contains(.option) { s += "\u{2325}" }
        if flags.contains(.shift) { s += "\u{21E7}" }
        if flags.contains(.command) { s += "\u{2318}" }
        return s
    }
}
