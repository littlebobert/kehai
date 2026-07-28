import AppKit
import SwiftUI

struct OverviewView: View {
    @Bindable var model: OverviewViewModel
    let usesGlassyBackground: Bool
    let close: () -> Void
    @State private var gridWidth: CGFloat = 0

    private let gridSpacing: CGFloat = 18
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: model.thumbnailCardWidth, maximum: model.thumbnailCardWidth + 80), spacing: gridSpacing)] }
    private var gridColumnCount: Int { max(1, Int((gridWidth + gridSpacing) / (model.thumbnailCardWidth + gridSpacing))) }
    private var thumbnailHeight: CGFloat { model.thumbnailCardWidth * 0.64 }

    var body: some View {
        ZStack {
            Group {
                if usesGlassyBackground {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 3) {
                controlBar
                    .padding(.horizontal, 30)
                statusRow
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
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.windowSections) { section in
                                    windowSection(section.title, windows: section.windows)
                                }
                            }
                            .padding(.horizontal, 36)
                            .padding(.top, 2)
                            .padding(.bottom, 30)
                            .animation(.easeInOut(duration: 0.14), value: model.viewMode)
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
                            guard let selectedWindowID else { return }
                            withAnimation(.easeOut(duration: 0.16)) {
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
        .task { await model.refresh() }
        .onChange(of: model.thumbnailCardWidth) {
            model.keyboardColumnCount = gridColumnCount
        }
        .animation(.easeInOut(duration: 0.16), value: model.thumbnailCardWidth)
        .alert("OpenAI request failed", isPresented: Binding(
            get: { model.openAIErrorMessage != nil },
            set: { if !$0 { model.openAIErrorMessage = nil } }
        )) {
            Button("OK") { model.openAIErrorMessage = nil }
        } message: {
            Text(model.openAIErrorMessage ?? "OpenAI returned an unexpected error.")
        }
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                GroupingControl(model: model)
                ViewModeControl(model: model)
                HiddenWindowsControl(model: model)
                Spacer(minLength: 12)
                SearchControl(model: model, submit: openSelectedWindow)
            }

            WrappingHStack(horizontalSpacing: 12, verticalSpacing: 10) {
                GroupingControl(model: model)
                ViewModeControl(model: model)
                HiddenWindowsControl(model: model)
                SearchControl(model: model, submit: openSelectedWindow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 4) {
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
    private func windowSection(_ title: String?, windows: [WindowItem], dusty: Bool = false) -> some View {
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
                            excludeApp: {
                                model.selectedWindowID = window.id
                                model.showActionChooserForSelectedWindow()
                            },
                            selectTab: { tab in Task { await model.activate(tab); close() } }
                        )
                        .id(window.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .padding(.top, 3)
            .padding(.bottom, 5)
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

    private var options: [(title: String, detail: String, isDestructive: Bool)] {
        switch stage {
        case .removal:
            return [
                (L10n.string("Close Window"), L10n.format("Use %@’s normal close action. Unsaved-work prompts appear in the app.", window.appName), false),
                (L10n.string("Hide Window in Kehai"), L10n.string("Hide only this window from the browser."), false)
            ] + (canExcludeApp ? [(L10n.string("Exclude App…"), L10n.format("Choose whether to exclude every %@ window from AI or Kehai.", window.appName), false)] : [])
        case .exclusion:
            return (canExcludeFromAI ? [(L10n.string("From AI Only"), L10n.format("Keep %@ visible locally, but never send its data to OpenAI.", window.appName), false)] : [])
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

                        if let icon = window.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(8)
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
                if !window.safariTabs.isEmpty { Text(L10n.format("%lld tabs", Int64(window.safariTabs.count))).font(.caption).foregroundStyle(.secondary) }
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
