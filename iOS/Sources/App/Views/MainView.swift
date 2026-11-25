//
//  MainView.swift
//  EQtargets (iOS)
//
//  Phone (portrait, one scrolling column, bars fixed):
//
//    +--------------------------------------+
//    | EQtargets      (status) (power) (gear)|  fixed
//    +--------------------------------------+
//    | Output card: where the sound goes    |
//    | Correction   [preset v]         (on) |
//    | Your tuning  [preset v]         (on) |
//    | Response graph                       |
//    | Band pills, type, freq, gain, Q      |
//    | Bass Style + live meter              |
//    +--------------------------------------+
//    |   (undo)  [ Hold to Compare ] (redo) |  fixed, at the thumb
//    +--------------------------------------+
//
//  Regular width (iPad): the graph and band editor take the main column; output,
//  layers and Bass Style sit in a side column. Measured on the real width rather
//  than the size class, so a narrow Split View gets the phone layout.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sceneIsActive) private var sceneIsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWide = false
    /// What to do once the open sheet has really gone: iOS refuses to present
    /// a file picker or a second sheet while one is still on screen.
    @State private var afterSheet: AfterSheet?
    #if DEBUG
    @State private var didApplyDebugLaunch = false
    #endif

    private enum Section: String {
        case output, graph, bands, bass
    }

    private enum AfterSheet {
        case chooseFile
        case paste(String?)
    }

    private static let wideThreshold: CGFloat = 700
    private static let sideColumnWidth: CGFloat = 360
    private static let phoneGraphHeight: CGFloat = 330

    var body: some View {
        @Bindable var model = model
        // Status only: `display` would also tie this body to the 4 Hz stats.
        let running = model.displayStatus == .running
        ScrollViewReader { proxy in
            Group {
                if isWide { wideLayout } else { phoneLayout }
            }
            .safeAreaBar(edge: .top) {
                HeaderBar(onStatusTap: { scroll(proxy, to: .output) },
                          onSettings: { model.showSettings = true })
            }
            .safeAreaBar(edge: .bottom) {
                BottomBar()
            }
            #if DEBUG
            .task { applyDebugLaunch(proxy) }
            #endif
        }
        .background(Palette.canvas)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideThreshold } action: { isWide = $0 }
        .overlay(alignment: .top) { toastOverlay }
        .animation(reduceMotion ? Motion.reduced : Motion.select, value: model.toast)
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.plainText, .text]) { result in
            switch result {
            case .success(let url):
                model.importFile(url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.showToast("Couldn\u{2019}t open that file.")
                }
            }
        }
        .sheet(item: $model.importPreview, onDismiss: runAfterSheet) { preview in
            ImportPreviewSheet(preview: preview, onChooseAnother: { afterSheet = .chooseFile })
        }
        .sheet(isPresented: $model.showSettings, onDismiss: runAfterSheet) {
            SettingsView(onImport: {
                afterSheet = .chooseFile
                model.showSettings = false
            }, onPaste: { text in
                afterSheet = .paste(text)
                model.showSettings = false
            })
        }
        // Status chips need meters while the screen is up and audio runs.
        .task(id: sceneIsActive && running) {
            guard sceneIsActive && running else { return }
            await model.meters.hold(.status)
        }
    }

    // MARK: Layouts

    private var phoneLayout: some View {
        ScrollView {
            VStack(spacing: Space.s3) {
                OutputCard().id(Section.output)
                LayerSelector()
                ResponseGraphView()
                    .frame(height: Self.phoneGraphHeight)
                    .id(Section.graph)
                BandEditorView().id(Section.bands)
                BassStylePanel().id(Section.bass)
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            ScrollView {
                VStack(spacing: Space.s3) {
                    ResponseGraphView()
                        .containerRelativeFrame(.vertical) { height, _ in max(360, height * 0.56) }
                        .id(Section.graph)
                    BandEditorView().id(Section.bands)
                }
                .padding(.vertical, Space.s2)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(spacing: Space.s3) {
                    OutputCard().id(Section.output)
                    LayerSelector()
                    BassStylePanel().id(Section.bass)
                }
                .padding(.vertical, Space.s2)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(width: Self.sideColumnWidth)
        }
        .padding(.horizontal, Space.s4)
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            ToastView(toast: toast)
                .padding(.top, 64)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(toast.id)
        }
    }

    // MARK: Helpers

    private func scroll(_ proxy: ScrollViewProxy, to section: Section) {
        if reduceMotion { proxy.scrollTo(section, anchor: .top) }
        else { withAnimation(Motion.screen) { proxy.scrollTo(section, anchor: .top) } }
    }

    private func runAfterSheet() {
        guard let next = afterSheet else { return }
        afterSheet = nil
        switch next {
        case .chooseFile: model.showFileImporter = true
        case .paste(let text): model.pasteAutoEQ(text: text)
        }
    }

    #if DEBUG
    private func applyDebugLaunch(_ proxy: ScrollViewProxy) {
        guard !didApplyDebugLaunch else { return }
        didApplyDebugLaunch = true
        DebugLaunch.openRequestedSheet(model)
        if let raw = DebugLaunch.scrollTarget, let section = Section(rawValue: raw) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                proxy.scrollTo(section, anchor: .top)
            }
        }
    }
    #endif
}
