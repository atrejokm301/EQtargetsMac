//
//  Theme.swift
//  EQtargets (iOS)
//
//  The Mac app's design tokens (docs/DESIGN.md §9), resolved through dynamic
//  UIColor providers. Every brand hue has up to three roles: `stroke` (graph
//  lines and nodes, at least 3:1), `ink` (text, at least 4.5:1) and `fill`
//  (behind a label). Light-mode inks are darker because the brand values fail
//  AA as small text on light surfaces.
//
//  Type uses text styles instead of the Mac's fixed sizes, so Dynamic Type works.
//  Three sizes per screen: title (17), body (15), caption (12).
//

import SwiftUI
import UIKit

extension Color {
    /// Light/dark sRGB pair, resolved by UIKit against the current traits.
    static func eqt(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor.eqt(light, dark))
    }
}

extension UIColor {
    static func eqt(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    convenience init(hex v: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Colour roles (§9.1). Names mirror the spec tokens one to one.
enum Palette {
    // Text. `secondary` is solid on purpose: the system's secondary label is
    // translucent and falls under AA at caption size.
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color.eqt(0x5B5B62, 0xA1A1A6)
    /// Disabled / placeholder only, never information.
    static let textTertiary = Color.eqt(0x8A8A8E, 0x6E6E73)

    // Surfaces
    static let card = Color.eqt(0xFFFFFF, 0x1E1E1E)
    static let chassis = Color.eqt(0xFFFFFF, 0x141416)
    static let separator = Color(uiColor: .separator)
    static let canvas = Color(uiColor: .systemGroupedBackground)

    // Correction (Target): blue
    static let targetStroke = Color.eqt(0x2673C7, 0x66BFFF)
    static let targetInk = Color.eqt(0x1F61AD, 0x66BFFF)
    static let targetOnFill = Color.eqt(0xFFFFFF, 0x141416)

    // Your tuning (Fine-Tune): orange
    static let fineStroke = Color.eqt(0xE0731F, 0xFFB359)
    static let fineInk = Color.eqt(0xA84D05, 0xFFB359)
    static let fineOnFill = Color.eqt(0x141416, 0x141416)

    // Accent
    static let accentStroke = Color.eqt(0x0073D9, 0x59B3FF)
    static let accentInk = Color.eqt(0x005FB8, 0x59B3FF)
    static let accentFill = Color.eqt(0x0073D9, 0x0073D9)

    // Bass Style: light blue secondary accent
    static let bassStroke = Color.eqt(0x3399F2, 0x8CD9FF)
    static let bassInk = Color.eqt(0x1A6BBF, 0x8CD9FF)
    static let bassFill = Color.eqt(0x1A6BBF, 0x8CD9FF)
    static let bassOnFill = Color.eqt(0xFFFFFF, 0x141416)
    static let bassMeter = Color.eqt(0x2180D9, 0x8CD9FF)

    // Status
    static let positive = Color.eqt(0x17784B, 0x66E699)
    static let warning = Color.eqt(0x8A5A00, 0xFFC24D)
    static let danger = Color.eqt(0xC42B33, 0xFF7378)
    static let onDanger = Color.eqt(0xFFFFFF, 0x141416)

    static func stroke(_ layer: EQLayer) -> Color { layer == .target ? targetStroke : fineStroke }
    static func ink(_ layer: EQLayer) -> Color { layer == .target ? targetInk : fineInk }
    static func onFill(_ layer: EQLayer) -> Color { layer == .target ? targetOnFill : fineOnFill }
}

/// SF Pro draws chrome; SF Pro Rounded carries the brand (titles, chips, figures,
/// graph labels, meters).
enum Typo {
    static let title = Font.system(.headline, design: .rounded, weight: .semibold)
    static let body = Font.system(.subheadline)
    static let bodySemibold = Font.system(.subheadline, weight: .semibold)
    static let value = Font.system(.subheadline, design: .rounded, weight: .medium).monospacedDigit()
    static let valueBold = Font.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit()
    static let caption = Font.system(.caption)
    static let captionMedium = Font.system(.caption, weight: .medium)
    static let captionRounded = Font.system(.caption, design: .rounded, weight: .medium).monospacedDigit()
    static let captionSemibold = Font.system(.caption, design: .rounded, weight: .semibold)
}

/// 4 / 8 spacing grid (§9.3).
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
    /// Apple's minimum touch target.
    static let touch: CGFloat = 44
}

/// Motion tokens (§9.6). Nothing is linear; nothing animates while idle.
enum Motion {
    static let press = Animation.easeOut(duration: 0.12)
    static let select = Animation.easeInOut(duration: 0.2)
    static let spring = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let curve = Animation.easeInOut(duration: 0.25)
    static let screen = Animation.easeInOut(duration: 0.35)
    static let meter = Animation.easeOut(duration: 0.08)
    static let reduced = Animation.easeInOut(duration: 0.15)

    /// The spec's Reduce Motion rule: springs and slides become 150 ms crossfades.
    static func choose(_ a: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : a
    }
}

// MARK: - Card chrome

/// Solid card: `bg.card` + hairline border, soft shadow in light mode only. Solid
/// on purpose: contrast stays predictable and live materials cost GPU (§9.5).
struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = Space.s4
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.card)
                    .shadow(color: scheme == .dark ? .clear : .black.opacity(0.06), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: contrast == .increased ? 1 : 0.5)
            )
    }
}

extension View {
    func eqtCard(radius: CGFloat = 16, padding: CGFloat = Space.s4) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }

    /// "Subtle glass" for floating things only (toast, readout chip, bars).
    @ViewBuilder
    func floatingGlass<S: Shape>(_ shape: S, reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            self.background(shape.fill(Palette.card)).overlay(shape.stroke(Palette.separator, lineWidth: 0.5))
        } else {
            self.glassEffect(.regular, in: shape)
        }
    }
}

/// Capsule with a hairline border, drawn as two fills so the border and the fill
/// always share one curve.
struct HairlineCapsule: View {
    var fill: Color
    var border: Color = Palette.separator
    var width: CGFloat = 0.5

    var body: some View {
        Capsule().fill(border)
            .overlay(Capsule().fill(fill).padding(width))
    }
}

/// Press feedback for custom buttons and chips: scale 0.97, 120 ms ease-out.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
