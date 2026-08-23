import AppKit
import SwiftUI


private struct ClassicMacCardBackground: View {
    let cornerRadius: CGFloat
    let shadowOffset: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.black)
                .offset(x: shadowOffset, y: shadowOffset)
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(white: 0.93))
        }
    }
}

struct OverviewView: View {
    @Bindable var model: OverviewViewModel
    @Bindable var appearance: AppearanceSettings
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var gridWidth: CGFloat = 0
    @State private var appStripWidth: CGFloat = 0
    @State private var frozenAppWindows: [WindowItem]?

    private let gridSpacing: CGFloat = 18
    private let taskTintPalette: [Color] = [
        Color(red: 0.30, green: 0.58, blue: 0.96),
        Color(red: 0.62, green: 0.46, blue: 0.88),
        Color(red: 0.24, green: 0.70, blue: 0.60),
        Color(red: 0.94, green: 0.59, blue: 0.28),
        Color(red: 0.90, green: 0.43, blue: 0.61)
    ]
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.thumbnailCardWidth, maximum: model.thumbnailCardWidth), spacing: gridSpacing)]
    }
    private var gridColumnCount: Int { max(1, Int((gridWidth + gridSpacing) / (model.thumbnailCardWidth + gridSpacing))) }
    private var thumbnailCellHeight: CGFloat { model.thumbnailCardWidth * 0.64 }

    var body: some View {
        ZStack {
            Group {
                if appearance.browserTheme == .classicMac {
                    Color(white: 0.88)
                } else if appearance.usesGlassyWindow && !reduceTransparency {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 3) {
                searchHeader

                appsSection
                    .padding(.horizontal, 30)

                controlBar
                    .padding(.horizontal, 30)

                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 30)
                }

                VStack(spacing: 0) {
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
                        windowScrollArea
                    }
                    repositorySection
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let window = model.actionChooserWindow, let stage = model.actionChooserStage {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.cancelActionChooser() }
                WindowActionChooser(
                    window: window,
                    stage: stage,
                    selectedIndex: model.actionChooserSelection,
                    canExcludeApp: model.canExcludeApp(window),
                    canExcludeFromAI: model.canExcludeAppFromAI(window),
                    choose: { index in
                        model.actionChooserSelection = index
                        model.confirmActionChooserSelection()
                    },
                    cancel: model.cancelActionChooser
                )
            }
        }
        .onChange(of: model.thumbnailCardWidth) {
            model.keyboardColumnCount = gridColumnCount
        }
        .animation(.easeInOut(duration: 0.16), value: model.thumbnailCardWidth)
        .preferredColorScheme(appearance.browserTheme == .classicMac ? .light : nil)
        .alert("AI request failed", isPresented: Binding(
            get: { model.aiErrorMessage != nil },
            set: { if !$0 { model.aiErrorMessage = nil } }
        )) {
            Button("OK") { model.aiErrorMessage = nil }
        } message: {
            Text(model.aiErrorMessage ?? "The AI provider returned an unexpected error.")
        }
    }

    private var windowScrollArea: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.usesTaskSectionLayout {
                        ForEach(taskFlowRows) { row in
                            HStack(alignment: .top, spacing: gridSpacing) {
                                ForEach(row.segments) { segment in
                                    taskSegment(segment)
                                }
                            }
                        }
                    } else {
                        ForEach(model.windowSections) { section in
                            windowSection(section.title, windows: section.windows)
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.14), value: model.viewMode)
                .animation(.easeInOut(duration: 0.12), value: model.focusedAppKey)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { updateGridWidth(proxy.size.width) }
                        .onChange(of: proxy.size.width) { _, width in updateGridWidth(width) }
                }
            }
            .onChange(of: model.selectedWindowID) { _, selectedWindowID in
                guard !model.isSwitcherMode, let selectedWindowID else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scrollProxy.scrollTo(selectedWindowID, anchor: .center)
                }
            }
        }
    }

    private var searchHeader: some View {
        HStack {
            SearchControl(
                model: model,
                classicTheme: appearance.browserTheme == .classicMac,
                submit: openSelectedWindow
            )
                .frame(maxWidth: 492)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.top, 5)
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.query.isEmpty {
                Text("Apps")
                    .font(.title2.bold())
            }
            recentAppsStrip
        }
    }

    /// Reserve one stable row while icon and label sizes adapt to the app count.
    private var recentAppsRowHeight: CGFloat { 88 }
    private var displayedAppWindows: [WindowItem] {
        if !model.query.isEmpty { return model.filteredRecentAppWindows }
        return model.isSwitcherMode ? model.recentAppWindows : (frozenAppWindows ?? model.recentAppWindows)
    }
    private var appStripItemCount: Int { displayedAppWindows.count + 1 }
    private var appStripSpacing: CGFloat {
        guard appStripItemCount > 1, appStripWidth > 0 else { return 4 }
        let widthPerItem = appStripWidth / CGFloat(appStripItemCount)
        return max(1, min(4, (widthPerItem - 16) / 6))
    }
    private var appStripCellWidth: CGFloat {
        guard appStripItemCount > 0, appStripWidth > 0 else { return 42 }
        return max(12, min(60, (appStripWidth - CGFloat(appStripItemCount - 1) * appStripSpacing - 8) / CGFloat(appStripItemCount)))
    }
    private var appStripIconPadding: CGFloat {
        max(1, min(4, appStripCellWidth * 0.08))
    }
    private var appStripIconSize: CGFloat {
        max(10, min(42, appStripCellWidth - appStripIconPadding * 2))
    }

    private var recentAppsStrip: some View {
        let allWindowsFocused = model.hoveredRepositoryID == nil && model.isAllWindowsAppSelected
        return Group {
            if displayedAppWindows.isEmpty, !model.query.isEmpty {
                HStack(spacing: 6) {
                    if model.isSmartSearching { ProgressView().controlSize(.mini) }
                    Text(model.isSmartSearching ? "Finding matching apps…" : "No matching apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: appStripSpacing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            model.selectAllWindowsApp()
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: max(14, appStripIconSize * 0.58), weight: .medium))
                                .frame(width: appStripIconSize, height: appStripIconSize)
                                .padding(appearance.browserTheme == .classicMac ? max(appStripIconPadding, 7) : appStripIconPadding)
                                .background {
                                    if appearance.browserTheme == .classicMac {
                                        ClassicMacCardBackground(cornerRadius: 1, shadowOffset: 2)
                                    } else {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(allWindowsFocused ? Color.accentColor.opacity(0.12) : .clear)
                                    }
                                }
                                .overlay {
                                    if appearance.browserTheme == .classicMac {
                                        Rectangle()
                                            .strokeBorder(
                                                allWindowsFocused
                                                    ? Color(red: 0.25, green: 0.35, blue: 0.65)
                                                    : .black,
                                                lineWidth: 2
                                            )
                                    }
                                }
                            Text(allWindowsFocused && appStripWidth > 0 ? "All Windows" : " ")
                                .font(.caption2)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.vertical, 4)
                        .frame(width: appStripCellWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id("all-windows")
                    .help("Show all windows")
                    .onHover { isHovering in
                        guard model.isSwitcherMode, isHovering else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            model.selectAllWindowsApp()
                        }
                    }

                    ForEach(Array(displayedAppWindows.enumerated()), id: \.element.id) { index, window in
                        RecentAppButton(
                            window: window,
                            isSelected: model.hoveredRepositoryID == nil && model.isAppFocused(window.id) && !model.suppressSelectionHalo,
                            cellWidth: appStripCellWidth,
                            iconSize: appStripIconSize,
                            iconPadding: appStripIconPadding,
                            stripWidth: appStripWidth,
                            itemCenterX: 4 + CGFloat(index + 1) * (appStripCellWidth + appStripSpacing) + appStripCellWidth / 2,
                            badgeLabel: model.badgeLabel(for: window),
                            classicTheme: appearance.browserTheme == .classicMac,
                            activate: {
                                if model.isAppFocused(window.id) {
                                    model.activate(window)
                                    close()
                                } else {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        model.focusApp(window.id)
                                    }
                                }
                            },
                            hoverChanged: { isHovering in
                                guard isHovering else { return }
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    model.hoverAppInSwitcherMode(window.id)
                                }
                            },
                            dragEntered: {
                                model.dragHoverEntered(windowID: window.id, isAppStrip: true)
                            },
                            dragExited: {
                                model.dragHoverExited(windowID: window.id)
                            },
                            quitApp: { model.quitApp(window) },
                            canExcludeFromAI: model.canExcludeAppFromAI(window),
                            canExcludeEntirely: model.canExcludeApp(window),
                            excludeFromAI: { model.excludeAppFromAI(window) },
                            excludeEntirely: { model.excludeApp(for: window) }
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        if frozenAppWindows == nil { frozenAppWindows = model.recentAppWindows }
                    } else {
                        frozenAppWindows = nil
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { updateAppStripWidth(proxy.size.width) }
                            .onChange(of: proxy.size.width) { _, width in updateAppStripWidth(width) }
                    }
                }
            }
        }
        .frame(height: recentAppsRowHeight, alignment: .leading)
    }

    private func updateAppStripWidth(_ width: CGFloat) {
        guard width > 0, width != appStripWidth else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            appStripWidth = width
        }
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                GroupingControl(model: model)
                Spacer(minLength: 12)
                ViewModeControl(model: model, classicTheme: appearance.browserTheme == .classicMac)
                HiddenWindowsControl(model: model, classicTheme: appearance.browserTheme == .classicMac)
            }

            WrappingHStack(horizontalSpacing: 12, verticalSpacing: 10) {
                GroupingControl(model: model)
                ViewModeControl(model: model, classicTheme: appearance.browserTheme == .classicMac)
                HiddenWindowsControl(model: model, classicTheme: appearance.browserTheme == .classicMac)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, appearance.browserTheme == .classicMac ? 4 : 0)
    }

    private func updateGridWidth(_ width: CGFloat) {
        gridWidth = width
        model.keyboardColumnCount = gridColumnCount
    }

    private func openSelectedWindow() {
        if model.activateCurrentSelection() { close() }
    }

    private var taskFlowColumnCount: Int {
        max(1, Int((max(model.thumbnailCardWidth, gridWidth - 60) + gridSpacing) / (model.thumbnailCardWidth + gridSpacing)))
    }

    private var taskFlowRows: [TaskFlowRow] {
        var rows: [TaskFlowRow] = []
        var segments: [TaskFlowSegment] = []
        var remainingSlots = taskFlowColumnCount

        func finishRow() {
            guard !segments.isEmpty else { return }
            rows.append(TaskFlowRow(index: rows.count, segments: segments))
            segments = []
            remainingSlots = taskFlowColumnCount
        }

        for (sectionIndex, section) in model.windowSections.enumerated() {
            var remainingWindows = section.windows
            var segmentIndex = 0
            while !remainingWindows.isEmpty {
                if remainingWindows.count <= taskFlowColumnCount,
                   remainingWindows.count > remainingSlots,
                   remainingSlots < taskFlowColumnCount {
                    finishRow()
                }

                let count = min(remainingWindows.count, remainingSlots)
                let windows = Array(remainingWindows.prefix(count))
                remainingWindows.removeFirst(count)
                segments.append(TaskFlowSegment(
                    id: "\(section.id)-\(segmentIndex)",
                    section: section,
                    sectionIndex: sectionIndex,
                    windows: windows,
                    showsTitle: segmentIndex == 0
                ))
                segmentIndex += 1
                remainingSlots -= count
                if remainingSlots == 0 { finishRow() }
            }
        }
        finishRow()
        return rows
    }

    private func taskTint(for section: BrowserWindowSection, at index: Int) -> Color? {
        guard section.id != "other" else { return nil }
        return taskTintPalette[index % taskTintPalette.count]
    }

    @ViewBuilder
    private func taskSegment(_ segment: TaskFlowSegment) -> some View {
        let width = CGFloat(segment.windows.count) * model.thumbnailCardWidth
            + CGFloat(max(0, segment.windows.count - 1)) * gridSpacing
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if segment.showsTitle, let title = segment.section.title {
                    Text(title)
                } else {
                    Text(" ").hidden()
                }
            }
            .font(.title2.bold())
            .foregroundStyle(taskTint(for: segment.section, at: segment.sectionIndex) ?? .primary)
            .lineLimit(1)
            HStack(spacing: gridSpacing) {
                ForEach(segment.windows) { window in
                    windowCard(window, tint: taskTint(for: segment.section, at: segment.sectionIndex))
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
    }

    private func windowCard(_ window: WindowItem, dusty: Bool = false, tint: Color? = nil) -> some View {
        WindowCard(
            window: window,
            dusty: dusty,
            tint: tint,
            classicTheme: appearance.browserTheme == .classicMac,
            isSelected: model.hoveredRepositoryID == nil && model.selectedWindowID == window.id && !model.suppressSelectionHalo,
            liveThumbnail: model.liveThumbnailWindowID == window.id ? model.liveThumbnail : nil,
            isRefreshingThumbnail: model.refreshingThumbnailWindowIDs.contains(window.physicalWindowID),
            thumbnailCellHeight: thumbnailCellHeight,
            isHidden: model.isWindowHidden(window),
            canExcludeApp: model.canExcludeApp(window),
            canExcludeFromAI: model.canExcludeAppFromAI(window),
            taskContext: model.taskContext(for: window.id),
            select: { model.activate(window); close() },
            hoverChanged: { isHovering in model.hoverWindowInSwitcherMode(isHovering ? window.id : nil) },
            dragEntered: { model.dragHoverEntered(windowID: window.id, isAppStrip: false) },
            dragExited: { model.dragHoverExited(windowID: window.id) },
            closeWindow: { model.closeWindowFromMenu(window) },
            toggleHidden: { model.toggleHidden(window) },
            excludeApp: {
                model.selectedWindowID = window.id
                model.showActionChooserForSelectedWindow()
            },
            excludeFromAI: { model.excludeAppFromAI(window) },
            excludeEntirely: { model.excludeApp(for: window) },
            selectTab: { tab in Task { await model.activate(tab); close() } }
        )
        .frame(width: model.thumbnailCardWidth)
        .id(window.id)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder
    private var repositorySection: some View {
        let repositories = model.filteredGitHubRepositories
        if model.githubRepositoryStore.hasSavedTokens {
            if appearance.browserTheme == .classicMac {
                Rectangle()
                    .fill(.black)
                    .frame(height: 2)
            } else {
                Divider()
            }
            ScrollViewReader { scrollProxy in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("GitHub Repositories")
                            .font(.headline)
                            .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.primary)
                        if model.githubRepositoryStore.isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        if model.query.isEmpty, !repositories.isEmpty {
                            Text("Recently updated")
                                .font(.caption)
                                .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
                        }
                    }
                    if repositories.isEmpty {
                        Text(model.githubRepositoryStore.isLoading
                            ? "Loading repositories…"
                            : model.query.isEmpty ? "No repositories available" : "No matching repositories")
                            .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
                            .frame(height: 96, alignment: .topLeading)
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(repositories) { repository in
                                    RepositoryResultCard(
                                        repository: repository,
                                        isSelected: model.hoveredRepositoryID.map { $0 == repository.id }
                                            ?? (model.selectedRepositoryID == repository.id),
                                        compact: false,
                                        classicTheme: appearance.browserTheme == .classicMac,
                                        activate: {
                                            _ = model.activate(repository)
                                            close()
                                        },
                                        openPullRequests: {
                                            _ = model.openPullRequests(for: repository)
                                            close()
                                        },
                                        hoverChanged: { hovering in
                                            if hovering {
                                                model.setHoveredRepository(repository.id)
                                            } else if model.hoveredRepositoryID == repository.id {
                                                model.setHoveredRepository(nil)
                                            }
                                        }
                                    )
                                    .frame(width: model.thumbnailCardWidth)
                                    .id("repository-\(repository.id)")
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .frame(height: 96)
                    }
                    if let error = model.githubRepositoryStore.errorMessage, repositories.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.black.opacity(0.16))
                        .frame(height: 1)
                        .blur(radius: 5)
                        .offset(y: -4)
                        .allowsHitTesting(false)
                }
                .onChange(of: model.selectedRepositoryID) { _, repositoryID in
                    guard let repositoryID else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollProxy.scrollTo("repository-\(repositoryID)", anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func windowSection(_ title: String?, windows: [WindowItem], dusty: Bool = false) -> some View {
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(dusty ? .secondary : .primary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(windows) { window in
                        windowCard(window, dusty: dusty)
                    }
                }
            }
            .padding(.top, 3)
            .padding(.bottom, 5)
        } else if let title, !model.query.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.bold())
                Text("No matching windows").foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }
    }
}


