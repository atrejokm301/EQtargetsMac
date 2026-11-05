//
//  GraphOverlay.swift
//  EQtargets (macOS)
//
//  Direct manipulation on the graph (DESIGN §6.2, §7.4–7.5). Only the EDITED
//  layer's nodes are drawn or grabbable, so a drag while tuning can never spoil
//  a measured correction.
//
//  Hit-testing is done here for the whole plot rather than per node view:
//  the spec needs "selected band first, then nearest centre within 14 pt, and a
//  repeat click on a stack cycles through overlapping bands" — rules a per-view
//  hit area can't express. The node views exist for drawing and VoiceOver
//  (each is an adjustable element) and don't take hits themselves.
//
//  Modifiers are read live from NSEvent so pressing ⌥ mid-drag switches to fine
//  without a jump: movement is integrated incrementally, scaled ×0.1 under ⌥.
//

import SwiftUI
import AppKit

enum GraphTarget: Equatable {
    case band(Int)
    case preamp
}

struct GraphOverlay: View {
    let geo: GraphGeometry
    let wantedYMax: Double

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var hover: GraphTarget?
    @State private var drag: DragSession?
    @State private var lastClick: ClickRecord?
    @State private var chipSize = CGSize(width: 120, height: 22)
    @State private var scrollQ = ScrollQController()
    @State private var pinchStartQ: Double?

    struct DragSession {
        var target: GraphTarget?
        var startPoint: CGPoint          // node / handle position at drag start
        var lastTranslation: CGSize = .zero
        var virtual: CGSize = .zero      // integrated, modifier-scaled movement
        var axisLock: Axis?
        var moved = false
    }

    struct ClickRecord { var point: CGPoint; var band: Int }

    private var layer: EQLayer { model.dual.editingLayer }
    private var layerState: EQLayerState { model.layerState(layer) }

    var body: some View {
        let l = layerState
        ZStack(alignment: .topLeading) {
            // Gesture surface: the whole chassis.
            Color.clear.contentShape(Rectangle())

            preampHandle(l)

            ForEach(Array(l.bands.enumerated()), id: \.offset) { i, band in
                let p = geo.nodePoint(frequency: band.frequency, db: band.gain + l.preamp)
                BandNodeView(index: i, band: band, layer: layer,
                             selected: model.bandHighlighted && model.selectedBandIndex == i,
                             hovered: hover == .band(i))
                    .position(p)
                    .accessibilityElement(children: .ignore)
                    .modifier(NodeAccessibility(index: i, band: band, layer: layer))
            }

            readoutChip(l)
        }
        .opacity(model.isComparing ? 0.3 : 1)
        .coordinateSpace(.named("graph"))
        .gesture(dragGesture)
        .simultaneousGesture(doubleClick)
        .simultaneousGesture(pinch)
        .onContinuousHover(coordinateSpace: .named("graph")) { phase in
            switch phase {
            case .active(let p): setHover(drag == nil ? hitTest(p, cycling: false) : hover)
            case .ended: if drag == nil { setHover(nil) }
            }
        }
        .pointerStyle(hover == nil ? nil : (drag?.moved == true ? .grabActive : .grabIdle))
        .contextMenu { contextMenu }
        .onDisappear { scrollQ.stop() }
    }

    private func setHover(_ t: GraphTarget?) {
        guard t != hover else { return }
        if reduceMotion { hover = t } else { withAnimation(Motion.hover) { hover = t } }
        if case .band(let i) = t { scrollQ.start(band: i, model: model) } else { scrollQ.stop() }
    }

    // MARK: Hit-testing (§7.4 "Collisions")

    private func hitTest(_ p: CGPoint, cycling: Bool) -> GraphTarget? {
        let l = layerState
        let candidates = l.bands.indices.filter { i in
            let c = geo.nodePoint(frequency: l.bands[i].frequency, db: l.bands[i].gain + l.preamp)
            return hypot(c.x - p.x, c.y - p.y) <= GraphGeometry.hitRadius
        }
        if candidates.isEmpty {
            let tab = geo.preampTabRect(preamp: l.preamp).insetBy(dx: -7, dy: -4)   // 28 × 28
            return tab.contains(p) ? .preamp : nil
        }
        // Repeat click on the same spot cycles through overlapping bands.
        if cycling, candidates.count > 1, let last = lastClick,
           hypot(last.point.x - p.x, last.point.y - p.y) < 3,
           let k = candidates.firstIndex(of: last.band) {
            return .band(candidates[(k + 1) % candidates.count])
        }
        if model.bandHighlighted, candidates.contains(model.selectedBandIndex) {
            return .band(model.selectedBandIndex)
        }
        let nearest = candidates.min { a, b in
            let pa = geo.nodePoint(frequency: l.bands[a].frequency, db: l.bands[a].gain + l.preamp)
            let pb = geo.nodePoint(frequency: l.bands[b].frequency, db: l.bands[b].gain + l.preamp)
            return hypot(pa.x - p.x, pa.y - p.y) < hypot(pb.x - p.x, pb.y - p.y)
        }
        return nearest.map { .band($0) }
    }

