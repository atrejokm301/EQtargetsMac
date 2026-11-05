//
//  LayerCards.swift
//  EQtargets (macOS)
//
//  "Headphone correction" (Target) and "Your tuning" (Fine-Tune) cards
//  (DESIGN §5.1/5.2, §6.1). The cards ARE the layer switch: clicking anywhere
//  that isn't a control selects that layer. Which layer is edited is said three
//  ways — tint, the "Editing" badge and the swatch line style — never by colour
//  alone.
//

import SwiftUI

struct LayerCardsView: View {
    let compact: Bool
    @Namespace private var badgeSpace

    var body: some View {
        HStack(spacing: Space.s3) {
            LayerCard(layer: .target, compact: compact, badgeSpace: badgeSpace)
            LayerCard(layer: .fineTune, compact: compact, badgeSpace: badgeSpace)
        }
    }
}

private struct LayerCard: View {
    let layer: EQLayer
    let compact: Bool
    let badgeSpace: Namespace.ID

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var kind: PresetKind { PresetKind(layer) }
    private var editing: Bool { model.dual.editingLayer == layer }
    private var state: EQLayerState { model.layerState(layer) }
    private var title: String { layer == .target ? "Headphone correction" : "Your tuning" }
    private var caption: String { layer == .target ? "Target \u{00B7} from AutoEQ" : "Fine-Tune \u{00B7} on top of the correction" }

    var body: some View {
        Group {
            if compact { compactBody } else { regularBody }
        }
        .padding(.horizontal, compact ? Space.s3 : Space.s4)
        .padding(.vertical, compact ? Space.s2 : Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { select() }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(model.displayName(kind))")
        .accessibilityAddTraits(editing ? .isSelected : [])
        .accessibilityHint("Selects this layer for editing")
        .accessibilityAction(named: "Edit \(title)") { select() }
    }

    private func select() {
        if reduceMotion { model.selectLayer(layer) }
        else { withAnimation(Motion.spring) { model.selectLayer(layer) } }
    }

    // MARK: Regular (3 rows)

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                swatch
                Text(title).font(Typo.bodySemibold).foregroundStyle(editing ? Palette.ink(layer) : Palette.textPrimary)
                if editing { editingBadge }
                Spacer(minLength: Space.s2)
                onToggle
            }
            PresetMenu(kind: kind)
            if layer == .target {
                BindingRow()
            } else {
                Text(caption).font(Typo.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        }
    }

    // MARK: Compact (one line)

    private var compactBody: some View {
        HStack(spacing: Space.s2) {
            swatch
            Text(title).font(Typo.bodySemibold).foregroundStyle(editing ? Palette.ink(layer) : Palette.textPrimary)
                .lineLimit(1).layoutPriority(1)
            // No BindingRow at this width: its items live in the Correction menu (§5.2).
            PresetMenu(kind: kind, showsBinding: layer == .target)
            if editing { editingBadge }
            Spacer(minLength: 0)
            onToggle
        }
        .frame(height: 28)
    }

    // MARK: Pieces

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

    private var editingBadge: some View {
        Label("Editing", systemImage: "pencil")
            .font(Typo.captionSemibold)
            .foregroundStyle(Palette.ink(layer))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // Outline, not a fill: the badge sits inside the already-tinted
            // editing card, and a second tint dropped the ink below 4.5:1
            // (3.75–4.27). On the card tint alone it is 4.75–6.0.
            .background(Capsule().strokeBorder(Palette.stroke(layer).opacity(0.6), lineWidth: 1))
            .matchedGeometryEffect(id: "editingBadge", in: badgeSpace)
            .fixedSize()
    }

    private var onToggle: some View {
        Toggle(isOn: Binding(get: { !state.isBypassed }, set: { model.setLayerOn(layer, $0) })) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(state.isBypassed ? "Turn \(title.lowercased()) on" : "Turn \(title.lowercased()) off to hear without it")
            .accessibilityLabel(layer == .target ? "Headphone correction on" : "Your tuning on")
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tint = Palette.stroke(layer).opacity(scheme == .dark ? 0.20 : 0.16)
        return shape.fill(Palette.card)
            .overlay(shape.fill(editing ? tint : .clear))
            .overlay(shape.strokeBorder(editing ? Palette.stroke(layer)
                                        : (hovering ? Palette.stroke(layer).opacity(0.4) : Palette.separator),
                                        lineWidth: editing ? 1 : 0.5))
            .shadow(color: scheme == .dark ? .clear : .black.opacity(0.06), radius: 2, y: 1)
    }
}

