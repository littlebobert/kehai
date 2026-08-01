import SwiftUI

struct GroupingControl: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.viewMode == .grouped {
                Button(L10n.string(model.taskGroups.isEmpty ? "Generate Groups" : "Regenerate Groups")) {
                    Task { await model.refreshAndRegenerateGroups() }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isLoading || model.isGrouping)
                .help("Use AI with downsampled window screenshots to infer task groups · Command-R")
                .frame(height: 24, alignment: .topLeading)
            }

            if model.thumbnailStatus != nil || model.viewMode == .grouped {
                HStack(spacing: 4) {
                    if let thumbnailStatus = model.thumbnailStatus {
                        ProgressView().controlSize(.mini)
                        Text(thumbnailStatus)
                            .contentTransition(.numericText())
                    } else if let groupingStatus = model.groupingStatus {
                        ProgressView().controlSize(.mini)
                        Text(groupingStatus)
                            .contentTransition(.numericText())
                    } else if model.hasGeneratedGroups,
                              let generatedAt = model.groupsGeneratedAt {
                        if Date().timeIntervalSince(generatedAt) < 60 {
                            Text("Generated just now")
                        } else {
                            Text("Generated \(generatedAt, format: .relative(presentation: .named))")
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 7)
                .frame(height: 16, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct ViewModeControl: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Toggle("Group by task", isOn: Binding(
            get: { model.viewMode == .grouped },
            set: { model.setViewMode($0 ? .grouped : .recent) }
        ))
        .toggleStyle(.checkbox)
        .controlSize(.regular)
        .padding(.top, 3)
        .help("Group by task: Command-1 · Sort all by recent: Command-2")
    }
}

struct HiddenWindowsControl: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Toggle("Exclude hidden windows", isOn: $model.excludeHiddenWindows)
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .padding(.top, 3)
            .help("Hide windows you have marked as hidden")
    }
}

struct SearchControl: View {
    @Bindable var model: OverviewViewModel
    let submit: () -> Void
    @AppStorage("permission.safariAutomationGranted") private var safariAutomationGranted = false
    @FocusState private var isFocused: Bool

    private var searchPrompt: String {
        L10n.string(safariAutomationGranted
            ? "Search windows, Safari tabs, and apps"
            : "Search windows and apps")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(searchPrompt, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .frame(height: 24, alignment: .topLeading)

            HStack(spacing: 5) {
                if model.isSmartSearching { ProgressView().controlSize(.mini) }
                Text(model.smartSearchStatus ?? L10n.string("Command-Return for Smart Search"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 7)
            .frame(height: 16, alignment: .leading)
        }
        .frame(minWidth: 180, idealWidth: 300, maxWidth: 380)
        .onChange(of: model.searchFocusRequest) {
            isFocused = true
        }
    }
}
