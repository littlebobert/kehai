import SwiftUI

struct GroupingControl: View {
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

struct HiddenWindowsControl: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Toggle("Exclude Hidden Windows", isOn: $model.excludeHiddenWindows)
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .help("Hide windows you have marked as hidden")
    }
}

struct SearchControl: View {
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