    // MARK: Drag (§6.2)

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
            .onChanged { v in
                if drag == nil { beginDrag(at: v.startLocation) }
                guard var s = drag, let target = s.target else { return }
                let flags = NSEvent.modifierFlags
                let factor: CGFloat = flags.contains(.option) ? 0.1 : 1
                let dt = CGSize(width: v.translation.width - s.lastTranslation.width,
                                height: v.translation.height - s.lastTranslation.height)
                s.lastTranslation = v.translation
                s.virtual.width += dt.width * factor
                s.virtual.height += dt.height * factor
                if !s.moved, hypot(v.translation.width, v.translation.height) >= 1 {
                    s.moved = true
                    model.beginGesture()
                    // Freeze the Y scale for the whole drag: a moving scale under
                    // the pointer is disorienting (§7.2); it re-scales on mouse-up.
                    model.graphFrozenYMax = geo.yMax
                    model.isDraggingGraph = true
                }
                // ⇧: constrain to the dominant axis after 4 pt of travel.
                if flags.contains(.shift) {
                    if s.axisLock == nil, hypot(v.translation.width, v.translation.height) >= 4 {
                        s.axisLock = abs(v.translation.width) >= abs(v.translation.height) ? .horizontal : .vertical
                    }
                } else {
                    s.axisLock = nil
                }
                drag = s
                guard s.moved else { return }
                let dx = s.axisLock == .vertical ? 0 : s.virtual.width
                let dy = s.axisLock == .horizontal ? 0 : s.virtual.height
                apply(target: target, point: CGPoint(x: s.startPoint.x + dx, y: s.startPoint.y + dy),
                      fine: flags.contains(.option))
            }
            .onEnded { v in
                guard let s = drag else { return }
                drag = nil
                if s.moved {
                    switch s.target {
                    case .band(let i): model.endGesture("Move Band \(i + 1)")
                    case .preamp: model.endGesture("Change Preamp")
                    case nil: break
                    }
                    model.isDraggingGraph = false
                    model.graphFrozenYMax = nil
                } else {
                    // A click: select (with cycling), or deselect on empty plot.
                    switch hitTest(v.location, cycling: true) {
                    case .band(let i):
                        model.selectBand(i)
                        lastClick = ClickRecord(point: v.location, band: i)
                    case .preamp: break
                    case nil:
                        model.selectBand(nil)
                        lastClick = nil
                    }
                }
                setHover(hitTest(v.location, cycling: false))
            }
    }

    private func beginDrag(at p: CGPoint) {
        let l = layerState
        let target = hitTest(p, cycling: false)
        var start = p
        switch target {
        case .band(let i):
            start = geo.nodePoint(frequency: l.bands[i].frequency, db: l.bands[i].gain + l.preamp)
            // Use the unclamped data point so a node parked on the edge doesn't jump.
            start.y = geo.y(l.bands[i].gain + l.preamp)
            model.selectBand(i)
        case .preamp:
            start = CGPoint(x: geo.plot.minX, y: geo.y(l.preamp))
        case nil:
            break
        }
        drag = DragSession(target: target, startPoint: start)
    }

    private func apply(target: GraphTarget, point: CGPoint, fine: Bool) {
        let l = layerState
        switch target {
        case .band(let i):
            let f = min(max(geo.frequency(atX: point.x), EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound)
            var g = geo.db(atY: point.y) - l.preamp
            // Snap to 0 dB within ±0.3 dB (never in ⌥ fine mode).
            if !fine, abs(g) <= 0.3 { g = 0 }
            g = min(max(g, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
            model.updateBand(i) { $0.frequency = f; $0.gain = (g * 100).rounded() / 100 }
        case .preamp:
            var p = geo.db(atY: point.y)
            if !fine, abs(p) <= 0.3 { p = 0 }
            model.setPreamp((p * 10).rounded() / 10)
        }
    }

    private var doubleClick: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .named("graph"))
            .onEnded { v in
                switch hitTest(v.location, cycling: false) {
                case .band(let i): model.resetBandGain(i)
                case .preamp: model.autoPreamp()
                case nil: break
                }
            }
    }

    /// Pinch with a band selected: Q = Q_start ÷ magnification (spread = wider).
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard model.bandHighlighted else { return }
                let i = model.selectedBandIndex
                if pinchStartQ == nil { pinchStartQ = model.band(i).q; model.beginGesture() }
                let q0 = pinchStartQ ?? 1.41
                model.updateBand(i) { $0.q = q0 / max(0.05, Double(v.magnification)) }
            }
            .onEnded { _ in
                guard pinchStartQ != nil else { return }
                pinchStartQ = nil
                model.endGesture("Change Q")
            }
    }

    // MARK: Preamp handle (§7.4)

    private func preampHandle(_ l: EQLayerState) -> some View {
        let r = geo.preampTabRect(preamp: l.preamp)
        let active = hover == .preamp || drag?.target == .preamp
        return ZStack(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 6,
                                   topTrailingRadius: 6, style: .continuous)
                .fill(Palette.stroke(layer).opacity(active ? 1 : 0.85))
                .frame(width: r.width, height: r.height)
            if active {
                Text("Preamp \(EQFormat.gain(l.preamp))")
                    .font(Typo.captionRounded)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, 3)
                    .floatingGlass(Capsule(), reduceTransparency: reduceTransparency)
                    .fixedSize()
                    .offset(x: r.width + 6)
            }
        }
        .frame(width: r.width, height: r.height, alignment: .leading)
        .position(x: r.midX, y: r.midY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layer == .target ? "Correction preamp" : "Tuning preamp")
        .accessibilityValue(EQFormat.gain(l.preamp))
        .accessibilityAdjustableAction { dir in
            let d = dir == .increment ? 0.5 : -0.5
            model.commitPreamp(l.preamp + d)
        }
        .accessibilityAction(named: "Set automatically") { model.autoPreamp() }
    }

    // MARK: Readout chip (§7.5)

    @ViewBuilder
    private func readoutChip(_ l: EQLayerState) -> some View {
        let dragging: Int? = { if case .band(let i)? = drag?.target, drag?.moved == true { return i }; return nil }()
        let hovered: Int? = { if case .band(let i)? = hover { return i }; return nil }()
        if let i = dragging ?? hovered {
            let b = l.bands[i]
            let values = "\(EQFormat.frequency(b.frequency)) \u{00B7} \(EQFormat.gain(b.gain)) \u{00B7} Q\u{00A0}\(EQFormat.q(b.q))"
            let text = dragging != nil ? values : "Band \(i + 1) \u{00B7} \(b.filterType.title) \u{00B7} " + values
            let node = geo.nodePoint(frequency: b.frequency, db: b.gain + l.preamp)
            let half = GraphGeometry.nodeSize / 2
            let aboveY = node.y - half - 8 - chipSize.height / 2
            let y = aboveY - chipSize.height / 2 < geo.plot.minY ? node.y + half + 8 + chipSize.height / 2 : aboveY
            let minX = geo.plot.minX + 4 + chipSize.width / 2
            let maxX = geo.plot.maxX - 4 - chipSize.width / 2
            let x = min(max(node.x, minX), max(minX, maxX))
            Text(text)
                .font(Typo.captionRounded)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Space.s2)
                .padding(.vertical, Space.s1)
                .floatingGlass(Capsule(), reduceTransparency: reduceTransparency)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { chipSize = $0 }
                .position(x: x, y: y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Context menu (§6.2)

    @ViewBuilder
    private var contextMenu: some View {
        if case .band(let i) = hover {
            let b = model.band(i)
            Menu("Type") {
                ForEach(EQFilterType.allCases) { t in
                    Toggle(t.title, isOn: Binding(get: { b.filterType == t }, set: { _ in model.setBandType(i, t) }))
                }
            }
            Button(b.isEnabled ? "Turn Band Off" : "Turn Band On") { model.setBandEnabled(i, !b.isEnabled) }
            Button("Reset Band") { model.resetBand(i) }
            Button("Copy Band Values") {
                let s = "\(b.filterType.title) \(EQFormat.frequency(b.frequency)) \(EQFormat.gain(b.gain)) Q \(EQFormat.q(b.q))"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.replacingOccurrences(of: "\u{00A0}", with: " "), forType: .string)
            }
        } else {
            Menu("Scale") {
                ForEach(GraphScale.allCases) { s in
                    Toggle(s.title, isOn: Binding(get: { model.graphScale == s }, set: { _ in model.graphScale = s }))
                }
            }
            Toggle("Show Correction Curve", isOn: Binding(get: { model.showCorrectionCurve }, set: { model.showCorrectionCurve = $0 }))
            Toggle("Show Your Tuning Curve", isOn: Binding(get: { model.showTuningCurve }, set: { model.showTuningCurve = $0 }))
        }
    }
}