struct CompactSwitcherView: View {
    @Bindable var model: OverviewViewModel
    @Bindable var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let opensRight: Bool
    let opensUp: Bool
    let openBrowser: () -> Void
    let close: () -> Void
    @State private var compactWidth: CGFloat = 676
    @FocusState private var compactSearchIsFocused: Bool
    @State private var appStripPointerLocation: CGPoint?
    @State private var activeHoveredAppID: String?
    @State private var pendingHoveredAppID: String?
    @State private var pointerIntentLockedAppID: String?
    @State private var pointerIntentLockExpiresAt = Date.distantPast
    @State private var deferredAppHoverTask: Task<Void, Never>?

    private let compactAppCellWidth: CGFloat = 55
    private let compactAppSpacing: CGFloat = 2
    private let compactAppHorizontalPadding: CGFloat = 10

    private var maximumVisibleApps: Int {
        let splitLayoutSpacing: CGFloat = opensRight ? 0 : 12
        let availableWidth = compactWidth - compactAppHorizontalPadding * 2 - splitLayoutSpacing
        let totalCellCount = max(1, Int((availableWidth + compactAppSpacing) / (compactAppCellWidth + compactAppSpacing)))
        return max(0, totalCellCount - 1)
    }

    private var displayedApps: [WindowItem] {
        Array(model.filteredRecentAppWindows.prefix(maximumVisibleApps))
    }

