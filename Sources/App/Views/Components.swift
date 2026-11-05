//
//  Components.swift
//  EQtargets (macOS)
//
//  Small shared pieces: window visibility tracking (drives meter polling),
//  transport symbols, toast, banner, labelled slider, value field.
//

import SwiftUI
import AppKit

// MARK: - Window visibility

/// Reports the hosting NSWindow and whether it is actually on screen
/// (`isVisible` AND not fully occluded). Meter polling depends on it: a hidden,
/// minimised or covered window must cost zero wakeups (DESIGN §8.2, QA B-2).
struct WindowObserver: NSViewRepresentable {
    var onChange: (NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((NSWindow?, Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { report(); return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(forceHidden: closing) }
                })
            }
            report()
        }

        private func report(forceHidden: Bool = false) {
            let w = window
            let visible = !forceHidden && (w.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
            // Defer out of the AppKit callback so SwiftUI state isn't mutated mid-update.
            DispatchQueue.main.async { [onChange] in onChange?(w, visible) }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

// MARK: - Transport symbols (§6.7)

enum TransportSymbol {
    static func name(for device: OutputDevice?) -> String {
        guard let device else { return "speaker.slash" }
        let lower = device.name.lowercased()
        let candidate: String
        switch device.transport {
        case .builtIn: candidate = "laptopcomputer"
        case .bluetooth:
            if lower.contains("airpods max") { candidate = "airpodsmax" }
            else if lower.contains("airpods pro") { candidate = "airpodspro" }
            else if lower.contains("airpods") { candidate = "airpods" }
            else { candidate = "headphones" }
        case .usb: candidate = "hifispeaker"
        case .hdmi, .displayPort: candidate = "display"
        case .airPlay: candidate = "airplayaudio"
        case .thunderbolt: candidate = "bolt.horizontal"
        case .virtual, .aggregate, .other: candidate = "speaker.wave.2"
        }
        return exists(candidate) ? candidate : "speaker.wave.2"
    }

    static func exists(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Text(toast.text)
            .font(Typo.body)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .floatingGlass(Capsule(), reduceTransparency: reduceTransparency)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Banner

struct BannerView: View {
    enum Tone { case warning, danger }
    let tone: Tone
    let title: String
    var message: String?
    var actions: [(title: String, action: () -> Void)] = []

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(Typo.bodySemibold)
                .foregroundStyle(tone == .warning ? Palette.warning : Palette.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.bodySemibold).foregroundStyle(Palette.textPrimary)
                if let message {
                    // No fixedSize here: AppKit probes the window's minimum size with a
                    // ~zero width, and a vertically fixed wrapping text then reports a
                    // huge height that pushes the whole column off the window.
                    Text(message).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Space.s3)
            ForEach(actions.indices, id: \.self) { i in
                Button(actions[i].title, action: actions[i].action)
                    .controlSize(.regular)
            }
        }
        .padding(Space.s3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((tone == .warning ? Palette.warning : Palette.danger).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((tone == .warning ? Palette.warning : Palette.danger).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Labelled slider (Bass panel)

struct LabeledSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var help: String?
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(valueText).font(Typo.valueBold).foregroundStyle(Palette.textPrimary)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditing)
                .tint(Palette.bassStroke)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
        .help(help ?? "")
    }
}

// MARK: - Value field (TextField + Stepper)

/// Inspector number field. Shows the model value formatted with its unit;
/// while focused it edits free text, and on commit parses forgivingly
/// (`1.2k`, `−3`, `+3 dB`), clamps to the model range, and reverts with a
/// shake (or a 1 s danger border under Reduce Motion) if it can't parse.
/// Commit rules: `ValueFieldEditor`. Callers give each field an `.id` per
/// band / layer, so switching bands never carries one band's text into another.
struct ValueField: View {
    let label: String
    let value: Double
    let format: (Double) -> String
    let parse: (String) -> Double?
    let range: ClosedRange<Double>
    /// (current value, +1/−1, fine, coarse) → new value
    let step: (Double, Double, Bool, Bool) -> Double
    let width: CGFloat
    let onCommit: (Double) -> Void

    @State private var editor = ValueFieldEditor()
    @State private var invalid = false
    @State private var shake: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            TextField(label, text: Binding(get: { editor.text }, set: { editor.userEdited($0) }))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(Typo.value)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .upArrow || press.key == .downArrow else { return .ignored }
                    let dir: Double = press.key == .upArrow ? 1 : -1
                    let base = editor.stepBase(value: value, parse: parse)
                    let v = clamp(step(base, dir, press.modifiers.contains(.option), press.modifiers.contains(.shift)))
                    onCommit(v)
                    editor.reset(to: v, format: format)
                    return .handled
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Palette.danger, lineWidth: 1.5)
                        .opacity(invalid ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .offset(x: shake)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            Stepper(label,
                    onIncrement: { stepAndCommit(1) },
                    onDecrement: { stepAndCommit(-1) })
                .labelsHidden()
                .accessibilityLabel(label)
        }
        .onAppear { editor.reset(to: value, format: format) }
        // Follows the model even while focused, unless the user is typing.
        .onChange(of: value) { _, v in editor.sync(to: v, format: format) }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        // Band / layer switch (new `.id`) or the inspector going away: typing
        // in progress lands on the band it was typed for (this closure still
        // holds the old band's `onCommit`), never on the next one.
        .onDisappear { commit() }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private func stepAndCommit(_ dir: Double) {
        let v = clamp(step(value, dir, false, false))
        onCommit(v)
        editor.reset(to: v, format: format)
    }

    /// Return / blur / disappear: commits only text the user typed.
    private func commit() {
        switch editor.finish(value: value, format: format, parse: parse, range: range) {
        case .none: break
        case .commit(let v): onCommit(v)
        case .invalid: flashInvalid()
        }
    }

    private func flashInvalid() {
        if reduceMotion {
            invalid = true
            Task { try? await Task.sleep(for: .seconds(1)); invalid = false }
        } else {
            // 3 pt × 2 shake.
            Task {
                for x in [3.0, -3.0, 3.0, -3.0, 0.0] {
                    withAnimation(.easeInOut(duration: 0.05)) { shake = x }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }
}

// MARK: - Status glyph

struct StatusDot: View {
    let color: Color
    var filled = true
    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: filled ? 0 : 1.5)
            .background(Circle().fill(filled ? color : .clear))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
