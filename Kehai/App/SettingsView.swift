import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @Bindable var shortcut: ShortcutSettings
    @Bindable var excludedApps: ExcludedAppStore
    let shortcutChanged: () -> Void
    let exclusionsChanged: () -> Void

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            privacySettings
                .tabItem { Label("Privacy & Exclusions", systemImage: "hand.raised") }
        }
        .frame(width: 580, height: 340)
    }

    private var generalSettings: some View {
        Form {
            Section("Overview") {
                LabeledContent("Keyboard shortcut") {
                    ShortcutRecorder(
                        keyCode: shortcut.keyCode,
                        modifiers: shortcut.modifiers
                    ) { keyCode, modifiers in
                        shortcut.update(keyCode: keyCode, modifiers: modifiers)
                        shortcutChanged()
                    }
                    .frame(width: 180, height: 28)
                }

                HStack {
                    Text("Shows or dismisses the Kehai overview from any app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") {
                        shortcut.reset()
                        shortcutChanged()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Excluded apps are never captured or included in AI grouping. Kehai observes only enough window metadata to apply these bundle-identifier rules.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if excludedApps.apps.isEmpty {
                ContentUnavailableView(
                    "No Excluded Apps",
                    systemImage: "hand.raised",
                    description: Text("Use the privacy button on a window card to exclude its entire app.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(excludedApps.apps) { app in
                    HStack(spacing: 12) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline)
                            Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Allow Again") {
                            excludedApps.allow(app)
                            exclusionsChanged()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let keyCode: UInt32
    let modifiers: UInt32
    let onChange: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = onChange
        view.update(keyCode: keyCode, modifiers: modifiers)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onChange = onChange
        view.update(keyCode: keyCode, modifiers: modifiers)
    }
}

private final class ShortcutRecorderView: NSButton {
    var onChange: ((UInt32, UInt32) -> Void)?
    private var recording = false
    private var displayedKeyCode: UInt32 = 0
    private var displayedModifiers: UInt32 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        focusRingType = .default
    }

    required init?(coder: NSCoder) { nil }

    func update(keyCode: UInt32, modifiers: UInt32) {
        guard !recording else { return }
        displayedKeyCode = keyCode
        displayedModifiers = modifiers
        title = shortcutTitle(keyCode: keyCode, modifiers: modifiers)
    }

    @objc private func beginRecording() {
        recording = true
        title = "Type Shortcut"
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            title = shortcutTitle(keyCode: displayedKeyCode, modifiers: displayedModifiers)
            return
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        recording = false
        displayedKeyCode = UInt32(event.keyCode)
        displayedModifiers = modifiers
        title = shortcutTitle(keyCode: displayedKeyCode, modifiers: displayedModifiers)
        onChange?(displayedKeyCode, displayedModifiers)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func shortcutTitle(keyCode: UInt32, modifiers: UInt32) -> String {
        var title = ""
        if modifiers & UInt32(controlKey) != 0 { title += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { title += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { title += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { title += "⌘" }
        title += keyName(for: keyCode)
        return title
    }

    private func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→"
        ]
        if let name = names[keyCode] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let layoutData = unsafeBitCast(data, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "Key \(keyCode)" }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return "Key \(keyCode)" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}
