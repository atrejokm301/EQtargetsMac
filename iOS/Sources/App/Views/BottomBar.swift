//
//  BottomBar.swift
//  EQtargets (iOS)
//
//  Undo, Compare and Redo, pinned where a thumb rests and outside the scroll
//  view, so holding Compare can't fight the page.
//

import SwiftUI

struct BottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.s2) {
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(CircleButtonStyle(diameter: Space.touch))
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityLabel(model.canUndo ? "Undo \(model.undoActionName)" : "Undo")
            .accessibilityShowsLargeContentViewer {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("undo")

            CompareButton()

            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(CircleButtonStyle(diameter: Space.touch))
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel(model.canRedo ? "Redo \(model.redoActionName)" : "Redo")
            .accessibilityShowsLargeContentViewer {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .accessibilityIdentifier("redo")
        }
        // A fixed bar: like the system's own bars its text stops growing, and a
        // long press shows the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: 560)                       // keeps its proportions on iPad
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s1)
    }
}

// MARK: - Compare

/// Hold to peek, tap to lock (§6.4). A press shorter than 250 ms toggles the
/// latch; a longer hold is momentary. Bypass engages at press-down and drives
/// only `masterBypass`, never power or routing, so it is instant.
struct CompareButton: View {
    @Environment(AppModel.self) private var model
    @State private var pressStart: Date?
    /// Resets by itself when the system cancels the touch (Control Center, a
    /// call), which never reaches `onEnded`.
    @GestureState private var isTouching = false

    private static let tapSeconds: TimeInterval = 0.25

    var body: some View {
        // A latched Compare must always be releasable, even if the connection
        // dropped while it was on.
        let enabled = model.displayIsProcessing || model.compareLatched
        let active = model.isComparing
        HStack(spacing: 6) {
            Image(systemName: model.compareLatched ? "lock.fill" : "circle.lefthalf.filled")
                .font(Typo.captionSemibold)
            ViewThatFits(in: .horizontal) {
                Text(active ? "Original" : "Hold to Compare")
                Text(active ? "Original" : "Compare")
            }
            .font(Typo.bodySemibold)
            .lineLimit(1)
        }
        .foregroundStyle(active ? Color(uiColor: .systemBackground) : Palette.textPrimary)
        .padding(.horizontal, Space.s3)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Space.touch)
        .background(Capsule().fill(active ? Palette.textPrimary : Palette.textPrimary.opacity(0.08)))
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.4)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isTouching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard enabled, pressStart == nil else { return }
                    pressStart = Date()
                    model.compareHeld = true
                }
                .onEnded { _ in
                    guard let start = pressStart else { return }
                    pressStart = nil
                    if Date().timeIntervalSince(start) < Self.tapSeconds { model.toggleCompareLatch() }
                    model.compareHeld = false
                }
        )
        .onChange(of: isTouching) { _, touching in
            guard !touching else { return }
            // After `onEnded` had its chance: only a cancelled touch is left here.
            DispatchQueue.main.async {
                guard pressStart != nil else { return }
                pressStart = nil
                model.compareHeld = false
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: active)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityShowsLargeContentViewer {
            Label("Hold to Compare", systemImage: "circle.lefthalf.filled")
        }
        .accessibilityLabel("Compare with original")
        .accessibilityValue(model.compareLatched ? "Locked" : (active ? "On" : "Off"))
        .accessibilityHint(enabled ? "Locks the original sound on or off" : "Turn EQtargets on to compare")
        .accessibilityAction { model.toggleCompareLatch() }
        .accessibilityIdentifier("compare")
    }
}