// MARK: - Node

struct BandNodeView: View {
    let index: Int
    let band: EQBand
    let layer: EQLayer
    let selected: Bool
    let hovered: Bool

    var body: some View {
        let stroke = Palette.stroke(layer)
        let size: CGFloat = hovered && !selected ? 22 : GraphGeometry.nodeSize
        let ringWidth: CGFloat = hovered ? 2.5 : 2
        let shelf = band.filterType != .peak
        ZStack {
            if hovered {
                nodeShape(shelf).fill(stroke.opacity(0.12)).frame(width: 28, height: 28)
            }
            if selected {
                nodeShape(shelf).stroke(Palette.textPrimary, lineWidth: 2).frame(width: 25, height: 25)
            }
            nodeShape(shelf)
                .fill(selected ? stroke : Palette.chassis)
                .frame(width: size, height: size)
            if band.isEnabled {
                nodeShape(shelf).stroke(stroke, lineWidth: ringWidth)
                    .frame(width: size - ringWidth, height: size - ringWidth)
            } else {
                nodeShape(shelf).stroke(Palette.textTertiary, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .frame(width: size - 2, height: size - 2)
            }
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(selected ? Palette.onFill(layer) : (band.isEnabled ? Palette.ink(layer) : Palette.textTertiary))
                .minimumScaleFactor(0.8)
        }
        .frame(width: 28, height: 28)
        .allowsHitTesting(false)
    }

    private func nodeShape(_ shelf: Bool) -> AnyShape {
        shelf ? AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)) : AnyShape(Circle())
    }
}

