//
//  AppModel+Actions.swift
//  EQtargets (macOS)
//
//  Everything a view, menu or shortcut can DO. Each discrete action is one undo
//  step with the copy-deck action name; continuous gestures wrap their changes
//  in beginGesture / endGesture instead.
//

import Foundation
import AppKit

extension AppModel {

    // MARK: Layers & selection

    var editingLayer: EQLayer { dual.editingLayer }

    func layerState(_ layer: EQLayer) -> EQLayerState {
        layer == .target ? dual.target : dual.fineTune
    }

    func selectLayer(_ layer: EQLayer) {
        guard dual.editingLayer != layer else { return }
        dual.editingLayer = layer
        bandHighlighted = false
    }

    var selectedBandIndex: Int { lastBand[dual.editingLayer] ?? 0 }

    func selectBand(_ index: Int?) {
        guard let index else { bandHighlighted = false; return }
        lastBand[dual.editingLayer] = min(max(index, 0), EQLayerState.bandCount - 1)
        bandHighlighted = true
    }

    func selectAdjacentBand(_ delta: Int) {
        let n = EQLayerState.bandCount
        selectBand((selectedBandIndex + delta + n) % n)
    }

    // MARK: Band edits (no undo on their own — callers wrap them)

    func band(_ index: Int, layer: EQLayer? = nil) -> EQBand {
        let l = layerState(layer ?? dual.editingLayer)
        return l.bands[min(max(index, 0), l.bands.count - 1)]
    }

    func updateBand(_ index: Int, layer: EQLayer? = nil, _ change: (inout EQBand) -> Void) {
        let which = layer ?? dual.editingLayer
        var l = layerState(which)
        guard l.bands.indices.contains(index) else { return }
        change(&l.bands[index])
        l.bands[index].sanitize()
        setLayer(l, which)
    }

    func setPreamp(_ db: Double, layer: EQLayer? = nil) {
        let which = layer ?? dual.editingLayer
        var l = layerState(which)
        guard db.isFinite else { return }
        l.preamp = min(max(db, EQLayerState.preampRange.lowerBound), EQLayerState.preampRange.upperBound)
        setLayer(l, which)
    }

    private func setLayer(_ l: EQLayerState, _ which: EQLayer) {
        if which == .target { dual.target = l } else { dual.fineTune = l }
    }

    // MARK: Band actions (undoable)

    func resetBandGain(_ index: Int? = nil) {
        let i = index ?? selectedBandIndex
        perform("Reset Band") { updateBand(i) { $0.gain = 0 } }
    }

    func resetBand(_ index: Int) {
        perform("Reset Band") { updateBand(index) { $0.reset() } }
    }

    func setBandEnabled(_ index: Int, _ on: Bool) {
        perform(on ? "Turn Band On" : "Turn Band Off") { updateBand(index) { $0.isEnabled = on } }
    }

    func setBandType(_ index: Int, _ type: EQFilterType) {
        perform("Change Band Type") { updateBand(index) { $0.filterType = type } }
    }

    /// `layer`: the layer the field belongs to (nil = the edited one). The
    /// inspector always passes it, so a commit that lands after a layer switch
    /// can't write into the other layer.
    func commitBandField(_ index: Int, layer: EQLayer? = nil, name: String, _ change: (inout EQBand) -> Void) {
        perform(name) { updateBand(index, layer: layer, change) }
    }

    func commitPreamp(_ db: Double, layer: EQLayer? = nil) {
        perform("Change Preamp") { setPreamp(db, layer: layer) }
    }

    func setLayerOn(_ layer: EQLayer, _ on: Bool) {
        let name = (layer == .target ? "Turn Correction " : "Turn Your Tuning ") + (on ? "On" : "Off")
        perform(name) {
            var l = layerState(layer)
            l.isBypassed = !on
            setLayer(l, layer)
        }
    }

    func resetTuning() {
        perform("Reset Your Tuning") {
            dual.resetFineTune()
            tuningKey = PresetStore.flatTuningKey
        }
    }

    /// −max(peak of that layer's bands, 0): the same rule `AutoEQParser` uses.
    func autoPreamp(layer: EQLayer? = nil) {
        let which = layer ?? dual.editingLayer
        let peak = FrequencyResponse.peakMagnitudeDB(bands: layerState(which).bands, sampleRate: display.graphSampleRate)
        perform("Change Preamp") { setPreamp(-max(peak, 0), layer: which) }
        showToast("Preamp set to \(EQFormat.gain(layerState(which).preamp))")
    }

    /// Peak of the Total EQ curve (both layers, both preamps), dense + band centres.
    var totalPeakDB: Double {
        let c = ResponseMath.curves(dual: dual, sampleRate: display.graphSampleRate, count: ResponseMath.maxPoints)
        return c.total.max() ?? 0
    }

