//
//  SettingsView.swift
//  EQtargets (macOS)
//
//  ⌘, — native TabView + grouped Forms (DESIGN §5.7). Native sizes and
//  controls throughout; nothing custom where AppKit already has the answer.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    enum Tab: Hashable { case general, audio, corrections, driver }
    @State var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            AudioSettings().tabItem { Label("Audio", systemImage: "speaker.wave.2") }.tag(Tab.audio)
            CorrectionsSettings().tabItem { Label("Corrections", systemImage: "headphones") }.tag(Tab.corrections)
            DriverSettings().tabItem { Label("Driver", systemImage: "cpu") }.tag(Tab.driver)
        }
        .frame(width: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LoginItemToggle(title: "Open EQtargets at login")
            // The last way to open the app can't be switched off (§5.7).
            Toggle("Show in menu bar", isOn: $model.showMenuBarExtra)
                .disabled(model.showMenuBarExtra && !model.showInDock)
                .help(model.showMenuBarExtra && !model.showInDock ? "EQtargets needs at least one way to be opened." : "")
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show in Dock", isOn: $model.showInDock)
                    .disabled(model.showInDock && !model.showMenuBarExtra)
                    .help(model.showInDock && !model.showMenuBarExtra ? "EQtargets needs at least one way to be opened." : "")
                Text("When hidden, use the menu bar icon to open EQtargets.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Turn on when EQtargets opens", isOn: $model.turnOnAtLaunch)
                Text("Quitting EQtargets turns it off and gives macOS its output back.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 280)
    }
}

private struct AudioSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let d = model.display
        Form {
            VStack(alignment: .leading, spacing: 2) {
                Picker("Output", selection: Binding(get: { model.pinnedOutputUID ?? "" },
                                                    set: { model.selectOutput(uid: $0.isEmpty ? nil : $0) })) {
                    Text("Follow macOS").tag("")
                    ForEach(d.outputDevices) { dev in Text(dev.name).tag(dev.uid) }
                }
                Text("Follow macOS uses whatever you pick in Control Center or Sound settings.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Safety limiter (recommended)", isOn: $model.outputProtection)
                Text("Catches overs at \u{2212}1\u{00A0}dB so boosts never clip. Only acts when needed.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

/// Works with the main window closed (menu-bar use): Rename and Delete are
/// presented HERE, by key, and never load the preset (renaming must not change
/// the sound). Import opens the main window, which hosts the file picker and
/// the import preview.
private struct CorrectionsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: PresetKey?
    @State private var renamePrompt: NamePrompt?
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        let entries = model.presets.user(.correction)
        VStack(alignment: .leading, spacing: Space.s2) {
            Table(entries, selection: $selection) {
                TableColumn("Name") { e in Text(e.name) }
                TableColumn("Used for") { e in
                    let names = model.presets.devices(boundTo: e.key).map(\.name)
                    Text(names.isEmpty ? "\u{2014}" : names.joined(separator: ", "))
                        .foregroundStyle(names.isEmpty ? Palette.textSecondary : Palette.textPrimary)
                }
                TableColumn("Filters") { e in
                    Text("\(e.layer.bands.filter { $0.isEnabled && abs($0.gain) > 0.001 }.count)").monospacedDigit()
                }.width(56)
            }
            .contextMenu(forSelectionType: PresetKey.self) { _ in } primaryAction: { keys in
                if let k = keys.first { rename(k) }
            }
            HStack {
                Button {
                    importFile()
                } label: { Image(systemName: "plus") }
                .help("Import AutoEQ File\u{2026}")
                Button {
                    if let k = selection, let e = model.presets.entry(k, .correction), !e.isBuiltin {
                        pendingDelete = PendingDelete(kind: .correction, entry: e)
                    }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Button("Rename\u{2026}") {
                    if let k = selection { rename(k) }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Import\u{2026}") { importFile() }
            }
            Text("Double-click a name to rename.").font(.caption).foregroundStyle(Palette.textSecondary)
        }
        .padding(Space.s6)
        .frame(height: 320)
        .sheet(item: $renamePrompt) { p in NamePromptSheet(prompt: p).environment(model) }
        .alert(pendingDelete.map { "Delete \u{201C}\($0.entry.name)\u{201D}?" } ?? "",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { pending in
            Button("Delete", role: .destructive) {
                model.confirmDelete(pending)
                if selection == pending.entry.key { selection = nil }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This can\u{2019}t be undone. Devices using it go back to no correction.")
        }
    }

    /// Renames by key; the selected Correction and the sound stay as they are.
    private func rename(_ key: PresetKey) {
        guard let e = model.presets.entry(key, .correction), !e.isBuiltin else { return }
        renamePrompt = NamePrompt(kind: .correction, purpose: .rename, name: e.name, key: key)
    }

    private func importFile() {
        openWindow(id: "main")
        model.showFileImporter = true
    }
}

private struct DriverSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUninstall = false
    @State private var working = false
    @State private var message: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let d = model.display
        Form {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    StatusDot(color: d.driverInstalled ? Palette.positive : Palette.warning)
                    Text(d.driverInstalled ? "Installed \u{2014} EQtargets Audio" : "Not installed")
                }
            }
            HStack {
                Button(d.driverInstalled ? "Reinstall Driver\u{2026}" : "Install Driver\u{2026}") {
                    model.onboardingStep = .driver
                    openWindow(id: "onboarding")
                }
                Button("Uninstall Driver\u{2026}") { confirmUninstall = true }
                    .disabled(!d.driverInstalled || working)
                if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(Palette.danger) }
            DisclosureGroup("Diagnostics") {
                LabeledContent("Sample rate", value: EQFormat.sampleRate(d.stats.sampleRate))
                LabeledContent("Buffer", value: d.stats.outputBufferFrames > 0 ? "\(d.stats.outputBufferFrames)" : "\u{2014}")
                LabeledContent("Latency", value: EQFormat.latency(d.stats.latencyMs))
                LabeledContent("Clock drift", value: String(format: "%@%.1f ppm", d.stats.driftPPM < 0 ? EQFormat.minus : "+", abs(d.stats.driftPPM)))
                LabeledContent("Underruns", value: "\(d.stats.underruns)")
                LabeledContent("Resyncs", value: "\(d.stats.resyncs)")
                LabeledContent("DSP load", value: String(format: "%.0f%%", d.stats.cpuLoad * 100))
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
        .alert("Uninstall the audio driver?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                working = true
                Task {
                    do { try await model.engine.uninstallDriver(); message = nil }
                    catch { message = error.localizedDescription }
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will play sound directly to \(d.currentOutput?.name ?? "your output") again. Sound pauses for a few seconds.")
        }
    }
}
