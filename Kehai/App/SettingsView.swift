import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @Bindable var shortcut: ShortcutSettings
    @Bindable var appearance: AppearanceSettings
    @Bindable var idleGrouping: IdleGroupingSettings
    @Bindable var excludedApps: ExcludedAppStore
    @Bindable var aiExcludedApps: AIExcludedAppStore
    @Bindable var permissionManager: PermissionManager
    @Bindable var openAIKeyStore: APIKeyStore
    @Bindable var anthropicKeyStore: APIKeyStore
    @Bindable var githubRepositoryStore: GitHubRepositoryStore
    @Bindable var githubRefreshSettings: GitHubRefreshSettings
    let safariService: SafariTabService
    let shortcutChanged: () -> Void
    let appearanceChanged: () -> Void
    let idleGroupingChanged: () -> Void
    let githubRefreshIntervalChanged: () -> Void
    let exclusionsChanged: () -> Void
    @State private var selectedProvider = AIProvider.current

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            appearanceSettings
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            aiSettings
                .tabItem { Label("AI", systemImage: "sparkles") }
            integrationsSettings
                .tabItem { Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted") }
            permissionsSettings
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            privacySettings
                .tabItem { Label("Exclusions", systemImage: "hand.raised") }
        }
        .frame(width: 620, height: 500)
        .onAppear { selectedProvider = AIProvider.current }
    }

    private var activeKeyStore: APIKeyStore {
        switch selectedProvider {
        case .openAI: openAIKeyStore
        case .anthropic: anthropicKeyStore
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Keyboard Shortcuts") {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show Mini Browser")
                        Text("Shows or dismisses Kehai from any app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    ShortcutRecorder(
                        keyCode: shortcut.keyCode,
                        modifiers: shortcut.modifiers
                    ) { keyCode, modifiers in
                        shortcut.update(keyCode: keyCode, modifiers: modifiers)
                        shortcutChanged()
                    }
                    .frame(width: 100, height: 28)
                    Button("Restore Default") {
                        shortcut.reset()
                        shortcutChanged()
                    }
                    .disabled(shortcut.isDefault)
                }

                Text("While Kehai is open, press the shortcut key again to move forward through apps. Release Shift and press the key to move backward; release the remaining modifiers to activate the selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let registrationError = shortcut.registrationError {
                    Label(registrationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Task Groups") {
                HStack {
                    Text("Regenerate automatically when idle")
                    Spacer(minLength: 20)
                    Toggle("", isOn: Binding(
                        get: { idleGrouping.isEnabled },
                        set: {
                            idleGrouping.isEnabled = $0
                            idleGroupingChanged()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                HStack {
                    Text("After")
                    Spacer(minLength: 20)
                    Picker("Idle delay", selection: Binding(
                        get: { idleGrouping.delayMinutes },
                        set: {
                            idleGrouping.delayMinutes = $0
                            idleGroupingChanged()
                        }
                    )) {
                        ForEach(IdleGroupingSettings.availableDelays, id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .disabled(!idleGrouping.isEnabled)
                Text("Runs once per idle period, and only when task groups are missing or the workspace has changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            Section("Browser Window") {
                Picker("Theme", selection: Binding(
                    get: { appearance.browserTheme },
                    set: {
                        appearance.browserTheme = $0
                        appearanceChanged()
                    }
                )) {
                    ForEach(BrowserTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose the system appearance or the Retrofit look from littlebobert.github.io.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appearance.browserTheme == .system {
                    Toggle("Use glassy background", isOn: Binding(
                        get: { appearance.usesGlassyWindow },
                        set: {
                            appearance.usesGlassyWindow = $0
                            appearanceChanged()
                        }
                    ))

                    Text("Adds translucent macOS material behind Kehai while keeping window cards readable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aiSettings: some View {
        Form {
            Section("Provider") {
                Picker("AI provider", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { _, provider in
                    AIProvider.current = provider
                }
                Text(L10n.format("Uses %@ for task groups and Smart Search.", selectedProvider.modelDisplayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(selectedProvider == .anthropic ? "Anthropic API Key" : "OpenAI API Key") {
                SecureField("API key", text: Binding(
                    get: { activeKeyStore.apiKey },
                    set: { activeKeyStore.apiKey = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { activeKeyStore.save() }
                HStack {
                    Text(L10n.string(activeKeyStore.hasUnsavedChanges
                        ? "Save your changes to the login Keychain."
                        : activeKeyStore.hasSavedKey
                            ? "Saved in your login Keychain."
                            : "Required to generate task groups and use Smart Search."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if activeKeyStore.hasSavedKey {
                        Button("Remove Key") {
                            activeKeyStore.apiKey = ""
                            activeKeyStore.save()
                        }
                    }
                    Button("Save Key") { activeKeyStore.save() }
                        .disabled(!activeKeyStore.canSave)
                }
                if let saveError = activeKeyStore.saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func refreshIntervalLabel(_ minutes: Int) -> String {
        minutes >= 60
            ? L10n.format(minutes == 60 ? "%lld hour" : "%lld hours", Int64(minutes / 60))
            : L10n.format("%lld minutes", Int64(minutes))
    }

    private var integrationsSettings: some View {
        Form {
            Section("GitHub Repository Search") {
                Text("Add fine-grained GitHub tokens to include selected repositories in Kehai search. Token requirements are listed below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Refresh repositories")
                    Spacer()
                    Picker("Refresh interval", selection: Binding(
                        get: { githubRefreshSettings.intervalMinutes },
                        set: { minutes in
                            githubRefreshSettings.intervalMinutes = minutes
                            githubRefreshIntervalChanged()
                        }
                    )) {
                        ForEach(GitHubRefreshSettings.availableIntervals, id: \.self) { minutes in
                            Text(refreshIntervalLabel(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Text("Also refreshes at launch, after adding a token, and when refreshed manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GitHubConnectionView(store: githubRepositoryStore)
            }
        }
        .formStyle(.grouped)
    }

    private var permissionsSettings: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Screen Recording",
                    granted: permissionManager.screenCaptureGranted,
                    attempted: permissionManager.screenCaptureAttempted,
                    enable: permissionManager.requestScreenCapture,
                    openSettings: permissionManager.openScreenCaptureSettings
                )
                permissionRow(
                    title: "Accessibility",
                    granted: permissionManager.accessibilityGranted,
                    attempted: permissionManager.accessibilityAttempted,
                    enable: permissionManager.requestAccessibility,
                    openSettings: permissionManager.openAccessibilitySettings
                )
                permissionRow(
                    title: "Safari tabs (optional)",
                    granted: permissionManager.safariAutomationStatus == "Granted",
                    attempted: permissionManager.safariAutomationStatus == "Needs permission",
                    requesting: permissionManager.safariAutomationStatus == "Requesting",
                    enable: { permissionManager.checkSafari(using: safariService) },
                    openSettings: permissionManager.openAutomationSettings
                )
                if let safariError = permissionManager.safariAutomationError {
                    Text(safariError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Permission changes may require restarting Kehai.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { permissionManager.refresh() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissionManager.refresh() }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        attempted: Bool,
        requesting: Bool = false,
        enable: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(L10n.string(title))
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if requesting {
                ProgressView().controlSize(.small)
            } else if attempted {
                Button("Open Settings", action: openSettings)
            } else {
                Button("Enable", action: enable)
            }
        }
    }

    private var privacySettings: some View {
        Form {
            Section("Excluded from Kehai") {
                Text("These apps do not appear in the browser and are never captured or sent to AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if excludedApps.apps.isEmpty {
                    Text("No apps excluded from Kehai.").foregroundStyle(.secondary)
                } else {
                    ForEach(excludedApps.apps) { app in
                        exclusionRow(app, buttonTitle: "Allow Again") {
                            excludedApps.allow(app)
                            exclusionsChanged()
                        }
                    }
                }
            }

            Section("Exclude from AI requests") {
                Text("These apps still appear in the browser, but their metadata, Safari tabs, thumbnails, and activity are never sent to your AI provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if aiExcludedApps.apps.isEmpty {
                    Text("No apps excluded from AI.").foregroundStyle(.secondary)
                } else {
                    ForEach(aiExcludedApps.apps) { app in
                        exclusionRow(app, buttonTitle: "Include in AI") {
                            aiExcludedApps.allow(app)
                            exclusionsChanged()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exclusionRow(_ app: ExcludedApp, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline)
                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string(buttonTitle), action: action)
        }
        .padding(.vertical, 2)
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
        title = L10n.string("Type Shortcut")
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
            UInt32(kVK_Space): L10n.string("Space"), UInt32(kVK_Return): L10n.string("Return"),
            UInt32(kVK_Tab): L10n.string("Tab"), UInt32(kVK_Delete): L10n.string("Delete"),
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→"
        ]
        if let name = names[keyCode] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return L10n.format("Key %lld", Int64(keyCode))
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