// MARK: - Preset menu

struct PresetMenu: View {
    let kind: PresetKind
    var compactLabel = false
    /// Correction card at compact width: the device-binding items (BindingRow
    /// is not shown there), DESIGN §5.2.
    var showsBinding = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.presetKey(kind)
        let entry = model.currentEntry(kind)
        let edited = model.isEdited(kind)
        let userEntry = entry.map { !$0.isBuiltin } ?? false
        Menu {
            Section(kind == .correction ? "Corrections" : "Tunings") {
                ForEach(model.presets.all(kind)) { e in
                    Toggle(e.displayName, isOn: Binding(get: { current == e.key }, set: { _ in model.loadPreset(e, kind) }))
                }
            }
            if kind == .correction {
                Divider()
                Button("Import AutoEQ File\u{2026}") { model.showFileImporter = true }
                Button("Paste from Clipboard") { model.pasteAutoEQ() }
            }
            if kind == .correction && showsBinding && BindingMenuItems.hasItems(model) {
                Divider()
                BindingMenuItems()
            }
            Divider()
            Button("Save Changes") { model.saveChanges(kind) }.disabled(!(edited && userEntry))
            Button(kind == .correction ? "Save as New Correction\u{2026}" : "Save as New Preset\u{2026}") { model.requestSaveAs(kind) }
            Button("Revert to Saved") { model.revertToSaved(kind) }.disabled(!edited)
            if kind == .tuning {
                Button("Reset to Flat") { model.resetTuning() }
            }
            Button("Rename\u{2026}") { model.requestRename(kind) }.disabled(!userEntry)
            Button("Delete\u{2026}") { model.requestDelete(kind) }.disabled(!userEntry)
            if kind == .correction {
                Divider()
                SettingsLink { Text("Manage Corrections\u{2026}") }
            }
        } label: {
            Text(model.displayName(kind))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 320, alignment: .leading)
        .help(model.displayName(kind))
        .accessibilityLabel(kind == .correction ? "Correction" : "Tuning")
        .accessibilityValue(model.displayName(kind))
    }
}

// MARK: - Device binding row (§6.6)

/// "Use for {device}" · "Stop Using for {device}" · "Use for Another Device".
/// Shared by the regular-width BindingRow and the compact Correction menu.
private struct BindingMenuItems: View {
    @Environment(AppModel.self) private var model

    /// Same condition BindingRow uses to show its menu at all.
    @MainActor static func hasItems(_ model: AppModel) -> Bool {
        model.currentOutput != nil || !model.boundDeviceNames(for: model.correctionKey).isEmpty
    }

    var body: some View {
        let output = model.currentOutput
        if let output, !model.isCurrentCorrectionBound(to: output) {
            Button("Use for \(output.name)") { model.bindCurrentCorrection(to: output) }
        }
        ForEach(model.presets.devices(boundTo: model.correctionKey ?? PresetKey(rawValue: "")), id: \.uid) { d in
            Button("Stop Using for \(d.name)") { model.unbind(d.uid) }
        }
        let others = model.display.outputDevices.filter { d in !model.isCurrentCorrectionBound(to: d) && d.uid != output?.uid }
        if !others.isEmpty {
            Menu("Use for Another Device") {
                ForEach(others) { d in Button(d.name) { model.bindCurrentCorrection(to: d) } }
            }
        }
    }
}

private struct BindingRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let output = model.currentOutput
        let bound = model.boundDeviceNames(for: model.correctionKey)
        HStack(spacing: Space.s1) {
            if output == nil && bound.isEmpty {
                Text("Target \u{00B7} from AutoEQ").font(Typo.caption).foregroundStyle(Palette.textSecondary)
            } else {
                Menu {
                    BindingMenuItems()
                } label: {
                    Label(bound.isEmpty ? "Use for \(output?.name ?? "")" : "Used for \(bound.joined(separator: ", "))",
                          systemImage: "link")
                        .font(Typo.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(bound.isEmpty ? Palette.textSecondary : Palette.targetInk)
                .help("Loads this correction automatically whenever that output is in use.")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }
}
