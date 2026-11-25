//
//  SettingsView.swift
//  EQtargets (iOS)
//
//  General, audio, saved corrections, the honest limits, diagnostics and about.
//  A sheet because it is a whole screen of settings, not one simple choice. Row
//  actions and prompts still open compact and anchored at their control.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    /// Both close Settings first, then continue on the main screen.
    let onImport: () -> Void
    let onPaste: (String?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Turn on when EQtargets opens", isOn: $model.turnOnAtLaunch)
                        .accessibilityIdentifier("settings.turnOnAtLaunch")
                } footer: {
                    Text("When this is off, EQtargets opens with the EQ off until you turn it on.")
                }

                Section {
                    OutputRow()
                    Toggle("Safety limiter", isOn: $model.outputProtection)
                        .accessibilityIdentifier("settings.limiter")
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Recommended. Catches overs at \u{2212}1\u{00A0}dB so boosts never clip. Only acts when needed.")
                }

                CorrectionsSection(onImport: onImport, onPaste: onPaste)

                Section("What to expect") {
                    HonestLimitsList()
                        .padding(.vertical, Space.s1)
                }

                Section {
                    DisclosureGroup("Diagnostics") {
                        DiagnosticsRows()
                    }
                    .accessibilityIdentifier("settings.diagnostics")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Link(destination: URL(string: "https://autoeq.app")!) {
                        Label("Find Your Headphones on AutoEQ", systemImage: "arrow.up.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Output

private struct OutputRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let output = model.currentOutput
        HStack(spacing: Space.s3) {
            Image(systemName: TransportSymbol.name(for: output))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Output")
                Text(output?.name ?? "No output device")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text("Change it in Control Center.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.s2)
        }
    }
}

// MARK: - Corrections

/// Rename and Delete work by key and never load the preset, so managing the
/// list can't change the sound.
private struct CorrectionsSection: View {
    let onImport: () -> Void
    let onPaste: (String?) -> Void

    @Environment(AppModel.self) private var model
    @State private var renamePrompt: NamePrompt?
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        let entries = model.presets.user(.correction)
        Section {
            if entries.isEmpty {
                Text("Corrections you import or save appear here.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(entries) { entry in
                row(entry)
            }
            Button {
                onImport()
            } label: {
                Label("Import AutoEQ File\u{2026}", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("settings.import")
            PasteButton(payloadType: String.self) { strings in
                let text = strings.first
                Task { @MainActor in onPaste(text) }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
        } header: {
            Text("Corrections")
        }
    }

    private func row(_ entry: PresetEntry) -> some View {
        let devices = model.presets.devices(boundTo: entry.key)
        let filters = entry.layer.bands.filter { $0.isEnabled && abs($0.gain) > 0.001 }.count
        return HStack(spacing: Space.s2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).lineLimit(1)
                Text(detail(devices: devices.map(\.name), filters: filters))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.s2)
            Menu {
                Button { rename(entry) } label: { Label("Rename\u{2026}", systemImage: "pencil") }
                ForEach(devices, id: \.uid) { device in
                    Button { model.unbind(device.uid) } label: {
                        Label("Stop Using for \(device.name)", systemImage: "minus.circle")
                    }
                }
                Button(role: .destructive) {
                    pendingDelete = PendingDelete(kind: .correction, entry: entry)
                } label: {
                    Label("Delete\u{2026}", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Typo.bodySemibold)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.textPrimary.opacity(0.08)))
                    .frame(width: Space.touch, height: Space.touch)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Actions for \(entry.name)")
            .popover(item: Binding(get: { renamePrompt?.key == entry.key ? renamePrompt : nil },
                                   set: { if $0 == nil { renamePrompt = nil } })) { prompt in
                NamePromptView(prompt: prompt) { model.completeNamePrompt($0) }
                    .presentationCompactAdaptation(.popover)
            }
            // On the row's own control: a modifier on a Section applies per row.
            .confirmationDialog("Delete \u{201C}\(entry.name)\u{201D}?",
                                isPresented: Binding(get: { pendingDelete?.entry.key == entry.key },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.confirmDelete(PendingDelete(kind: .correction, entry: entry))
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This can\u{2019}t be undone. Devices using it go back to no correction.")
            }
        }
    }

    private func detail(devices: [String], filters: Int) -> String {
        let count = "\(filters) filter\(filters == 1 ? "" : "s")"
        return devices.isEmpty ? count : "Used for \(devices.joined(separator: ", ")) \u{00B7} \(count)"
    }

    private func rename(_ entry: PresetEntry) {
        renamePrompt = NamePrompt(kind: .correction, purpose: .rename, name: entry.name, key: entry.key)
    }
}

// MARK: - Diagnostics

/// Reads the 4 Hz stats, and only exists while the group is expanded.
private struct DiagnosticsRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.display.stats
        LabeledContent("Sample rate", value: EQFormat.sampleRate(s.sampleRate))
        LabeledContent("Buffer", value: s.outputBufferFrames > 0 ? "\(s.outputBufferFrames) frames" : "\u{2014}")
        LabeledContent("Link reserve", value: s.reserveFrames > 0 ? "\(s.reserveFrames) frames" : "\u{2014}")
        LabeledContent("Latency", value: EQFormat.latency(s.latencyMs))
        LabeledContent("Clock drift", value: String(format: "%@%.1f ppm", s.driftPPM < 0 ? EQFormat.minus : "+", abs(s.driftPPM)))
        LabeledContent("Underruns", value: "\(s.underruns)")
        LabeledContent("Resyncs", value: "\(s.resyncs)")
        LabeledContent("DSP load", value: String(format: "%.0f%%", s.cpuLoad * 100))
    }
}
