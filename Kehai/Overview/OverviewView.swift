import AppKit
import SwiftUI

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
                if appearance.usesGlassyWindow && !reduceTransparency {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 3) {
                searchHeader

                recentAppsStrip
                    .padding(.horizontal, 30)

                controlBar
                    .padding(.horizontal, 30)

                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 30)
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
                            Group {
                                if model.usesTaskSectionLayout {
                                    LazyVStack(alignment: .leading, spacing: 20) {
                                        ForEach(taskFlowRows) { row in
                                            HStack(alignment: .top, spacing: gridSpacing) {
                                                ForEach(row.segments) { segment in
                                                    taskSegment(segment)
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        ForEach(model.windowSections) { section in
                                            windowSection(section.title, windows: section.windows)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 30)
                            .padding(.top, 10)
                            .padding(.bottom, 30)
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
        .alert("AI request failed", isPresented: Binding(
            get: { model.aiErrorMessage != nil },
            set: { if !$0 { model.aiErrorMessage = nil } }
        )) {
            Button("OK") { model.aiErrorMessage = nil }
        } message: {
            Text(model.aiErrorMessage ?? "The AI provider returned an unexpected error.")
        }
    }

    private var searchHeader: some View {
        HStack {
            SearchControl(model: model, submit: openSelectedWindow)
                .frame(maxWidth: 328)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.top, 5)
    }

    /// Reserve one stable row while icon and label sizes adapt to the app count.
    private var recentAppsRowHeight: CGFloat { 88 }
    private var displayedAppWindows: [WindowItem] {
        model.isSwitcherMode ? model.recentAppWindows : (frozenAppWindows ?? model.recentAppWindows)
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
        Group {
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
                                .padding(appStripIconPadding)
                                .background {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(model.isAllWindowsAppSelected ? Color.accentColor.opacity(0.12) : .clear)
                                }
                            Text(model.isAllWindowsAppSelected && appStripWidth > 0 ? "All Windows" : " ")
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
                            isSelected: model.isAppFocused(window.id) && !model.suppressSelectionHalo,
                            cellWidth: appStripCellWidth,
                            iconSize: appStripIconSize,
                            iconPadding: appStripIconPadding,
                            stripWidth: appStripWidth,
                            itemCenterX: 4 + CGFloat(index + 1) * (appStripCellWidth + appStripSpacing) + appStripCellWidth / 2,
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
                            }
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
                ViewModeControl(model: model)
                HiddenWindowsControl(model: model)
            }

            WrappingHStack(horizontalSpacing: 12, verticalSpacing: 10) {
                GroupingControl(model: model)
                ViewModeControl(model: model)
                HiddenWindowsControl(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateGridWidth(_ width: CGFloat) {
        gridWidth = width
        model.keyboardColumnCount = gridColumnCount
    }

    private func openSelectedWindow() {
        if model.activateSelectedWindow() { close() }
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
            isSelected: model.selectedWindowID == window.id && !model.suppressSelectionHalo,
            liveThumbnail: model.liveThumbnailWindowID == window.id ? model.liveThumbnail : nil,
            isRefreshingThumbnail: model.refreshingThumbnailWindowIDs.contains(window.id),
            thumbnailCellHeight: thumbnailCellHeight,
            isHidden: model.isWindowHidden(window),
            canExcludeApp: model.canExcludeApp(window),
            taskContext: model.taskContext(for: window.id),
            select: { model.activate(window); close() },
            hoverChanged: { isHovering in model.hoverWindowInSwitcherMode(isHovering ? window.id : nil) },
            dragEntered: { model.dragHoverEntered(windowID: window.id, isAppStrip: false) },
            dragExited: { model.dragHoverExited(windowID: window.id) },
            toggleHidden: { model.toggleHidden(window) },
            excludeApp: {
                model.selectedWindowID = window.id
                model.showActionChooserForSelectedWindow()
            },
            selectTab: { tab in Task { await model.activate(tab); close() } }
        )
        .frame(width: model.thumbnailCardWidth)
        .id(window.id)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
        }
    }
}

struct CompactSwitcherView: View {
    @Bindable var model: OverviewViewModel
    @Bindable var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let opensRight: Bool
    let opensUp: Bool
    let stripWidth: CGFloat
    let maximumVisibleWindows: Int
    let openBrowser: () -> Void
    let close: () -> Void

    private let compactAppCellWidth: CGFloat = 46
    private let compactAppSpacing: CGFloat = 2
    private let compactAppHorizontalPadding: CGFloat = 10

    private var displayedApps: [WindowItem] {
        opensRight ? model.recentAppWindows : Array(model.recentAppWindows.reversed())
    }

    private let compactWindowWidth: CGFloat = 176

    private var appStripContentWidth: CGFloat {
        let itemCount = displayedApps.count + 1
        return compactAppHorizontalPadding * 2
            + CGFloat(itemCount) * compactAppCellWidth
            + CGFloat(max(0, itemCount - 1)) * compactAppSpacing
    }

    private var appStripContentOffset: CGFloat {
        opensRight ? 0 : stripWidth - appStripContentWidth
    }

    private var displayedWindows: [WindowItem] {
        let recent = Array(model.filteredWindows.prefix(maximumVisibleWindows))
        return opensRight ? recent : Array(recent.reversed())
    }

    var body: some View {
        VStack(spacing: 0) {
            if opensUp {
                compactWindows
                    .padding(.bottom, 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                appStrip
                    .padding(.bottom, 2)
            } else {
                appStrip
                    .padding(.top, 10)
                compactWindows
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            if appearance.usesGlassyWindow && !reduceTransparency {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private var appStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: compactAppSpacing) {
                    if opensRight { allWindowsButton(itemIndex: 0) }
                    ForEach(Array(displayedApps.enumerated()), id: \.element.id) { index, window in
                        compactAppButton(window, itemIndex: index + (opensRight ? 1 : 0))
                    }
                    if !opensRight { allWindowsButton(itemIndex: displayedApps.count) }
                }
                .padding(.horizontal, compactAppHorizontalPadding)
                .padding(.bottom, 5)
                .frame(minWidth: stripWidth, alignment: opensRight ? .leading : .trailing)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("compact-all-windows", anchor: opensRight ? .leading : .trailing)
                }
            }
        }
        .frame(height: 62)
    }

    private func allWindowsButton(itemIndex: Int) -> some View {
        Button(action: openBrowser) {
            compactIconLabel(
                icon: Image(systemName: "square.grid.2x2"),
                title: "All Windows",
                selected: model.isAllWindowsAppSelected,
                itemIndex: itemIndex
            )
        }
        .buttonStyle(.plain)
        .id("compact-all-windows")
        .onHover { hovering in
            guard hovering else { return }
            model.selectAllWindowsApp()
        }
    }

    private func compactAppButton(_ window: WindowItem, itemIndex: Int) -> some View {
        let selected = model.isAppFocused(window.id) && !model.suppressSelectionHalo
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
                itemIndex: itemIndex
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering else { return }
            model.hoverAppInSwitcherMode(window.id)
        }
        .dragHoverCatcher(
            onEntered: { model.dragHoverEntered(windowID: window.id, isAppStrip: true) },
            onExited: { model.dragHoverExited(windowID: window.id) }
        )
    }

    private func compactIconLabel(icon: Image, title: String, selected: Bool, itemIndex: Int) -> some View {
        let isAllWindows = title == "All Windows"
        let itemCenterX = appStripContentOffset
            + compactAppHorizontalPadding
            + CGFloat(itemIndex) * (compactAppCellWidth + compactAppSpacing)
            + compactAppCellWidth / 2
        let alignment = compactLabelAlignment(title: title, itemCenterX: itemCenterX)
        return VStack(spacing: 2) {
            icon
                .resizable()
                .scaledToFit()
                .padding(isAllWindows ? 4 : 0)
                .frame(width: 30, height: 30)
                .padding(2)
                .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                }
            Text(selected ? title : " ")
                .font(.caption2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: compactAppCellWidth, alignment: alignment)
        }
        .frame(width: compactAppCellWidth)
        .contentShape(Rectangle())
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func compactLabelAlignment(title: String, itemCenterX: CGFloat) -> Alignment {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ]
        let halfWidth = ceil((title as NSString).size(withAttributes: attributes).width) / 2
        if itemCenterX - halfWidth < 0 { return .leading }
        if itemCenterX + halfWidth > stripWidth { return .trailing }
        return .center
    }


    @ViewBuilder
    private var compactWindows: some View {
        if displayedWindows.isEmpty {
            Text("No open windows")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                ForEach(displayedWindows) { window in
                    compactWindowButton(window)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: opensRight ? .leading : .trailing)
            .animation(.easeInOut(duration: 0.07), value: model.focusedAppKey)
        }
    }

    private func compactWindowButton(_ window: WindowItem) -> some View {
        let selected = model.selectedWindowID == window.id && !model.suppressSelectionHalo
        return Button {
            model.activate(window)
            close()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                compactThumbnail(window)
                Text(window.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(window.appName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(width: compactWindowWidth, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: selected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
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
            Color.black.opacity(0.06)
            if window.thumbnailIsUsable, let thumbnail = window.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
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
            if model.focusedAppKey == nil,
               let icon = window.appIcon,
               liveThumbnail != nil || (window.thumbnailIsUsable && window.thumbnail != nil) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }
        }
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.12), value: liveThumbnail != nil)
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
    let activate: () -> Void
    let hoverChanged: (Bool) -> Void
    let dragEntered: () -> Void
    let dragExited: () -> Void

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
                .padding(iconPadding)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
                }

                Text(isSelected && stripWidth > 0 ? window.appName : " ")
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: cellWidth, alignment: labelAlignment)
            }
            .padding(.vertical, 4)
            .frame(width: cellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover(perform: hoverChanged)
        .dragHoverCatcher(onEntered: dragEntered, onExited: dragExited)
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

    private var options: [(title: String, detail: String, isDestructive: Bool)] {
        switch stage {
        case .removal:
            return [
                (L10n.string("Close Window"), L10n.format("Use %@’s normal close action. Unsaved-work prompts appear in the app.", window.appName), false),
                (L10n.string("Hide Window in Kehai"), L10n.string("Hide only this window from the browser."), false)
            ] + (canExcludeApp ? [(L10n.string("Exclude App…"), L10n.format("Choose whether to exclude every %@ window from AI or Kehai.", window.appName), false)] : [])
        case .exclusion:
            return (canExcludeFromAI ? [(L10n.string("From AI Only"), L10n.format("Keep %@ visible locally, but never send its data to AI.", window.appName), false)] : [])
                + [(L10n.string("From Kehai Entirely"), L10n.format("Remove %@ and never capture or send it.", window.appName), true)]
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
                                    .foregroundStyle(option.isDestructive ? Color.red : Color.primary)
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
    let isSelected: Bool
    let liveThumbnail: NSImage?
    let isRefreshingThumbnail: Bool
    let thumbnailCellHeight: CGFloat
    let isHidden: Bool
    let canExcludeApp: Bool
    let taskContext: String?
    let select: () -> Void
    let hoverChanged: (Bool) -> Void
    let dragEntered: () -> Void
    let dragExited: () -> Void
    let toggleHidden: () -> Void
    let excludeApp: () -> Void
    let selectTab: (SafariTab) -> Void

    private var capturedWindowCornerRadius: CGFloat {
        min(8, max(4, thumbnailCellHeight * 0.025))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
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
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .animation(.easeInOut(duration: 0.18), value: window.thumbnailRevision)
                .animation(.easeInOut(duration: 0.12), value: liveThumbnail != nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.title).font(.headline).lineLimit(1)
                    Text(window.appName).foregroundStyle(.secondary).lineLimit(1)
                    if let taskContext {
                        Text(taskContext)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                if !window.safariTabs.isEmpty { Text(L10n.format("%lld tabs", Int64(window.safariTabs.count))).font(.caption).foregroundStyle(.secondary).fixedSize() }
                if isRefreshingThumbnail, liveThumbnail == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                        .transition(.opacity)
                }
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
                    .help("Exclude this app from AI or Kehai")
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
        .background {
            if let tint {
                RoundedRectangle(cornerRadius: 16)
                    .fill(tint.opacity(0.20))
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.85) : (tint?.opacity(0.42) ?? .clear),
                    lineWidth: isSelected ? 2 : 1
                )
                .padding(1)
        }
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .onHover(perform: hoverChanged)
        .dragHoverCatcher(onEntered: dragEntered, onExited: dragExited)
        .opacity(dusty ? 0.62 : 1)
    }
}
