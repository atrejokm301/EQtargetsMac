//
//  LayerCards.swift
//  EQtargets (iOS)
//
//  "Correction" (Target) and "Your tuning" (Fine-Tune) rows (DESIGN §6.1). The
//  rows ARE the layer switch: tapping anywhere that isn't a control selects that
//  layer. Which layer is edited is said three ways (tint, the word "Editing" and
//  the swatch line style), never by colour alone.
//

import SwiftUI
import UIKit

struct LayerSelector: View {
    var body: some View {
        VStack(spacing: Space.s2) {
            LayerRow(layer: .target)
            LayerRow(layer: .fineTune)
        }
    }
}

private struct LayerRow: View {
    let layer: EQLayer

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var kind: PresetKind { PresetKind(layer) }
    private var editing: Bool { model.dual.editingLayer == layer }
    private var title: String { layer == .target ? "Correction" : "Your tuning" }
    private var spokenTitle: String { layer == .target ? "Headphone correction" : "Your tuning" }

    private var caption: String {
        var detail = layer == .target ? "Target" : "Fine-Tune"
        let bound = model.boundDeviceNames(for: model.presetKey(kind), kind)
        if !bound.isEmpty { detail = "For \(bound.joined(separator: ", "))" }
        return editing ? "Editing \u{00B7} \(detail)" : detail
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            // Stacks early: a preset name cut down to "Bass…" says nothing.
            if typeSize >= .xxLarge {
                VStack(alignment: .leading, spacing: Space.s2) {
                    HStack(spacing: Space.s2) {
                        swatch
                        titleBlock
                        Spacer(minLength: 0)
                        onSwitch
                    }
                    PresetMenu(kind: kind)
                }
            } else {
                HStack(spacing: Space.s2) {
                    swatch
                    titleBlock
                        .layoutPriority(1)
                    PresetMenu(kind: kind)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    onSwitch
                }
            }
        }
        .padding(.leading, Space.s3)
        .padding(.trailing, Space.s1)
        .padding(.vertical, Space.s1)
        .background(background(shape))
        .contentShape(shape)
        .onTapGesture { select() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(spokenTitle), \(model.displayName(kind))")
        .accessibilityAddTraits(editing ? .isSelected : [])
        .accessibilityAction(named: "Edit \(spokenTitle)") { select() }
        .accessibilityIdentifier("layer.\(kind.rawValue)")
    }

    private func select() {
        if reduceMotion { model.selectLayer(layer) }
        else { withAnimation(Motion.spring) { model.selectLayer(layer) } }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typo.bodySemibold)
                .foregroundStyle(editing ? Palette.ink(layer) : Palette.textPrimary)
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(editing ? Palette.ink(layer) : Palette.textSecondary)
        }
        .lineLimit(1)
    }

    private var swatch: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 1, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
            ctx.stroke(p, with: .color(Palette.stroke(layer)),
                       style: StrokeStyle(lineWidth: editing ? 3 : 2, lineCap: .round, dash: editing ? [] : [5, 4]))
        }
        .frame(width: 20, height: 6)
        .accessibilityHidden(true)
    }

    private var onSwitch: some View {
        let state = model.layerState(layer)
        return Toggle(isOn: Binding(get: { !state.isBypassed }, set: { model.setLayerOn(layer, $0) })) {
            Text(layer == .target ? "Headphone correction on" : "Your tuning on")
        }
        .toggleStyle(PillSwitchStyle(tint: Palette.stroke(layer)))
        .accessibilityIdentifier("layer.\(kind.rawValue).on")
    }

    private func background(_ shape: RoundedRectangle) -> some View {
        let tint = Palette.stroke(layer).opacity(scheme == .dark ? 0.20 : 0.14)
        return shape.fill(Palette.card)
            .overlay(shape.fill(editing ? tint : .clear))
            .overlay(shape.strokeBorder(editing ? Palette.stroke(layer) : Palette.separator,
                                        lineWidth: editing ? 1 : 0.5))
            .shadow(color: scheme == .dark ? .clear : .black.opacity(0.06), radius: 2, y: 1)
    }
}

// MARK: - Preset menu