    private let compactWindowWidth: CGFloat = 212


    private var maximumVisibleWindows: Int {
        max(1, Int((compactWidth - 24 + 8) / (compactWindowWidth + 8)))
    }

    private var displayedWindows: [WindowItem] {
        Array(model.filteredWindows.prefix(maximumVisibleWindows))
    }


    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if opensUp {
                    compactHeader
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    compactWindows
                        .padding(.top, 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.horizontal, 12)
                    compactRepositoryShelf
                    appStrip
                        .padding(.bottom, 2)
                } else {
                    compactHeader
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    appStrip
                    compactWindows
                        .padding(.top, 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.horizontal, 12)
                    compactRepositoryShelf
                        .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)

            if let window = model.actionChooserWindow, let stage = model.actionChooserStage {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.cancelActionChooser() }
                WindowActionChooser(
                    window: window,
                    stage: stage,
                    selectedIndex: model.actionChooserSelection,
                    canExcludeApp: model.canExcludeApp(window),
                    canExcludeFromAI: model.canExcludeAppFromAI(window),
                    choose: { index in
                        model.actionChooserSelection = index
                        model.confirmActionChooserSelection()
                    },
                    cancel: model.cancelActionChooser
                )
            }
        }
        .background {
            if appearance.browserTheme == .classicMac {
                Color(white: 0.88)
            } else if appearance.usesGlassyWindow && !reduceTransparency {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateCompactWidth(proxy.size.width - 8) }
                    .onChange(of: proxy.size.width) { _, width in updateCompactWidth(width - 8) }
            }
        }
        .onChange(of: model.compactSearchFocusRequest) {
            compactSearchIsFocused = true
            DispatchQueue.main.async {
                model.applyPendingPinnedSwitcherSearchText()
            }
        }
        .onChange(of: model.compactSearchBlurRequest) {
            compactSearchIsFocused = false
        }
        .preferredColorScheme(appearance.browserTheme == .classicMac ? .light : nil)
    }

    private var compactHeader: some View {
        compactQueryIndicator
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }

    private var compactQueryIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
            TextField("Search windows, apps, and GitHub repositories", text: $model.query)
                .textFieldStyle(.plain)
                .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.primary)
                .focused($compactSearchIsFocused)
                .onSubmit {
                    if model.activateCurrentSelection() { close() }
                }
                .onChange(of: model.query) {
                    if compactSearchIsFocused { model.updatePinnedSwitcherSearchSelection() }
                }
            Spacer(minLength: 0)
            if !model.query.isEmpty {
                Text("Esc to clear")
                    .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: appearance.browserTheme == .classicMac ? 30 : 22)
        .background {
            if appearance.browserTheme == .classicMac {
                ClassicMacCardBackground(cornerRadius: 0, shadowOffset: 2)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.55))
            }
        }
        .overlay {
            Group {
                if appearance.browserTheme == .classicMac {
                    Rectangle()
                        .strokeBorder(
                            compactSearchIsFocused ? Color(red: 0.25, green: 0.35, blue: 0.65) : .black,
                            lineWidth: 2
                        )
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(compactSearchIsFocused ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: max(330, compactWidth / 2))
    }


    private var appStrip: some View {
        HStack(spacing: compactAppSpacing) {
            if opensRight {
                allWindowsButton(itemIndex: 0)
            }
            ForEach(Array(displayedApps.enumerated()), id: \.element.id) { index, window in
                compactAppButton(window, itemIndex: index + (opensRight ? 1 : 0))
            }
            if !opensRight {
                Spacer(minLength: 12)
                allWindowsButton(itemIndex: displayedApps.count)
            }
        }
        .padding(.horizontal, compactAppHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: appearance.browserTheme == .classicMac ? 80 : 66)
        .clipped()
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                updateAppStripPointerIntent(at: location)
            case .ended:
                appStripPointerLocation = nil
                activeHoveredAppID = nil
                cancelDeferredAppHover()
            }
        }
    }

    private func allWindowsButton(itemIndex: Int) -> some View {
        Button(action: openBrowser) {
            compactIconLabel(
                icon: Image(systemName: "square.grid.2x2"),
                title: "All Windows",
                selected: model.hoveredRepositoryID == nil && model.isAllWindowsAppSelected,
                itemIndex: itemIndex,
                badgeLabel: nil
            )
        }
        .buttonStyle(.plain)
        .id("compact-all-windows")
        .onHover { hovering in
            handleCompactAppHover(appID: "compact-all-windows", hovering: hovering) {
                model.selectAllWindowsApp()
            }
        }
    }

    private func compactAppButton(_ window: WindowItem, itemIndex: Int) -> some View {
        let selected = model.hoveredRepositoryID == nil && model.isAppFocused(window.id) && !model.suppressSelectionHalo
        return Button {
            if model.isAppFocused(window.id) {
                model.activate(window)
                close()
            } else {
                model.focusApp(window.id)
            }
        } label: {
            compactIconLabel(
                icon: window.appIcon.map { Image(nsImage: $0) } ?? Image(systemName: "app"),
                title: window.appName,
                selected: selected,
                itemIndex: itemIndex,
                badgeLabel: model.badgeLabel(for: window)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.string("Quit App")) { model.quitApp(window) }
            Menu(L10n.string("Exclude App…")) {
                Button(L10n.string("From AI Queries")) { model.excludeAppFromAI(window) }
                    .disabled(!model.canExcludeAppFromAI(window))
                Button(L10n.string("From Kehai Entirely")) { model.excludeApp(for: window) }
                    .disabled(!model.canExcludeApp(window))
            }
            .disabled(!model.canExcludeAppFromAI(window) && !model.canExcludeApp(window))
        }
        .onHover { hovering in
            handleCompactAppHover(appID: compactAppHoverID(window), hovering: hovering) {
                model.hoverAppInSwitcherMode(window.id)
            }
        }
        .dragHoverCatcher(
            onEntered: { model.dragHoverEntered(windowID: window.id, isAppStrip: true) },
            onExited: { model.dragHoverExited(windowID: window.id) }
        )
    }

    private func compactIconLabel(
        icon: Image,
        title: String,
        selected: Bool,
        itemIndex: Int,
        badgeLabel: String?
    ) -> some View {
        let isAllWindows = title == "All Windows"
        let itemCenterX = !opensRight && isAllWindows
            ? compactWidth - compactAppHorizontalPadding - compactAppCellWidth / 2
            : compactAppHorizontalPadding
                + CGFloat(itemIndex) * (compactAppCellWidth + compactAppSpacing)
                + compactAppCellWidth / 2
        let labelOffset = compactLabelOffset(title: title, itemCenterX: itemCenterX)
        return VStack(spacing: 2) {
            icon
                .resizable()
                .scaledToFit()
                .padding(isAllWindows ? 5 : 0)
                .frame(width: 36, height: 36)
                .overlay(alignment: .topTrailing) {
                    AppBadgeView(label: badgeLabel)
                        .offset(
                            x: appearance.browserTheme == .classicMac ? 2 : 5,
                            y: appearance.browserTheme == .classicMac ? 1 : 4
                        )
                }
                .padding(appearance.browserTheme == .classicMac ? 6 : 2)
                .background {
                    if appearance.browserTheme == .classicMac {
                        ClassicMacCardBackground(cornerRadius: 1, shadowOffset: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
                            .padding(.horizontal, -5)
                            .padding(.vertical, -4)
                    }
                }
                .overlay {
                    if appearance.browserTheme == .classicMac {
                        Rectangle()
                            .strokeBorder(
                                selected ? Color(red: 0.25, green: 0.35, blue: 0.65) : .black,
                                lineWidth: 2
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(selected ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            .padding(.horizontal, -5)
                            .padding(.vertical, -4)
                    }
                }
            Text(selected ? title : " ")
                .font(.caption2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: labelOffset, y: 4)
                .frame(width: compactAppCellWidth)
        }
        .padding(.vertical, appearance.browserTheme == .classicMac ? 3 : 0)
        .frame(width: compactAppCellWidth)
        .contentShape(Rectangle())
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func compactLabelOffset(title: String, itemCenterX: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ]
        let halfWidth = ceil((title as NSString).size(withAttributes: attributes).width) / 2
        let edgeInset: CGFloat = 8
        let minimumCenter = edgeInset + halfWidth
        let maximumCenter = compactWidth - edgeInset - halfWidth
        return min(max(itemCenterX, minimumCenter), maximumCenter) - itemCenterX
    }

    private func compactAppHoverID(_ window: WindowItem) -> String {
        "compact-app-\(window.id)"
    }

    private func updateAppStripPointerIntent(at location: CGPoint) {
        defer { appStripPointerLocation = location }
        guard let previous = appStripPointerLocation else { return }

        let deltaX = location.x - previous.x
        let deltaY = location.y - previous.y
        let directionalY = opensUp ? -deltaY : deltaY
        let horizontalDistance = abs(deltaX)
        let isClearlyMovingTowardWindows = directionalY >= horizontalDistance * 0.55
        let isTraversingAppStrip = horizontalDistance > max(directionalY, 0) * 1.4

        if isTraversingAppStrip {
            clearPointerIntentLock()
        } else if isClearlyMovingTowardWindows, let activeHoveredAppID {
            pointerIntentLockedAppID = activeHoveredAppID
            pointerIntentLockExpiresAt = Date().addingTimeInterval(0.24)
        }
    }

    private func handleCompactAppHover(
        appID: String,
        hovering: Bool,
        action: @escaping @MainActor () -> Void
    ) {
        if !hovering {
            if pendingHoveredAppID == appID { cancelDeferredAppHover() }
            return
        }

        let remainingLockDuration = pointerIntentLockExpiresAt.timeIntervalSinceNow
        if let pointerIntentLockedAppID,
           pointerIntentLockedAppID != appID,
           remainingLockDuration > 0 {
            cancelDeferredAppHover()
            pendingHoveredAppID = appID
            deferredAppHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(remainingLockDuration))
                guard !Task.isCancelled, pendingHoveredAppID == appID else { return }
                selectHoveredCompactApp(appID: appID, action: action)
            }
            return
        }

        selectHoveredCompactApp(appID: appID, action: action)
    }

    private func selectHoveredCompactApp(
        appID: String,
        action: @MainActor () -> Void
    ) {
        cancelDeferredAppHover()
        activeHoveredAppID = appID
        action()
    }

    private func clearPointerIntentLock() {
        pointerIntentLockedAppID = nil
        pointerIntentLockExpiresAt = .distantPast
        cancelDeferredAppHover()
    }

    private func cancelDeferredAppHover() {
        deferredAppHoverTask?.cancel()
        deferredAppHoverTask = nil
        pendingHoveredAppID = nil
    }

    private func updateCompactWidth(_ width: CGFloat) {
        guard width > 0, width != compactWidth else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            compactWidth = width
        }
    }

    @ViewBuilder
    private var compactRepositoryShelf: some View {
        if model.githubRepositoryStore.hasSavedTokens {
            Divider()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 5) {
                compactSectionLabel("GitHub Repositories")
                if model.githubRepositoryStore.isLoading, model.filteredGitHubRepositories.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Loading repositories…")
                            .font(.caption)
                            .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else if model.filteredGitHubRepositories.isEmpty {
                    Text(model.query.isEmpty ? "No repositories available" : "No matching repositories")
                        .font(.caption)
                        .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 7) {
                                ForEach(model.filteredGitHubRepositories) { repository in
                                    RepositoryResultCard(
                                        repository: repository,
                                        isSelected: model.hoveredRepositoryID.map { $0 == repository.id }
                                            ?? (model.selectedRepositoryID == repository.id),
                                        compact: true,
                                        classicTheme: appearance.browserTheme == .classicMac,
                                        activate: {
                                            _ = model.activate(repository)
                                            close()
                                        },
                                        openPullRequests: {
                                            _ = model.openPullRequests(for: repository)
                                            close()
                                        },
                                        hoverChanged: { hovering in
                                            if hovering {
                                                model.setHoveredRepository(repository.id)
                                            } else if model.hoveredRepositoryID == repository.id {
                                                model.setHoveredRepository(nil)
                                            }
                                        }
                                    )
                                    .id("compact-repository-\(repository.id)")
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .frame(height: 60)
                        .onChange(of: model.selectedRepositoryID) { _, repositoryID in
                            guard let repositoryID else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo("compact-repository-\(repositoryID)", anchor: .center)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 5)
        }
    }


    private func compactSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(appearance.browserTheme == .classicMac ? Color.black : Color.secondary)
    }

    private var compactWindows: some View {
        Group {
            if displayedWindows.isEmpty {
                Text("No open windows")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    ForEach(displayedWindows) { window in
                        compactWindowButton(window)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.07), value: model.focusedAppKey)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { clearPointerIntentLock() }
        }
    }

    private func compactWindowButton(_ window: WindowItem) -> some View {
        let selected = model.hoveredRepositoryID == nil && model.selectedWindowID == window.id && !model.suppressSelectionHalo
        return Button {
            model.activate(window)
            close()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(window.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                compactThumbnail(window)
            }
            .padding(8)
            .frame(width: compactWindowWidth, alignment: .leading)
            .background {
                if appearance.browserTheme == .classicMac {
                    ClassicMacCardBackground(cornerRadius: 1, shadowOffset: 2)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: appearance.browserTheme == .classicMac ? 1 : 6)
                    .strokeBorder(
                        appearance.browserTheme == .classicMac
                            ? selected ? Color(red: 0.25, green: 0.35, blue: 0.65) : Color.black
                            : selected ? Color.accentColor.opacity(0.85) : Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: appearance.browserTheme == .classicMac && selected ? 3 : appearance.browserTheme == .classicMac || selected ? 2 : 1
                    )
            }

        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.string("Close Window")) { model.closeWindowFromMenu(window) }
            Button(L10n.string("Hide Window in Kehai")) { model.toggleHidden(window) }
            Menu(L10n.string("Exclude App…")) {
                Button(L10n.string("From AI Queries")) { model.excludeAppFromAI(window) }
                    .disabled(!model.canExcludeAppFromAI(window))
                Button(L10n.string("From Kehai Entirely")) { model.excludeApp(for: window) }
                    .disabled(!model.canExcludeApp(window))
            }
            .disabled(!model.canExcludeAppFromAI(window) && !model.canExcludeApp(window))
        }
        .onHover { hovering in model.hoverWindowInSwitcherMode(hovering ? window.id : nil) }
        .dragHoverCatcher(
            onEntered: { model.dragHoverEntered(windowID: window.id, isAppStrip: false) },
            onExited: { model.dragHoverExited(windowID: window.id) }
        )
    }

    @ViewBuilder
    private func compactThumbnail(_ window: WindowItem) -> some View {
        let liveThumbnail = model.liveThumbnailWindowID == window.id ? model.liveThumbnail : nil
        ZStack {
            Color.clear
            if window.thumbnailIsUsable, let thumbnail = window.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
            }
            if let liveThumbnail {
                Image(nsImage: liveThumbnail)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
                Text("Live")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.62), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
            if let icon = window.appIcon,
               liveThumbnail != nil || (window.thumbnailIsUsable && window.thumbnail != nil) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }
        }
        .frame(height: 134)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(.easeInOut(duration: 0.12), value: liveThumbnail != nil)
    }
}

