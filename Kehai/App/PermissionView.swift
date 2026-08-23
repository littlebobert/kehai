import SwiftUI

struct PermissionView: View {
    @Bindable var permissionManager: PermissionManager
    var safariService: SafariTabService?
    @Bindable var openAIKeyStore: APIKeyStore
    @Bindable var anthropicKeyStore: APIKeyStore
    @Bindable var githubRepositoryStore: GitHubRepositoryStore
    var close: () -> Void

    @State private var step: SetupStep = .systemAccess
    @State private var selectedProvider = AIProvider.current

    private enum SetupStep: Int {
        case systemAccess = 1
        case integrations = 2
    }

    private var activeKeyStore: APIKeyStore {
        switch selectedProvider {
        case .openAI: openAIKeyStore
        case .anthropic: anthropicKeyStore
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Group {
                switch step {
                case .systemAccess:
                    systemAccessStep
                case .integrations:
                    integrationsStep
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(24)
        .onAppear {
            permissionManager.refresh()
            selectedProvider = AIProvider.current
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: step == .systemAccess ? "lock.shield" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.tint)
                Spacer()
                Text("Step \(step.rawValue) of 2")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(step == .systemAccess ? "Allow System Access" : "Connect Integrations")
                .font(.system(size: 26, weight: .semibold))
            Text(step == .systemAccess
                 ? "Kehai needs these permissions to show and restore your windows."
                 : "Optional integrations add AI grouping, Safari tabs, and GitHub repository search.")
                .foregroundStyle(.secondary)
        }
    }

    private var systemAccessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                detail: "Lets Kehai bring windows to the front.",
                granted: permissionManager.accessibilityGranted,
                attempted: permissionManager.accessibilityAttempted,
                allow: permissionManager.requestAccessibility,
                settings: permissionManager.openAccessibilitySettings
            )
            if !permissionManager.hasCorePermissions {
                Label("Enable both permissions to continue.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var integrationsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                integrationSection(title: "AI Provider", subtitle: "Optional · Groups related windows and powers Smart Search") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $selectedProvider) {
                            ForEach(AIProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: selectedProvider) { _, provider in
                            AIProvider.current = provider
                        }

                        SecureField("API key", text: Binding(
                            get: { activeKeyStore.apiKey },
                            set: { activeKeyStore.apiKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { activeKeyStore.save() }

                        HStack {
                            Text(activeKeyStore.hasSavedKey ? "Saved securely in your login Keychain." : "Stored securely in your login Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Save Key") { activeKeyStore.save() }
                                .disabled(!activeKeyStore.canSave)
                        }
                        if let saveError = activeKeyStore.saveError {
                            Text(saveError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                integrationSection(title: "GitHub", subtitle: "Optional · Search repositories from Kehai") {
                    GitHubConnectionView(store: githubRepositoryStore)
                }

                integrationSection(title: "Safari Tabs", subtitle: "Optional · Show and activate individual tabs") {
                    HStack {
                        Text(permissionManager.safariAutomationError ?? permissionManager.safariAutomationStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        if permissionManager.safariAutomationStatus == "Granted" {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if permissionManager.safariAutomationStatus == "Requesting" {
                            ProgressView().controlSize(.small)
                        } else if permissionManager.safariAutomationStatus == "Needs permission" {
                            Button("Open Settings", action: permissionManager.openAutomationSettings)
                        } else {
                            Button("Enable") {
                                if let safariService {
                                    permissionManager.checkSafari(using: safariService)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step == .integrations {
                Button("Back") { step = .systemAccess }
                Spacer()
                Button("Skip") { close() }
                Button("Start Using Kehai") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Next") { step = .integrations }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissionManager.hasCorePermissions)
            }
        }
    }

    private func integrationSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
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
                Text(L10n.string(title)).font(.headline)
                Text(L10n.string(detail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                readyLabel.fixedSize()
            } else if requesting {
                ProgressView().controlSize(.small).fixedSize()
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
        .padding(14)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct GitHubConnectionView: View {
    @Bindable var store: GitHubRepositoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.connections.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.connections) { connection in
                        GitHubConnectionRow(store: store, connection: connection)
                        if connection.id != store.connections.last?.id { Divider() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(store.connections.isEmpty ? "Connect GitHub" : "Add another token")
                    .font(.callout.weight(.medium))
                SecureField("Personal access token", text: $store.newToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addConnection() }
                HStack {
                    Text("Fine-grained tokens are limited to one resource owner. Add one token for each personal or organization account you want to search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(store.connections.isEmpty ? "Connect" : "Add Token") {
                        addConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoading)
                }
            }

            if store.isAddingConnection {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Validating token and loading repositories…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let errorMessage = store.errorMessage,
                      store.connections.isEmpty || store.connections.allSatisfy({ $0.errorMessage == nil }) {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else {
                Text("Tokens are stored separately in your login Keychain and used only with GitHub’s API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addConnection() {
        guard !store.newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await store.addConnection() }
    }
}

private struct GitHubConnectionRow: View {
    @Bindable var store: GitHubRepositoryStore
    @Bindable var connection: GitHubRepositoryConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if connection.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.username.map { "@\($0)" } ?? "Saved GitHub token")
                        .font(.callout.weight(.medium))
                    Text("\(connection.repositories.count) repositories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await store.refresh(connection) }
                }
                .disabled(connection.isLoading || store.isAddingConnection)
                Button("Remove", role: .destructive) {
                    store.removeConnection(connection)
                }
                .disabled(connection.isLoading || store.isAddingConnection)
            }
            if let errorMessage = connection.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else if let lastRefreshedAt = connection.lastRefreshedAt {
                Text("Refreshed \(lastRefreshedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
