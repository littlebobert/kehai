import SwiftUI

struct PermissionView: View {
    @Bindable var permissionManager: PermissionManager
    var safariService: SafariTabService?
    @Bindable var openAIKeyStore: OpenAIKeyStore
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Welcome to Kehai")
                    .font(.system(size: 26, weight: .semibold))
                Text("Kehai helps you return to interrupted work. Press Command+Option+K any time you forget where you were.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Required")
                    .font(.headline)
                permissionCard(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    detail: "Lets Kehai show thumbnails of each window.",
                    granted: permissionManager.screenCaptureGranted,
                    attempted: permissionManager.screenCaptureAttempted,
                    allow: permissionManager.requestScreenCapture,
                    settings: permissionManager.openScreenCaptureSettings
                )
                permissionCard(
                    icon: "cursorarrow.click.2",
                    title: "Accessibility",
                    detail: "Lets Kehai bring up windows.",
                    granted: permissionManager.accessibilityGranted,
                    attempted: permissionManager.accessibilityAttempted,
                    allow: permissionManager.requestAccessibility,
                    settings: permissionManager.openAccessibilitySettings
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OpenAI")
                    .font(.headline)
                SecureField("API key", text: $openAIKeyStore.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { openAIKeyStore.save() }
                HStack {
                    Text(openAIKeyStore.hasUnsavedChanges ? "Save this key to your login Keychain." : openAIKeyStore.hasKey ? "Saved in your login Keychain. Window metadata and downsampled screenshots are sent when you refresh groups." : "Required for AI task grouping. Stored in your login Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Key") { openAIKeyStore.save() }
                        .disabled(!openAIKeyStore.canSave)
                }
                if let saveError = openAIKeyStore.saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Optional")
                        .font(.headline)
                    Spacer()
                    if permissionManager.safariAutomationStatus == "Needs permission" {
                        Text("Not enabled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                permissionCard(
                    icon: "safari",
                    title: "Safari tabs",
                    detail: permissionManager.safariAutomationError ?? "Show, group and activate individual Safari tabs.",
                    granted: permissionManager.safariAutomationStatus == "Granted",
                    attempted: permissionManager.safariAutomationStatus == "Needs permission",
                    requesting: permissionManager.safariAutomationStatus == "Requesting",
                    allow: { if let safariService { permissionManager.checkSafari(using: safariService) } },
                    settings: permissionManager.openAutomationSettings
                )
            }

            HStack {
                if !permissionManager.hasCorePermissions {
                    Text("Enable both required permissions to proceed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Proceed") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissionManager.hasCorePermissions)
            }
        }
        .padding(22)
        .onAppear { permissionManager.refresh() }
    }

    private var readyLabel: some View {
        Label("Ready", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }

    private func permissionCard(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        attempted: Bool,
        requesting: Bool = false,
        allow: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 14)
            if granted {
                readyLabel
                    .fixedSize()
            } else if requesting {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()
            } else if attempted {
                Button("Open Settings", action: settings)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            } else {
                Button("Enable", action: allow)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
}