/// VoiceOver for one node (§12): adjustable gain plus custom actions.
struct NodeAccessibility: ViewModifier {
    let index: Int
    let band: EQBand
    let layer: EQLayer
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let name = "Move Band \(index + 1)"
        let value = String(format: "%@ %.1f decibels, Q %.2f", band.gain < 0 ? "minus" : "plus", abs(band.gain), band.q)
            + (band.isEnabled ? "" : ", off")
        content
            .accessibilityLabel("Band \(index + 1), \(band.filterType.title), \(EQFormat.spokenFrequency(band.frequency))")
            .accessibilityValue(value)
            .accessibilityAdjustableAction { dir in
                model.perform(name) { model.updateBand(index) { $0.gain += dir == .increment ? 0.5 : -0.5 } }
            }
            .accessibilityAction(named: "Raise frequency") {
                model.perform(name) { model.updateBand(index) { $0.frequency *= pow(2, 1 / 12.0) } }
            }
            .accessibilityAction(named: "Lower frequency") {
                model.perform(name) { model.updateBand(index) { $0.frequency /= pow(2, 1 / 12.0) } }
            }
            .accessibilityAction(named: "Narrower") {
                model.perform("Change Q") { model.updateBand(index) { $0.q *= pow(2, 1 / 6.0) } }
            }
            .accessibilityAction(named: "Wider") {
                model.perform("Change Q") { model.updateBand(index) { $0.q /= pow(2, 1 / 6.0) } }
            }
            .accessibilityAction(named: "Reset gain") { model.resetBandGain(index) }
            .accessibilityAction(named: band.isEnabled ? "Turn band off" : "Turn band on") {
                model.setBandEnabled(index, !band.isEnabled)
            }
            .accessibilityAction(named: "Change type to Peak") { model.setBandType(index, .peak) }
            .accessibilityAction(named: "Change type to Low Shelf") { model.setBandType(index, .lowShelf) }
            .accessibilityAction(named: "Change type to High Shelf") { model.setBandType(index, .highShelf) }
            .accessibilityAddTraits(model.bandHighlighted && model.selectedBandIndex == index ? .isSelected : [])
    }
}

// MARK: - Scroll → Q

/// Scroll over a hovered node changes its Q (§6.2): each 10 pt multiplies Q by
/// 2^(1/6) (⌥: 2^(1/24)); positive = narrower. `scrollingDeltaY` is used as
/// delivered so the user's natural-scrolling setting is respected. The monitor
/// exists ONLY while a node is hovered and returns events it doesn't handle.
@MainActor
final class ScrollQController {
    private weak var model: AppModel?
    private var band: Int?
    private var monitor: Any?
    private var endTask: Task<Void, Never>?

    func start(band: Int, model: AppModel) {
        self.band = band
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { self?.handle(e) ?? false }
            return handled ? nil : event
        }
    }

    func stop() {
        band = nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let model, let band, e.window != nil, e.window === model.mainWindow else { return false }
        var dy = Double(e.scrollingDeltaY)
        if !e.hasPreciseScrollingDeltas { dy *= 10 }      // wheel lines → points
        guard dy != 0 else { return true }
        let steps = e.modifierFlags.contains(.option) ? 24.0 : 6.0
        model.beginGesture()
        model.updateBand(band) { $0.q *= pow(2, (dy / 10) / steps) }
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.model?.endGesture("Change Q")
        }
        return true
    }
}
