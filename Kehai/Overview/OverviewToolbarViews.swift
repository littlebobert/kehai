import AppKit
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
    let classicTheme: Bool
    let submit: () -> Void
    @AppStorage("permission.safariAutomationGranted") private var safariAutomationGranted = false
    @FocusState private var isFocused: Bool

    private var searchPrompt: String {
        if model.githubRepositoryStore.hasSavedTokens {
            return L10n.string(safariAutomationGranted
                ? "Search apps, windows, Safari tabs, and GitHub repos"
                : "Search apps, windows, and GitHub repos")
        }
        return L10n.string(safariAutomationGranted
            ? "Search windows, Safari tabs, and apps"
            : "Search windows and apps")
    }

    @ViewBuilder
    private var searchField: some View {
        if classicTheme {
            TextField(searchPrompt, text: $model.query)
                .textFieldStyle(.plain)
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background {
                    ZStack {
                        Rectangle().fill(.black).offset(x: 2, y: 2)
                        Rectangle().fill(.white)
                    }
                }
                .overlay {
                    Rectangle()
                        .strokeBorder(isFocused ? Color(red: 0.25, green: 0.35, blue: 0.65) : .black, lineWidth: 2)
                }
                .focused($isFocused)
                .onSubmit(submit)
        } else {
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
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: classicTheme ? 8 : 4) {
            searchField

            HStack(spacing: 5) {
                if model.isSmartSearching { ProgressView().controlSize(.mini) }
                Text(model.smartSearchStatus ?? L10n.string("Command-Return for Smart Search"))
            }
            .font(.caption2)
            .foregroundStyle(classicTheme ? Color.black : Color.secondary)
            .lineLimit(1)
            .padding(.leading, classicTheme ? 0 : 7)
            .padding(.horizontal, classicTheme ? 6 : 0)
            .padding(.vertical, classicTheme ? 2 : 0)
            .frame(height: classicTheme ? 20 : 16, alignment: .leading)
            .background {
                if classicTheme {
                    ZStack {
                        Rectangle().fill(.black).offset(x: 1, y: 1)
                        Rectangle().fill(Color(white: 0.90))
                    }
                }
            }
            .overlay {
                if classicTheme {
                    Rectangle().strokeBorder(.black, lineWidth: 1)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 450, maxWidth: 520)
        .onChange(of: model.searchFocusRequest) {
            isFocused = true
            DispatchQueue.main.async {
                model.applyPendingSearchText()
                DispatchQueue.main.async {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                }
            }
        }
        .onChange(of: model.searchBlurRequest) {
            isFocused = false
        }
    }
}
