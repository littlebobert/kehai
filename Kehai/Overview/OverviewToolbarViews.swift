import SwiftUI

struct GroupingToolbarView: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Button(model.taskGroups.isEmpty ? "Generate Groups" : "Regenerate Groups") {
            Task { await model.refreshTaskGroups() }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.isLoading || model.isGrouping)
        .help("Use OpenAI with downsampled window screenshots to infer task groups")
    }
}

struct HiddenWindowsToolbarView: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Button {
            model.excludeHiddenWindows.toggle()
        } label: {
            Image(systemName: model.excludeHiddenWindows ? "eye.slash" : "eye")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(model.excludeHiddenWindows ? .accentColor : nil)
        .help(model.excludeHiddenWindows ? "Hidden windows are excluded" : "Hidden windows are included")
        .accessibilityLabel("Exclude Hidden Windows")
        .accessibilityValue(model.excludeHiddenWindows ? "On" : "Off")
    }
}

struct SearchToolbarView: View {
    @Bindable var model: OverviewViewModel
    let submit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Search windows and Safari tabs", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit(submit)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .frame(minWidth: 180, idealWidth: 300, maxWidth: 380)
            .onChange(of: model.searchFocusRequest) {
                isFocused = true
            }
    }
}
