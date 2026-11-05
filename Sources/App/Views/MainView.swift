//
//  MainView.swift
//  EQtargets (macOS)
//
//  One window, no sidebar (DESIGN §4): banner slot → layer cards → graph →
//  band editor, with Bass Style in the native trailing inspector at regular
//  width (≥ 1040 pt) and a compact row below it otherwise.
//
//  The width class is measured on the WHOLE window content (outside the
//  inspector), so opening the inspector can't flip the class and loop.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @State private var windowVisible = false
    @State private var dropHighlight = DropHighlight.none
    @State private var offeredOnboarding = false

    enum DropHighlight: Equatable { case none, valid, invalid }

    var body: some View {
        @Bindable var model = model
        let compact = model.isCompactWidth
        // Status only: `display` would also make this body depend on the 2 Hz stats.
        let running = model.displayStatus == .running
        mainColumn(compact: compact)
            .inspector(isPresented: compact ? $model.bassPanelCompact : $model.bassPanelRegular) {
                BassStylePanel()
                    .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
            }
            .toolbar { toolbarContent }
            .onGeometryChange(for: Bool.self) { $0.size.width < 1040 } action: { model.isCompactWidth = $0 }
            .frame(minWidth: 900, minHeight: 620)
            .environment(\.windowIsVisible, windowVisible)
            .background(WindowObserver { window, visible in
                model.mainWindow = window
                if windowVisible != visible { windowVisible = visible }
            })
            .onDrop(of: [.fileURL, .plainText, .utf8PlainText, .text],
                    delegate: ImportDropDelegate(model: model, highlight: $dropHighlight))
            .overlay { dropOverlay }
            .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.plainText, .text]) { result in
                if case .success(let url) = result { model.importFile(url) }
            }
            .sheet(item: $model.importPreview) { p in ImportPreviewSheet(preview: p) }
            .sheet(item: $model.namePrompt) { p in NamePromptSheet(prompt: p) }
            .alert(model.pendingDelete.map { "Delete \u{201C}\($0.entry.name)\u{201D}?" } ?? "",
                   isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
                   presenting: model.pendingDelete) { pending in
                Button("Delete", role: .destructive) { model.confirmDelete(pending) }
                Button("Cancel", role: .cancel) { model.pendingDelete = nil }
            } message: { _ in
                Text("This can\u{2019}t be undone. Devices using it go back to no correction.")
            }
            .onAppear {
                model.undoManager = undoManager
                offerOnboardingIfNeeded()
            }
            .onChange(of: undoManager) { _, um in model.undoManager = um }
            // Status chips need meters while this window is on screen and audio runs.
            .task(id: windowVisible && running) {
                guard windowVisible && running else { return }
                await model.meters.hold(.status)
            }
    }

    // MARK: Layout

    private func mainColumn(compact: Bool) -> some View {
        VStack(spacing: Space.s3) {
            banner
            LayerCardsView(compact: compact)
            ResponseGraphView()
                .frame(minHeight: 240, maxHeight: .infinity)
                .overlay(alignment: .top) { toastOverlay }
            BandEditorView(compact: compact)
            if compact && !model.bassPanelCompact {
                CompactBassRow()
            }
        }
        .padding(compact ? Space.s4 : Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    @ViewBuilder
    private var banner: some View {
        switch model.displayStatus {
        case .driverMissing:
            BannerView(tone: .warning,
                       title: "EQtargets needs its audio driver to process sound.",
                       message: "You can set up your EQ now \u{2014} it applies once the driver is installed.",
                       actions: [(title: "Install Driver\u{2026}", action: openOnboarding)])
        case .error(let message):
            BannerView(tone: .danger, title: "Something went wrong: \(message)",
                       actions: [(title: "Try Again", action: { model.setPowered(true) }),
                                 (title: "Copy Details", action: {
                                     NSPasteboard.general.clearContents()
                                     NSPasteboard.general.setString(message, forType: .string)
                                 })])
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            ToastView(toast: toast)
                .padding(.top, 44)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if dropHighlight != .none {
            let valid = dropHighlight == .valid
            let color = valid ? Palette.accentStroke : Palette.danger
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                VStack(spacing: Space.s2) {
                    Image(systemName: valid ? "square.and.arrow.down" : "nosign")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(color)
                    Text(valid ? "Drop to preview headphone correction" : "Only AutoEQ .txt files")
                        .font(Typo.title)
                        .foregroundStyle(valid ? Palette.textPrimary : Palette.danger)
                }
            }
            .padding(Space.s2)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            PowerToggle()
        }
        ToolbarItem(placement: .principal) {
            StatusPill()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            CompareButton()
            Button {
                model.showFileImporter = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import an AutoEQ ParametricEQ.txt (\u{2318}O). You can also drop the file here or paste it with \u{2318}V.")
            Button {
                model.toggleBassPanel()
            } label: {
                Label("Bass Style", systemImage: "sidebar.right")
            }
            .help("Show or hide Bass Style (\u{2325}\u{2318}B)")
        }
    }

    // MARK: Onboarding

    private func openOnboarding() {
        model.onboardingStep = .driver
        openWindow(id: "onboarding")
    }

    private func offerOnboardingIfNeeded() {
        guard !offeredOnboarding, model.shouldOfferOnboarding else { return }
        offeredOnboarding = true
        model.onboardingStep = .welcome
        openWindow(id: "onboarding")
    }
}

extension AppModel {
    /// First run without the driver: the main window opens onboarding once
    /// (§5.6). A model property so `--ui-selftest` can check it against the
    /// real engine with the driver hidden.
    var shouldOfferOnboarding: Bool {
        mode == .live && !onboardingCompleted && display.status == .driverMissing
    }

    func toggleBassPanel() {
        if isCompactWidth { bassPanelCompact.toggle() } else { bassPanelRegular.toggle() }
    }
}

// MARK: - Drop

/// Whole-window drop target for AutoEQ files or dragged text (§6.5). Image /
/// media drags are refused up front; anything else that turns out not to be
/// text is caught by `AutoEQImport` (NUL-byte check) and explained in the sheet.
struct ImportDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var highlight: MainView.DropHighlight

    private func acceptable(_ info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.image, .movie, .audio, .pdf, .archive, .application]) { return false }
        return info.hasItemsConforming(to: [.fileURL, .plainText, .utf8PlainText, .text])
    }

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        withAnimation(Motion.hover) { highlight = acceptable(info) ? .valid : .invalid }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: acceptable(info) ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        withAnimation(Motion.hover) { highlight = .none }
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(Motion.hover) { highlight = .none }
        guard acceptable(info) else { return false }
        let model = self.model
        if let p = info.itemProviders(for: [.fileURL]).first {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importFile(url) }
            }
            return true
        }
        if let p = info.itemProviders(for: [.plainText, .utf8PlainText, .text]).first {
            _ = p.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                Task { @MainActor in model.importText(text, sourceName: "Dropped text") }
            }
            return true
        }
        return false
    }
}

// MARK: - Name prompt (Save As / Rename)

struct NamePromptSheet: View {
    @State var prompt: NamePrompt
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(title).font(Typo.title)
            TextField("Name", text: $prompt.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.purpose == .rename ? "Rename" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.s6)
        .frame(width: 360)
    }

    private var title: String {
        switch (prompt.purpose, prompt.kind) {
        case (.rename, _): return "Rename"
        case (.saveAs, .correction): return "Save Correction"
        case (.saveAs, .tuning): return "Save Preset"
        }
    }

    private func save() {
        guard !prompt.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.completeNamePrompt(prompt)
        dismiss()
    }
}