    /// "Lower Preamp to {x} dB": lowers Your tuning's preamp by the Total EQ peak
    /// rounded UP to 0.5 dB, so the total never exceeds 0 dB. (DESIGN §6.7 with
    /// the design report's erratum: relative to the current tuning preamp.)
    var headroomFixPreampDB: Double? { preampFixDB(overDB: 0) }

    /// The Limiting / Clipping chip's fix. `overDB` is how far the OUTPUT went
    /// over (the limiter's gain reduction, or the clipped peak above 0 dBFS —
    /// `MeterHub.recentOverDB`). The limiter also acts on a hot master, Punch's
    /// attack boost or Bass post gain while the EQ curve itself stays ≤ 0 dB;
    /// the old curve-only rule then offered no fix at all. The cut is the larger
    /// of the two, rounded UP to 0.5 dB; nil when there is nothing to cut or no
    /// room left above −20 dB.
    func preampFixDB(overDB: Double) -> Double? {
        let need = max(totalPeakDB, overDB.isFinite ? overDB : 0, 0)
        guard need > 0.01 else { return nil }
        let cut = (need * 2).rounded(.up) / 2
        let x = max(dual.fineTune.preamp - cut, EQLayerState.preampRange.lowerBound)
        return x < dual.fineTune.preamp - 0.01 ? x : nil
    }

    func applyHeadroomFix() {
        guard let x = headroomFixPreampDB else { return }
        applyPreampFix(to: x)
    }

    /// Sets Your tuning's preamp to the value the fix button showed (one undo step).
    func applyPreampFix(to x: Double) {
        perform("Change Preamp") { setPreamp(x, layer: .fineTune) }
        showToast("Preamp set to \(EQFormat.gain(x))")
    }

    // MARK: Bass Style

    func selectBassStyle(_ style: BassStyle) {
        perform("Change Bass Style") {
            var b = bass
            b.selectStyle(style, applyRecommendedCutoff: true)
            bass = b
        }
    }

    func updateBass(_ change: (inout BassProcessorState) -> Void) {
        var b = bass
        change(&b)
        b.sanitize()
        bass = b
    }

    func restoreRecommendedCutoff() {
        guard let hz = bass.style.recommendedCutoffHz else { return }
        perform("Change Bass Style") { updateBass { $0.cutoff = hz } }
    }

    // MARK: Compare

    func toggleCompareLatch() {
        guard display.isProcessing else { return }
        compareLatched.toggle()
        announce(isComparing ? "Comparing: original sound" : "EQ on")
    }