private struct RepositoryResultCard: View {
    @State private var isHoveringPullRequests = false

    let repository: GitHubRepository
    let isSelected: Bool
    let compact: Bool
    let classicTheme: Bool
    let activate: () -> Void
    let openPullRequests: () -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: activate) {
                HStack(alignment: .top, spacing: compact ? 7 : 10) {
                    ownerAvatar
                    VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                        Text(repository.ownerLogin)
                            .font(compact ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(repository.name)
                            .font(compact ? .caption.weight(.semibold) : .headline)
                            .lineLimit(1)
                        if !compact, let description = repository.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            if repository.isFork { repoBadge("Fork") }
                            if repository.isArchived { repoBadge("Archived") }
                            if let pushedAt = repository.pushedAt {
                                HStack(spacing: 2) {
                                    Text("Pushed")
                                    Text(relativePushTime(pushedAt))
                                }
                                .font(.system(size: compact ? 9 : 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, compact ? 30 : 38)
                .padding(compact ? 7 : 12)
                .frame(width: compact ? 200 : nil, height: compact ? 60 : 96, alignment: .leading)
                .background {
                    if classicTheme {
                        ClassicMacCardBackground(cornerRadius: 1, shadowOffset: 2)
                    } else {
                        RoundedRectangle(cornerRadius: compact ? 4.5 : 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: classicTheme ? 1 : (compact ? 4.5 : 6))
                        .strokeBorder(
                            classicTheme
                                ? isSelected ? Color(red: 0.25, green: 0.35, blue: 0.65) : Color.black
                                : isSelected ? Color.accentColor.opacity(0.9) : Color(nsColor: .separatorColor).opacity(0.35),
                            lineWidth: classicTheme || isSelected ? 2 : 1
                        )
                }

            }
            .buttonStyle(.plain)
            .help("Open \(repository.fullName) on GitHub")

            Button(action: openPullRequests) {
                Text("PRs")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        classicTheme
                            ? isHoveringPullRequests ? Color.white : Color.black
                            : isHoveringPullRequests ? Color.accentColor : Color.secondary
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        if classicTheme {
                            ZStack {
                                Rectangle().fill(.black).offset(x: 1, y: 1)
                                Rectangle().fill(isHoveringPullRequests ? Color.black : Color(white: 0.90))
                            }
                        } else {
                            Capsule()
                                .fill(isHoveringPullRequests ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                        }
                    }
                    .overlay {
                        if classicTheme {
                            Rectangle().strokeBorder(.black, lineWidth: 1)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Open pull requests for \(repository.fullName)")
            .onHover { isHoveringPullRequests = $0 }
            .animation(.easeOut(duration: 0.1), value: isHoveringPullRequests)
            .padding(compact ? 6 : 10)
        }
        .onHover(perform: hoverChanged)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }

    @ViewBuilder
    private var ownerAvatar: some View {
        let size: CGFloat = compact ? 30 : 38
        AsyncImage(url: repository.ownerAvatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    ProgressView().controlSize(.mini)
                }
            case .failure:
                avatarFallback
            @unknown default:
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 6))
    }

    private var avatarFallback: some View {
        Image(systemName: "person.crop.square")
            .resizable()
            .scaledToFit()
            .padding(5)
            .foregroundStyle(.secondary)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private func relativePushTime(_ date: Date) -> String {
        let secondsAgo = Date().timeIntervalSince(date)
        if secondsAgo >= 0, secondsAgo < 60 { return "<1 min ago" }
        if secondsAgo < 0, secondsAgo > -60 { return "in <1 min" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func repoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(classicTheme ? Color.black : Color.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                if classicTheme {
                    ZStack {
                        Rectangle().fill(.black).offset(x: 1, y: 1)
                        Rectangle().fill(Color(white: 0.90))
                    }
                } else {
                    Capsule().fill(.quaternary)
                }
            }
            .overlay {
                if classicTheme {
                    Rectangle().strokeBorder(.black, lineWidth: 1)
                }
            }
    }
}

private struct TaskFlowRow: Identifiable {
    let index: Int
    let segments: [TaskFlowSegment]
    var id: Int { index }
}

private struct TaskFlowSegment: Identifiable {
    let id: String
    let section: BrowserWindowSection
    let sectionIndex: Int
    let windows: [WindowItem]
    let showsTitle: Bool
}

private struct RecentAppButton: View {
    let window: WindowItem
    let isSelected: Bool
    let cellWidth: CGFloat
    let iconSize: CGFloat
    let iconPadding: CGFloat
    let stripWidth: CGFloat
    let itemCenterX: CGFloat
    let badgeLabel: String?
    let classicTheme: Bool
    let activate: () -> Void
    let hoverChanged: (Bool) -> Void
    let dragEntered: () -> Void
    let dragExited: () -> Void
    let quitApp: () -> Void
    let canExcludeFromAI: Bool
    let canExcludeEntirely: Bool
    let excludeFromAI: () -> Void
    let excludeEntirely: () -> Void

    private var appNameWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ]
        return ceil((window.appName as NSString).size(withAttributes: attributes).width)
    }

    private var labelAlignment: Alignment {
        let halfWidth = appNameWidth / 2
        if itemCenterX - halfWidth < 0 { return .leading }
        if itemCenterX + halfWidth > stripWidth { return .trailing }
        return .center
    }

    var body: some View {
        Button(action: activate) {
            VStack(spacing: 3) {
                Group {
                    if let icon = window.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app")
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .overlay(alignment: .topTrailing) {
                    AppBadgeView(label: badgeLabel)
                        .offset(x: classicTheme ? 2 : 5, y: classicTheme ? 1 : 4)
                }
                .padding(classicTheme ? max(iconPadding, 7) : iconPadding)
                .background {
                    if classicTheme {
                        ClassicMacCardBackground(cornerRadius: 1, shadowOffset: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
                            .padding(-4)
                    }
                }
                .overlay {
                    if classicTheme {
                        Rectangle()
                            .strokeBorder(
                                isSelected ? Color(red: 0.25, green: 0.35, blue: 0.65) : .black,
                                lineWidth: 2
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
                            .padding(-4)
                    }
                }

                Text(isSelected && stripWidth > 0 ? window.appName : " ")
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(y: 2)
                    .frame(width: cellWidth, alignment: labelAlignment)
            }
            .padding(.vertical, 4)
            .frame(width: cellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L10n.string("Quit App"), action: quitApp)
            Menu(L10n.string("Exclude App…")) {
                Button(L10n.string("From AI Queries"), action: excludeFromAI)
                    .disabled(!canExcludeFromAI)
                Button(L10n.string("From Kehai Entirely"), action: excludeEntirely)
                    .disabled(!canExcludeEntirely)
            }
            .disabled(!canExcludeFromAI && !canExcludeEntirely)
        }
        .onHover(perform: hoverChanged)
        .dragHoverCatcher(onEntered: dragEntered, onExited: dragExited)
    }
}

private struct AppBadgeView: View {
    let label: String?

    private var displayText: String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        guard let count = Int(label) else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    private var numberedBadgeWidth: CGFloat {
        switch displayText?.count {
        case 1: 16
        case 2: 20
        default: 25
        }
    }

    var body: some View {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ZStack {
                Capsule()
                    .fill(.red)
                    .frame(
                        width: displayText == nil ? 16 : numberedBadgeWidth,
                        height: 16
                    )
                if let displayText {
                    Text(displayText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(width: numberedBadgeWidth, height: 16, alignment: .center)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 3, height: 3)
                }
            }
            .fixedSize()
            .offset(
                x: displayText == nil ? -2 : -2,
                y: -5
            )
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            .accessibilityLabel("Unread: \(label)")
        }
    }
}

private struct WindowActionChooser: View {
    let window: WindowItem
    let stage: WindowActionChooserStage
    let selectedIndex: Int
    let canExcludeApp: Bool
    let canExcludeFromAI: Bool
    let choose: (Int) -> Void
    let cancel: () -> Void

    private var options: [(title: String, detail: String)] {
        switch stage {
        case .removal:
            return [
                (L10n.string("Close Window"), L10n.format("Use %@’s normal close action. Unsaved-work prompts appear in the app.", window.appName)),
                (L10n.string("Hide Window in Kehai"), L10n.string("Hide only this window from the browser."))
            ] + (canExcludeApp ? [(L10n.string("Exclude App…"), L10n.format("Choose whether to exclude every %@ window from AI or Kehai.", window.appName))] : [])
        case .exclusion:
            return (canExcludeFromAI ? [(L10n.string("From AI Queries"), L10n.format("Keep %@ visible locally, but never send its data to AI. Change this later in Settings.", window.appName))] : [])
                + [(L10n.string("From Kehai Entirely"), L10n.format("Remove %@ from Kehai entirely. Change this later in Settings.", window.appName))]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(stage == .removal ? L10n.format("Remove %@?", window.title) : L10n.format("Exclude %@?", window.appName))
                .font(.headline)
                .lineLimit(2)
            VStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button { choose(index) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIndex == index ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selectedIndex == index ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .fontWeight(.medium)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(selectedIndex == index ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Use the arrow keys, then press Return. Escape cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)) }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}

private struct WindowCard: View {
    let window: WindowItem
    let dusty: Bool
    let tint: Color?
    let classicTheme: Bool
    let isSelected: Bool
    let liveThumbnail: NSImage?
    let isRefreshingThumbnail: Bool
    let thumbnailCellHeight: CGFloat
    let isHidden: Bool
    let canExcludeApp: Bool
    let canExcludeFromAI: Bool
    let taskContext: String?
    let select: () -> Void
    let hoverChanged: (Bool) -> Void
    let dragEntered: () -> Void
    let dragExited: () -> Void
    let closeWindow: () -> Void
    let toggleHidden: () -> Void
    let excludeApp: () -> Void
    let excludeFromAI: () -> Void
    let excludeEntirely: () -> Void
    let selectTab: (SafariTab) -> Void

    private var capturedWindowCornerRadius: CGFloat {
        min(4, max(2, thumbnailCellHeight * 0.0125))
    }

    var body: some View {
        ZStack {
            Button(action: select) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(-12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(window.title)

            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Color.clear

                    Group {
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
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: capturedWindowCornerRadius))
                            .opacity(window.thumbnailIsUsable ? 1 : 0)
                    }
                    if let liveThumbnail {
                        Image(nsImage: liveThumbnail)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: capturedWindowCornerRadius))
                            .transition(.opacity)

                        Text("Live")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(8)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    if let icon = window.appIcon,
                       liveThumbnail != nil || (window.thumbnailIsUsable && window.thumbnail != nil) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: thumbnailCellHeight)
                .clipped()
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .animation(.easeInOut(duration: 0.18), value: window.thumbnailRevision)
                .animation(.easeInOut(duration: 0.12), value: liveThumbnail != nil)
                .allowsHitTesting(false)
                HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.title).font(.headline).lineLimit(1)
                    Text(taskContext ?? " ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityHidden(taskContext == nil)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .allowsHitTesting(false)
                if !window.safariTabs.isEmpty {
                    Text(L10n.format("%lld tabs", Int64(window.safariTabs.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .allowsHitTesting(false)
                }
                if isRefreshingThumbnail, liveThumbnail == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .allowsHitTesting(false)
                        .frame(width: 18, height: 18)
                        .transition(.opacity)
                }
                Button(action: toggleHidden) {
                    Image(systemName: isHidden ? "eye" : "eye.slash")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(isHidden ? "Show this window again" : "Hide this window from Kehai")
                if canExcludeApp {
                    Button(action: excludeApp) {
                        Image(systemName: "xmark.app")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Exclude this app from AI or Kehai")
                }
            }
            .frame(minHeight: 18)
            if !window.safariTabs.isEmpty {
                DisclosureGroup("Safari tabs") {
                    ForEach(window.safariTabs.prefix(30)) { tab in
                        Button { selectTab(tab) } label: { HStack { Image(systemName: tab.isCurrent ? "circle.fill" : "circle"); Text(tab.title).lineLimit(1); Spacer(); Text(tab.domain).foregroundStyle(.secondary).lineLimit(1) } }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }
            }
            }
        }
        .padding(12)
        .background {
            if classicTheme {
                ClassicMacCardBackground(cornerRadius: 1, shadowOffset: 3)
            } else if let tint {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.20))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: classicTheme ? 1 : 7.5)
                .strokeBorder(
                    classicTheme
                        ? isSelected ? Color(red: 0.25, green: 0.35, blue: 0.65) : Color.black
                        : isSelected ? Color.accentColor.opacity(0.85) : (tint?.opacity(0.42) ?? .clear),
                    lineWidth: classicTheme && isSelected ? 3 : classicTheme || isSelected ? 2 : 1
                )
                .padding(classicTheme ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .contextMenu {
            Button(L10n.string("Close Window"), action: closeWindow)
            Button(L10n.string("Hide Window in Kehai"), action: toggleHidden)
            Menu(L10n.string("Exclude App…")) {
                Button(L10n.string("From AI Queries"), action: excludeFromAI)
                    .disabled(!canExcludeFromAI)
                Button(L10n.string("From Kehai Entirely"), action: excludeEntirely)
                    .disabled(!canExcludeApp)
            }
            .disabled(!canExcludeFromAI && !canExcludeApp)
        }
        .onHover(perform: hoverChanged)
        .dragHoverCatcher(onEntered: dragEntered, onExited: dragExited)
        .opacity(dusty ? 0.62 : 1)
    }
}