/// The preset picker. A native Menu, so it opens compact and anchored at the pill.
struct PresetMenu: View {
    let kind: PresetKind
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: Space.s1) {
                Text(model.displayName(kind))
                    .font(Typo.captionSemibold)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 32)
            .background(Capsule().fill(Palette.textPrimary.opacity(0.08)))
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel(kind == .correction ? "Correction" : "Tuning")
        .accessibilityValue(model.displayName(kind))
        .accessibilityIdentifier("preset.\(kind.rawValue)")
        .popover(item: promptBinding) { prompt in
            NamePromptView(prompt: prompt) { model.completeNamePrompt($0) }
                .presentationCompactAdaptation(.popover)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible,
                            presenting: model.pendingDelete) { pending in
            Button("Delete", role: .destructive) { model.confirmDelete(pending) }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: { pending in
            Text(pending.kind == .correction
                 ? "This can\u{2019}t be undone. Devices using it go back to no correction."
                 : "This can\u{2019}t be undone. Outputs set to use it keep the tuning they have.")
        }
    }

    @ViewBuilder
    private var items: some View {
        let current = model.presetKey(kind)
        let entry = model.currentEntry(kind)
        let edited = model.isEdited(kind)
        let userEntry = entry.map { !$0.isBuiltin } ?? false

        Section(kind == .correction ? "Corrections" : "Tunings") {
            ForEach(model.presets.all(kind)) { e in
                Toggle(e.displayName, isOn: Binding(get: { current == e.key },
                                                    set: { if $0 { model.loadPreset(e, kind) } }))
            }
        }
        if kind == .correction {
            Section {
                Button { model.showFileImporter = true } label: {
                    Label("Import AutoEQ File\u{2026}", systemImage: "doc.badge.plus")
                }
                // Read only on this tap, so iOS never shows a paste banner by itself.
                Button { model.pasteAutoEQ(text: UIPasteboard.general.string) } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
            }
        }
        bindingItems
        Section {
            Button { model.saveChanges(kind) } label: {
                Label("Save Changes", systemImage: "square.and.arrow.down")
            }
            .disabled(!(edited && userEntry))
            Button { model.requestSaveAs(kind) } label: {
                Label(kind == .correction ? "Save as New Correction\u{2026}" : "Save as New Preset\u{2026}",
                      systemImage: "plus.square.on.square")
            }
            Button { model.revertToSaved(kind) } label: {
                Label("Revert to Saved", systemImage: "arrow.uturn.backward")
            }
            .disabled(!edited)
            if kind == .tuning {
                Button { model.resetTuning() } label: {
                    Label("Reset to Flat", systemImage: "arrow.counterclockwise")
                }
            }
            Button { model.requestRename(kind) } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            .disabled(!userEntry)
            Button(role: .destructive) { model.requestDelete(kind) } label: {
                Label("Delete\u{2026}", systemImage: "trash")
            }
            .disabled(!userEntry)
        }
        if kind == .correction {
            Section {
                Button { model.showSettings = true } label: {
                    Label("Manage Corrections\u{2026}", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    /// "Use for {output}" and "Stop Using for {device}" (§6.6), for a Correction
    /// or a Tuning alike: each output can load its own of both.
    @ViewBuilder
    private var bindingItems: some View {
        let output = model.currentOutput
        let bound = model.boundDevices(kind)
        if output != nil || !bound.isEmpty {
            Section("Automatic") {
                if let output, !model.isCurrentPresetBound(kind, to: output) {
                    Button { model.bindCurrentPreset(kind, to: output) } label: {
                        Label("Use for \(output.name)", systemImage: "link")
                    }
                }
                ForEach(bound, id: \.uid) { device in
                    Button { model.unbind(kind, device.uid) } label: {
                        Label("Stop Using for \(device.name)", systemImage: "minus.circle")
                    }
                }
            }
        }
    }

    private var promptBinding: Binding<NamePrompt?> {
        Binding(get: { model.namePrompt?.kind == kind ? model.namePrompt : nil },
                set: { if $0 == nil { model.namePrompt = nil } })
    }

    private var deleteTitle: String {
        model.pendingDelete.map { "Delete \u{201C}\($0.entry.name)\u{201D}?" } ?? ""
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { model.pendingDelete?.kind == kind },
                set: { if !$0 { model.pendingDelete = nil } })
    }
}

// MARK: - Name prompt (Save As / Rename)

/// Shown in a popover anchored at the control that asked for it.
struct NamePromptView: View {
    @State var prompt: NamePrompt
    let onComplete: (NamePrompt) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var isEmpty: Bool { prompt.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title).font(Typo.title).foregroundStyle(Palette.textPrimary)
            TextField("Name", text: $prompt.name)
                .font(Typo.body)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .padding(.horizontal, Space.s4)
                .frame(minHeight: Space.touch)
                .background(Capsule().fill(Palette.textPrimary.opacity(0.08)))
                .accessibilityIdentifier("namePrompt.field")
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(PillButtonStyle())
                Spacer(minLength: Space.s2)
                Button(prompt.purpose == .rename ? "Rename" : "Save", action: save)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(isEmpty)
                    .accessibilityIdentifier("namePrompt.save")
            }
        }
        .padding(Space.s4)
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private var title: String {
        switch (prompt.purpose, prompt.kind) {
        case (.rename, _): return "Rename"
        case (.saveAs, .correction): return "Save Correction"
        case (.saveAs, .tuning): return "Save Preset"
        }
    }

    private func save() {
        guard !isEmpty else { return }
        onComplete(prompt)
        dismiss()
    }
}