    private func announce(_ text: String) {
        guard mode == .live else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Presets

    func presetKey(_ kind: PresetKind) -> PresetKey? { kind == .correction ? correctionKey : tuningKey }

    func currentEntry(_ kind: PresetKind) -> PresetEntry? { presets.entry(presetKey(kind), kind) }

    func isEdited(_ kind: PresetKind) -> Bool {
        guard let e = currentEntry(kind) else { return false }
        return !LayerCompare.sameSound(e.layer, layerState(kind.layer))
    }

    /// "Sennheiser HD 600 — Edited" / "None (flat)" / "Custom".
    func displayName(_ kind: PresetKind) -> String {
        guard let e = currentEntry(kind) else { return "Custom" }
        return e.displayName + (isEdited(kind) ? " \u{2014} Edited" : "")
    }

    func applyCorrection(_ entry: PresetEntry, keepEditingLayer: Bool) {
        let editing = dual.editingLayer
        dual.loadTarget(entry.layer)
        if keepEditingLayer { dual.editingLayer = editing }
        correctionKey = entry.key
    }

    func loadPreset(_ entry: PresetEntry, _ kind: PresetKind) {
        if kind == .correction {
            perform("Load Correction") { applyCorrection(entry, keepEditingLayer: true) }
        } else {
            perform("Load Tuning") {
                var l = entry.layer
                l.isBypassed = false
                dual.fineTune = l
                tuningKey = entry.key
            }
        }
    }

    func revertToSaved(_ kind: PresetKind) {
        guard let e = currentEntry(kind) else { return }
        perform("Revert to Saved") {
            if kind == .correction { applyCorrection(e, keepEditingLayer: true) }
            else { var l = e.layer; l.isBypassed = dual.fineTune.isBypassed; dual.fineTune = l }
        }
    }

    /// ⌘S: overwrite a user preset; a built-in (or none) asks for a name instead.
    func saveChanges(_ kind: PresetKind) {
        guard let e = currentEntry(kind), !e.isBuiltin else {
            namePrompt = NamePrompt(kind: kind, purpose: .saveAs, name: currentEntry(kind)?.name ?? "")
            return
        }
        presets.update(e.key, kind, layer: layerState(kind.layer))
        showToast("Saved \u{201C}\(e.name)\u{201D}")
    }

    func requestSaveAs(_ kind: PresetKind) {
        let base = currentEntry(kind).map { $0.isBuiltin ? "" : $0.name } ?? ""
        namePrompt = NamePrompt(kind: kind, purpose: .saveAs, name: base)
    }

    func requestRename(_ kind: PresetKind) {
        guard let e = currentEntry(kind), !e.isBuiltin else { return }
        namePrompt = NamePrompt(kind: kind, purpose: .rename, name: e.name)
    }

    func completeNamePrompt(_ prompt: NamePrompt) {
        // Only clear the main window's prompt if this IS it (Settings presents its own).
        if namePrompt?.id == prompt.id { namePrompt = nil }
        let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch prompt.purpose {
        case .saveAs:
            let e = presets.add(prompt.kind, name: name, layer: layerState(prompt.kind.layer))
            if prompt.kind == .correction { correctionKey = e.key } else { tuningKey = e.key }
            showToast("Saved \u{201C}\(e.name)\u{201D}")
        case .rename:
            // Settings renames a preset by key without loading it (no sound change).
            if let key = prompt.key ?? presetKey(prompt.kind) { presets.rename(key, prompt.kind, to: name) }
        }
    }

    func requestDelete(_ kind: PresetKind) {
        guard let e = currentEntry(kind), !e.isBuiltin else { return }
        pendingDelete = PendingDelete(kind: kind, entry: e)
    }

    func confirmDelete(_ pending: PendingDelete) {
        if pendingDelete?.id == pending.id { pendingDelete = nil }
        presets.delete(pending.entry.key, pending.kind)
        // The sound stays as it is; it is simply no longer a saved preset.
        if presetKey(pending.kind) == pending.entry.key {
            if pending.kind == .correction { correctionKey = nil } else { tuningKey = nil }
        }
    }

    // MARK: Device binding

    /// Read without `display` (which also reads the 2 Hz `engine.stats`).
    var currentOutput: OutputDevice? {
        if let o = displayOverride { return o.currentOutput }
        return engine.currentOutput
    }

    func boundDeviceNames(for key: PresetKey?) -> [String] {
        guard let key else { return [] }
        return presets.devices(boundTo: key).map(\.name)
    }

    func isCurrentCorrectionBound(to device: OutputDevice) -> Bool {
        guard let key = correctionKey else { return false }
        return presets.boundKey(for: device.uid) == key
    }

    /// Binds the current Correction to a device. An unsaved / edited Correction
    /// is saved first, because a binding must point at something that exists.
    func bindCurrentCorrection(to device: OutputDevice) {
        var key = correctionKey
        if key == nil || isEdited(.correction) {
            let base = currentEntry(.correction)?.name ?? device.name
            let e = presets.add(.correction, name: base, layer: dual.target)
            correctionKey = e.key
            key = e.key
        }
        guard let key else { return }
        presets.bind(deviceUID: device.uid, deviceName: device.name, to: key)
    }

    func unbind(_ deviceUID: String) { presets.unbind(deviceUID: deviceUID) }

    // MARK: Import

    func importFile(_ url: URL) {
        importPreview = ImportPreview(result: AutoEQImport.read(url: url))
    }

    func importText(_ text: String, sourceName: String) {
        importPreview = ImportPreview(result: AutoEQImport.parse(text: text, sourceName: sourceName, fileName: nil))
    }

    /// ⌘V with no text field focused. Returns false (and toasts) if the
    /// clipboard has neither a file nor AutoEQ filter text.
    @discardableResult
    func pasteAutoEQ(from pasteboard: NSPasteboard = .general) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            importFile(url)
            return true
        }
        if let text = pasteboard.string(forType: .string), AutoEQImport.containsFilters(text) {
            importText(text, sourceName: "Clipboard")
            return true
        }
        showToast("The clipboard doesn\u{2019}t contain AutoEQ filters.")
        return false
    }

    func applyImport(_ preview: ImportPreview) {
        guard case .success(let c) = preview.result else { return }
        let name = preview.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved: PresetEntry?
        perform("Import Correction") {
            // loadTarget keeps Your tuning and makes it the edited layer (§6.5).
            dual.loadTarget(c.layer)
            let e = presets.add(.correction, name: name.isEmpty ? c.suggestedName : name, layer: c.layer)
            correctionKey = e.key
            saved = e
        }
        if preview.bindToCurrentOutput, let device = display.currentOutput, let e = saved {
            presets.bind(deviceUID: device.uid, deviceName: device.name, to: e.key)
        }
        importPreview = nil
        if let e = saved { showToast("Imported \u{201C}\(e.name)\u{201D}") }
    }

    // MARK: Driver install

    func installDriver() async {
        installState = .installing
        onboardingStep = .installing
        do {
            try await engine.installDriver()
            installState = .done
            onboardingStep = .done
            onboardingCompleted = true
        } catch {
            let ns = error as NSError
            let cancelled = error is CancellationError || ns.code == NSUserCancelledError || ns.code == -128
                || ns.localizedDescription.localizedCaseInsensitiveContains("cancel")
            installState = cancelled ? .cancelled : .failed(ns.localizedDescription)
            onboardingStep = .driver      // the Driver step shows the cancelled / failed variants
        }
    }
}
