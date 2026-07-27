import AppKit
import SwiftUI

struct OverviewView: View {
    @Bindable var model: OverviewViewModel
    let close: () -> Void
    @State private var appPendingExclusion: WindowItem?
    @State private var gridWidth: CGFloat = 0

    private let gridSpacing: CGFloat = 18
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: model.thumbnailCardWidth, maximum: model.thumbnailCardWidth + 80), spacing: gridSpacing)] }
    private var gridColumnCount: Int { max(1, Int((gridWidth + gridSpacing) / (model.thumbnailCardWidth + gridSpacing))) }
    private var thumbnailHeight: CGFloat { model.thumbnailCardWidth * 0.64 }
    private let categoryBarHeight: CGFloat = 36

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                statusRow
                categoryBar
                    .frame(minHeight: categoryBarHeight)

                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                if model.isLoading {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView().controlSize(.large)
                        Text("Loading window thumbnails…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                windowSection(nil, windows: model.filteredWindows.filter { !$0.isDusty })
                                if model.filteredWindows.contains(where: \.isDusty) {
                                    windowSection("Dusty", windows: model.filteredWindows.filter(\.isDusty), dusty: true)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .padding(.bottom, 30)
                            .animation(.easeInOut(duration: 0.14), value: model.selectedTaskGroupID)
                        }
                        .contentMargins(.trailing, 14, for: .scrollContent)
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { updateGridWidth(proxy.size.width) }
                                    .onChange(of: proxy.size.width) { _, width in updateGridWidth(width) }
                            }
                        }
                        .onChange(of: model.selectedWindowID) { _, selectedWindowID in
                            guard let selectedWindowID else { return }
                            withAnimation(.easeOut(duration: 0.16)) {
                                scrollProxy.scrollTo(selectedWindowID, anchor: .center)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task { await model.refresh() }
        .onChange(of: model.thumbnailCardWidth) {
            model.keyboardColumnCount = gridColumnCount
        }
        .animation(.easeInOut(duration: 0.16), value: model.thumbnailCardWidth)
        .alert("Never capture \(appPendingExclusion?.appName ?? "this app")?", isPresented: Binding(
            get: { appPendingExclusion != nil },
            set: { if !$0 { appPendingExclusion = nil } }
        ), presenting: appPendingExclusion) { window in
            Button("Cancel", role: .cancel) { appPendingExclusion = nil }
            Button("Exclude App", role: .destructive) {
                model.excludeApp(for: window)
                appPendingExclusion = nil
            }
        } message: { window in
            Text("All current and future \(window.appName) windows will be removed from Kehai. Kehai won’t capture their thumbnails or include them in AI grouping. You can allow the app again in Settings.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            if model.isGrouping {
                ProgressView().controlSize(.small)
                if let groupingStatus = model.groupingStatus {
                    Text(groupingStatus)
                        .contentTransition(.numericText())
                }
            } else if let thumbnailStatus = model.thumbnailStatus {
                ProgressView().controlSize(.small)
                Text(thumbnailStatus)
                    .contentTransition(.numericText())
            } else if model.groupsAreStale {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                Text("Groups may be outdated")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 16)
    }

    private func updateGridWidth(_ width: CGFloat) {
        gridWidth = width
        model.keyboardColumnCount = gridColumnCount
    }

    private func openSelectedWindow() {
        if model.activateSelectedWindow() { close() }
    }

    @ViewBuilder
    private var categoryBar: some View {
        if model.taskGroups.isEmpty {
            HStack {
                if model.hasGeneratedGroups {
                    Text("No confident task groups found")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else {
            WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
                taskGroupButton("All", selected: model.selectedTaskGroupID == nil, showsIcon: true) {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        model.selectTaskGroup(nil)
                    }
                }
                ForEach(model.taskGroups) { group in
                    taskGroupButton(group.name, selected: model.selectedTaskGroupID == group.id) {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            model.selectTaskGroup(group)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    private func taskGroupButton(_ title: String, selected: Bool, showsIcon: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if showsIcon {
                    Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle.grid.2x2")
                } else {
                    Text(title)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: categoryBarHeight)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func windowSection(_ title: String?, windows: [WindowItem], dusty: Bool = false) -> some View {
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let title {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(dusty ? .secondary : .primary)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(windows) { window in
                        WindowCard(
                            window: window,
                            dusty: dusty,
                            isSelected: model.selectedWindowID == window.id,
                            liveThumbnail: model.liveThumbnailWindowID == window.id ? model.liveThumbnail : nil,
                            thumbnailHeight: thumbnailHeight,
                            isHidden: model.isWindowHidden(window),
                            canExcludeApp: model.canExcludeApp(window),
                            select: { model.activate(window); close() },
                            toggleHidden: { model.toggleHidden(window) },
                            excludeApp: { appPendingExclusion = window },
                            selectTab: { tab in Task { await model.activate(tab); close() } }
                        )
                        .id(window.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct WindowCard: View {
    let window: WindowItem
    let dusty: Bool
    let isSelected: Bool
    let liveThumbnail: NSImage?
    let thumbnailHeight: CGFloat
    let isHidden: Bool
    let canExcludeApp: Bool
    let select: () -> Void
    let toggleHidden: () -> Void
    let excludeApp: () -> Void
    let selectTab: (SafariTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
                GeometryReader { proxy in
                    ZStack {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            if let icon = window.appIcon {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 72, height: 72)
                            } else {
                                Image(systemName: "macwindow").font(.largeTitle)
                            }
                        }
                        .opacity(window.thumbnailIsUsable && window.thumbnail != nil ? 0 : 1)

                        if let image = window.thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .opacity(window.thumbnailIsUsable ? 1 : 0)
                        }
                        if let liveThumbnail {
                            Image(nsImage: liveThumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .transition(.opacity)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .animation(.easeInOut(duration: 0.18), value: window.thumbnailRevision)
                .animation(.easeInOut(duration: 0.12), value: liveThumbnail != nil)
                .frame(maxWidth: .infinity)
                .frame(height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading) { Text(window.title).font(.headline).lineLimit(1); Text(window.appName).foregroundStyle(.secondary) }
                Spacer()
                if !window.safariTabs.isEmpty { Text("\(window.safariTabs.count) tabs").font(.caption).foregroundStyle(.secondary) }
                Button(action: toggleHidden) {
                    Image(systemName: isHidden ? "eye" : "eye.slash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isHidden ? "Show this window again" : "Hide this window from Kehai")
                if canExcludeApp {
                    Button(action: excludeApp) {
                        Image(systemName: "xmark.app")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Never capture or send this app")
                }
            }
            if !window.safariTabs.isEmpty {
                DisclosureGroup("Safari tabs") {
                    ForEach(window.safariTabs.prefix(30)) { tab in
                        Button { selectTab(tab) } label: { HStack { Image(systemName: tab.isCurrent ? "circle.fill" : "circle"); Text(tab.title).lineLimit(1); Spacer(); Text(tab.domain).foregroundStyle(.secondary).lineLimit(1) } }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 2)
                .padding(1)
        }
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .opacity(dusty ? 0.62 : 1)
    }
}
