import SwiftUI

struct GroupingControl: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Button(L10n.string(model.taskGroups.isEmpty ? "Generate Groups" : "Regenerate Groups")) {
            Task { await model.refreshTaskGroups() }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.isLoading || model.isGrouping)
        .help("Use OpenAI with downsampled window screenshots to infer task groups · Command-R")
        .overlay(alignment: .topLeading) {
            if !model.isGrouping,
               model.thumbnailStatus == nil,
               model.hasGeneratedGroups,
               let generatedAt = model.groupsGeneratedAt {
                HStack(spacing: 4) {
                    if model.groupsAreStale {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        Text("Groups may be outdated")
                        Text("·")
                    }
                    if Date().timeIntervalSince(generatedAt) < 60 {
                        Text("Generated just now")
                    } else {
                        Text("Generated \(generatedAt, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(y: 30)
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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("Search windows and Safari tabs", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(.trailing, model.query.isEmpty ? 0 : 24)
        }
        .overlay(alignment: .trailing) {
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .padding(.trailing, 7)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 5) {
                if model.isSmartSearching { ProgressView().controlSize(.mini) }
                Text(model.smartSearchStatus ?? L10n.string("Command-Return for Smart Search"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .offset(x: 7, y: 30)
        }
        .padding(.bottom, 14)
        .frame(minWidth: 180, idealWidth: 300, maxWidth: 380)
        .onChange(of: model.searchFocusRequest) {
            isFocused = true
        }
    }
}
