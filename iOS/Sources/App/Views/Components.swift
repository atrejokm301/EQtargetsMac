//
//  Components.swift
//  EQtargets (iOS)
//
//  Small shared pieces. Controls are capsules and icon buttons are circles, each
//  with a full 44 pt touch target even when the visible shape is smaller.
//

import SwiftUI
import UIKit

// MARK: - Scene visibility

private struct SceneActiveKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the scene is frontmost. Meter polling depends on it: this app
    /// keeps running in the background, where `.task` loops are not cancelled.
    var sceneIsActive: Bool {
        get { self[SceneActiveKey.self] }
        set { self[SceneActiveKey.self] = newValue }
    }
}

// MARK: - Transport symbols

enum TransportSymbol {
    static func name(for device: OutputDevice?) -> String {
        guard let device else { return "speaker.wave.2" }
        let lower = device.name.lowercased()
        let candidates: [String]
        switch device.transport {
        case .builtIn:
            candidates = [UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"]
        case .wired:
            candidates = ["headphones"]
        case .bluetooth:
            if lower.contains("airpods max") { candidates = ["airpods.max", "airpodsmax", "headphones"] }
            else if lower.contains("airpods pro") { candidates = ["airpods.pro", "airpodspro", "headphones"] }
            else if lower.contains("airpods") { candidates = ["airpods", "headphones"] }
            else { candidates = ["headphones"] }
        case .usb:
            candidates = ["cable.connector", "hifispeaker"]
        case .hdmi:
            candidates = ["tv"]
        case .airPlay:
            candidates = ["airplayaudio"]
        case .carPlay:
            candidates = ["car.fill"]
        case .other:
            candidates = []
        }
        return candidates.first { UIImage(systemName: $0) != nil } ?? "speaker.wave.2"
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
            .padding(.horizontal, Space.s4)
            .onAppear { UIAccessibility.post(notification: .announcement, argument: toast.text) }
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

extension OutputCardContent.Tone {
    var color: Color {
        switch self {
        case .positive: return Palette.positive
        case .neutral: return Palette.textSecondary
        case .warning: return Palette.warning
        case .danger: return Palette.danger
        }
    }
}

// MARK: - Button styles

/// The app's pill. `primary` is a solid fill; `secondary` a quiet tint.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var fill: Color = Palette.accentFill
    var labelColor: Color = .white
    var fullWidth = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.bodySemibold)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(kind == .primary ? labelColor : Palette.textPrimary)
            .padding(.horizontal, Space.s4)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: 36)
            .background(Capsule().fill(kind == .primary ? fill : Palette.textPrimary.opacity(0.08)))
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Icon button: a circle, with the touch target grown to 44 pt.
struct CircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 36
    var fill: Color = Palette.textPrimary.opacity(0.08)
    var foreground: Color = Palette.textPrimary

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.bodySemibold)
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .frame(width: max(diameter, Space.touch), height: max(diameter, Space.touch))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Compact on/off capsule for places a full system switch doesn't fit. Still a
/// real toggle for VoiceOver.
struct PillSwitchStyle: ToggleStyle {
    var tint: Color = Palette.accentFill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? tint : Palette.textPrimary.opacity(0.18))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 40, height: 24)
            .frame(width: Space.touch + 4, height: Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Motion.select, value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Equal-width chips

/// Lays children out at one shared width. Its IDEAL width is widest child x
/// count, which is what `ViewThatFits` compares. Given a real width it takes
/// exactly that: reporting more would push the whole page past the screen at
/// large text sizes.
struct EqualWidthHStack: Layout {
    var spacing: CGFloat

    private func measure(_ subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (sizes.map(\.width).max() ?? 0, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let m = measure(subviews)
        let needed = m.width * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        guard let w = proposal.width, w.isFinite else { return CGSize(width: needed, height: m.height) }
        return CGSize(width: w, height: m.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let n = CGFloat(subviews.count)
        let w = (bounds.width - spacing * (n - 1)) / n
        var x = bounds.minX
        for sv in subviews {
            sv.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                     proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

// MARK: - Labelled slider

struct LabeledSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = Palette.bassStroke
    var onEditing: (Bool) -> Void = { _ in }
    /// Each movement while held, so a step another finger closed can reopen.
    var onMoved: () -> Void = {}
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s2)
                Text(valueText).font(Typo.valueBold).foregroundStyle(Palette.textPrimary)
                    .fixedSize()
            }
            Slider(value: Binding(get: { value }, set: { v in
                if isDragging { onMoved() }
                value = v
            }), in: range, onEditingChanged: { editing in
                isDragging = editing
                onEditing(editing)
            })
                .tint(tint)
                .labelsHidden()
                .frame(minHeight: Space.touch)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
                // Removed mid-drag, it never reports the end.
                .onDisappear {
                    guard isDragging else { return }
                    isDragging = false
                    onEditing(false)
                }
        }
    }
}

// MARK: - Value field

/// A number in a capsule: minus, typed entry, plus. Focusing blanks the field and
/// keeps the current value as its placeholder, so typing always starts fresh.
/// (Selecting the text on focus loses a race with UIKit's caret placement, and
/// the digits then land after the unit: "0.0 dB3.5".) On commit it parses
/// forgivingly (`1.2k`, `-3`, `+3 dB`), clamps to the model range, and reverts
/// with a shake (or a danger border under Reduce Motion) if it can't parse.
/// Commit rules live in `ValueFieldEditor`. Callers give each field an `.id` per
/// band and layer, so text never carries across bands.
struct ValueField: View {
    let label: String
    let value: Double
    let format: (Double) -> String
    let parse: (String) -> Double?
    let range: ClosedRange<Double>
    /// (current value, +1 or -1) -> new value
    let step: (Double, Double) -> Double
    var minTextWidth: CGFloat = 76
    let onCommit: (Double) -> Void

    @State private var editor = ValueFieldEditor()
    @State private var invalid = false
    @State private var shake: CGFloat = 0
    @State private var flushID = UUID()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        HStack(spacing: 0) {
            stepButton(direction: -1, symbol: "minus", name: "Decrease")
            TextField(label, text: Binding(get: { editor.text }, set: { editor.userEdited($0) }),
                      prompt: Text(format(value)))
                .labelsHidden()
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(Typo.value)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .frame(minWidth: minTextWidth, minHeight: Space.touch)
                .fixedSize(horizontal: true, vertical: false)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            stepButton(direction: 1, symbol: "plus", name: "Increase")
        }
        .background(Capsule().fill(Palette.textPrimary.opacity(0.07)))
        .overlay(
            Capsule()
                .strokeBorder(invalid ? Palette.danger : (focused ? Palette.accentStroke : .clear), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .offset(x: shake)
        .onAppear { editor.reset(to: value, format: format) }
        // Follows the model, except a focused field: its placeholder already does.
        .onChange(of: value) { _, v in
            guard !focused else {
                registerFlush()     // its commit must compare against this value
                return
            }
            editor.sync(to: v, format: format)
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                editor.reset(to: value, format: Self.blank)
                registerFlush()
            } else {
                model?.clearFieldFlush(owner: flushID)
                commit()
            }
        }
        // Band or layer switch (new `.id`) or the editor going away: typing in
        // progress lands on the band it was typed for, never on the next one.
        .onDisappear {
            model?.clearFieldFlush(owner: flushID)
            commit()
        }
    }

    /// A gesture lands the typing first. Focus goes too: a focused field ignores
    /// model updates, so it would sit on a stale number while the gesture moves it.
    private func registerFlush() {
        model?.setFieldFlush(owner: flushID) {
            commit()
            focused = false
        }
    }

    private func stepButton(direction: Double, symbol: String, name: String) -> some View {
        Button {
            // Steps from what was typed, if anything, not from the old value.
            let v = clamp(step(editor.stepBase(value: value, parse: parse), direction))
            onCommit(v)
            editor.reset(to: v, format: focused ? Self.blank : format)
        } label: {
            Image(systemName: symbol)
                .font(Typo.captionSemibold)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 40, height: Space.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(name) \(label)")
    }

    private static func blank(_: Double) -> String { "" }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    /// Return, blur or disappear: commits only text the user typed. An empty
    /// field means nothing was entered, so the value simply stays.
    private func commit() {
        guard !editor.text.isEmpty else {
            editor.reset(to: value, format: format)
            return
        }
        switch editor.finish(value: value, format: format, parse: parse, range: range) {
        case .none: break
        case .commit(let v): onCommit(v)
        case .invalid: flashInvalid()
        }
    }

    private func flashInvalid() {
        if reduceMotion {
            invalid = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                invalid = false
            }
        } else {
            Task {
                for x in [3.0, -3.0, 3.0, -3.0, 0.0] {
                    withAnimation(.easeInOut(duration: 0.05)) { shake = x }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }
}
