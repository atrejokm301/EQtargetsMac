//
//  Theme.swift
//  EQtargets (macOS)
//
//  Design tokens from docs/DESIGN.md §9. Every brand hue has up to three roles:
//  `stroke` (graph lines / nodes, ≥ 3:1), `ink` (text, ≥ 4.5:1) and `fill`
//  (background behind a label). The iOS brand values are kept exactly for
//  strokes; light-mode inks are darker shades because the brand values fail AA
//  as small text on light surfaces.
//
//  WHY dynamic NSColor providers and not an asset catalog / forced theme:
//  AppKit resolves the provider against the drawing appearance, so sheets,
//  popovers and the MenuBarExtra window all pick the right light/dark value with
//  no `\.colorScheme` plumbing (the iOS app's forced-theme bug was exactly that
//  plumbing going missing inside a sheet).
//

import SwiftUI
import AppKit

extension Color {
    /// Light/dark sRGB pair resolved by AppKit at draw time.
    static func eqt(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor.eqt(light, dark))
    }
}

extension NSColor {
    static func eqt(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex v: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Colour roles (§9.1). Names mirror the spec tokens one to one.
enum Palette {
    // Text. `secondary` is a solid colour on purpose: `secondaryLabelColor` is
    // ≈ 50% alpha and works out to ~4.0:1 on white, failing AA at 11 pt.
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color.eqt(0x5B5B62, 0xA1A1A6)
    /// Disabled / placeholder only — never information (WCAG exempts inactive UI).
    static let textTertiary = Color.eqt(0x8A8A8E, 0x6E6E73)

    // Surfaces
    static let card = Color.eqt(0xFFFFFF, 0x1E1E1E)
    static let chassis = Color.eqt(0xFFFFFF, 0x141416)
    static let separator = Color(nsColor: .separatorColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)

    // Correction (Target) — blue
    static let targetStroke = Color.eqt(0x2673C7, 0x66BFFF)
    static let targetInk = Color.eqt(0x1F61AD, 0x66BFFF)
    static let targetOnFill = Color.eqt(0xFFFFFF, 0x141416)

    // Your tuning (Fine-Tune) — orange
    static let fineStroke = Color.eqt(0xE0731F, 0xFFB359)
    static let fineInk = Color.eqt(0xA84D05, 0xFFB359)
    static let fineOnFill = Color.eqt(0x141416, 0x141416)

    // Accent
    static let accentStroke = Color.eqt(0x0073D9, 0x59B3FF)
    static let accentInk = Color.eqt(0x005FB8, 0x59B3FF)
    static let accentFill = Color.eqt(0x0073D9, 0x0073D9)

    // Bass Style — light blue secondary accent
    static let bassStroke = Color.eqt(0x3399F2, 0x8CD9FF)
    static let bassInk = Color.eqt(0x1A6BBF, 0x8CD9FF)
    static let bassFill = Color.eqt(0x1A6BBF, 0x8CD9FF)
    static let bassOnFill = Color.eqt(0xFFFFFF, 0x141416)
    static let bassMeter = Color.eqt(0x2180D9, 0x8CD9FF)

    // Status
    static let positive = Color.eqt(0x17784B, 0x66E699)
    static let warning = Color.eqt(0x8A5A00, 0xFFC24D)
    static let danger = Color.eqt(0xC42B33, 0xFF7378)
    /// Text on a solid `danger` fill: white 5.6:1 (light); dark text 7.0:1 on
    /// the light dark-mode red, where white was 2.6:1.
    static let onDanger = Color.eqt(0xFFFFFF, 0x141416)

    static func stroke(_ layer: EQLayer) -> Color { layer == .target ? targetStroke : fineStroke }
    static func ink(_ layer: EQLayer) -> Color { layer == .target ? targetInk : fineInk }
    static func onFill(_ layer: EQLayer) -> Color { layer == .target ? targetOnFill : fineOnFill }
}

/// Type scale (§9.2): max three sizes per screen. SF Pro draws chrome; SF Pro
/// Rounded carries the brand (titles, chips, figures, graph labels, meters).
enum Typo {
    static let display = Font.system(size: 22, weight: .bold, design: .rounded)
    static let title = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let value = Font.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
    static let valueBold = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let captionRounded = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()
    static let captionSemibold = Font.system(size: 11, weight: .semibold, design: .rounded)
}

/// 4 / 8 spacing grid (§9.3).
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
}

/// Motion tokens (§9.6). Nothing is linear; nothing animates while idle.
enum Motion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let select = Animation.easeInOut(duration: 0.2)
    static let spring = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let curve = Animation.easeInOut(duration: 0.25)
    static let screen = Animation.easeInOut(duration: 0.35)
    static let meter = Animation.easeOut(duration: 0.08)
    static let reduced = Animation.easeInOut(duration: 0.15)

    /// The spec's Reduce Motion rule: springs/slides/scales become 150 ms crossfades.
    static func choose(_ a: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : a
    }
}

// MARK: - Card chrome

/// Solid card: `bg.card` + 0.5 pt separator border; light-mode-only soft shadow.
/// Cards are solid on purpose — contrast stays predictable and ten live
/// materials would be a GPU cost for no information (§9.5).
struct CardBackground: ViewModifier {
    var radius: CGFloat = 12
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
    func eqtCard(radius: CGFloat = 12, padding: CGFloat = Space.s4) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }

    /// "Subtle glass" for floating things only (toast, readout chip, banner, drop veil).
    @ViewBuilder
    func floatingGlass<S: Shape>(_ shape: S, reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            self.background(shape.fill(Palette.card)).overlay(shape.stroke(Palette.separator, lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

/// Capsule with a 0.5 pt hairline border, drawn as two FILLS (border colour,
/// then the fill inset by 0.5 pt). `Capsule().strokeBorder` at 0.5 pt renders
/// its near-vertical ends as short flat "ticks" that don't follow the filled
/// capsule's curve (seen in the snapshot QA at 2×); two fills of the same shape
/// always share one geometry.
struct HairlineCapsule: View {
    var fill: Color
    var border: Color = Palette.separator
    var width: CGFloat = 0.5

    var body: some View {
        Capsule().fill(border)
            .overlay(Capsule().fill(fill).padding(width))
    }
}

/// Press feedback for custom buttons / chips: scale 0.97, 120 ms ease-out.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}
