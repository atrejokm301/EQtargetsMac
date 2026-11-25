//
//  GraphOverlay.swift
//  EQtargets (iOS)
//
//  Direct manipulation on the graph (DESIGN §6.2, §7.4-7.5). Only the EDITED
//  layer's nodes are drawn or grabbable, so a drag while tuning can never spoil
//  a measured correction.
//
//  Touch: drag a node for frequency and gain, pinch for Q, tap to select,
//  double-tap to reset gain. A repeat tap on a stack cycles through its bands.
//  The first tap selects immediately rather than waiting to see if a second one
//  follows. Node views draw and speak; `GraphTouchLayer` takes the touches.
//

import SwiftUI

struct GraphOverlay: View {
    let geo: GraphGeometry

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var drag: DragSession?
    @State private var pinch: PinchSession?
    @State private var lastTap: TapRecord?
    @State private var chipSize = CGSize(width: 120, height: 24)
    @State private var snapTick = 0

    struct DragSession {
        var target: GraphTarget
        var layer: EQLayer
        var start: CGPoint
        var snapped = false
    }

    struct PinchSession {
        var band: Int
        var layer: EQLayer
        var startQ: Double
    }

    struct TapRecord {
        var point: CGPoint
        var target: GraphTarget
        var time: TimeInterval
    }

    private static let dragOwner = "graph.drag"
    private static let pinchOwner = "graph.pinch"
    private static let doubleTapSeconds: TimeInterval = 0.32
    private static let doubleTapDistance: CGFloat = 24

    private var layer: EQLayer { model.dual.editingLayer }

    var body: some View {
        let l = model.layerState(layer)
        ZStack(alignment: .topLeading) {
            GraphTouchLayer(resolve: { resolve($0) }, emit: { handle($0) })
                .accessibilityIdentifier("graph.touch")
                .onDisappear {          // e.g. the iPad layout changing mid-drag
                    endDrag()
                    endPinch()
                }
                // Another layer took over the graph: this finger's drag is done.
                .onChange(of: model.dual.editingLayer) { _, now in
                    if let s = drag, s.layer != now { endDrag() }
                    if let s = pinch, s.layer != now { endPinch() }
                }

            preampHandle(l)

            ForEach(l.bands.indices, id: \.self) { i in
                let band = l.bands[i]
                BandNodeView(index: i, band: band, layer: layer,
                             selected: model.bandHighlighted && model.selectedBandIndex == i)
                    .position(geo.nodePoint(frequency: band.frequency, db: band.gain + l.preamp))
                    .accessibilityElement(children: .ignore)
                    .modifier(NodeAccessibility(index: i, band: band, layer: layer))
                    .accessibilityIdentifier("node.\(i + 1)")
            }

            readoutChip(l)
        }
        .opacity(model.isComparing ? 0.3 : 1)
        .sensoryFeedback(.selection, trigger: snapTick)
    }

    // MARK: Targets

    private func nodePoints(_ l: EQLayerState) -> [CGPoint] {
        l.bands.map { geo.nodePoint(frequency: $0.frequency, db: $0.gain + l.preamp) }
    }

    private func resolve(_ p: CGPoint) -> GraphTarget? {
        let l = model.layerState(layer)
        return GraphHitTest.target(at: p, nodes: nodePoints(l),
                                   selected: model.bandHighlighted ? model.selectedBandIndex : nil,
                                   preampTab: geo.preampTabRect(preamp: l.preamp))
    }

    // MARK: Events

    private func handle(_ event: GraphTouchEvent) {
        switch event {
        case .dragBegan(let target): beginDrag(target)
        case .dragChanged(let translation): updateDrag(translation)
        case .dragEnded: endDrag()
        case .pinchBegan(let center): beginPinch(center)
        case .pinchChanged(let scale): updatePinch(scale)
        case .pinchEnded: endPinch()
        case .tap(let point): handleTap(point)
        }
    }

    // MARK: Drag

    private func beginDrag(_ target: GraphTarget) {
        var band: Int?
        if case .band(let i) = target { band = i }
        let name = band.map { "Move Band \($0 + 1)" } ?? "Change Preamp"
        let (dragLayer, l) = model.openGraphGesture(band: band, owner: Self.dragOwner, name: name)
        let start: CGPoint
        switch target {
        case .band(let i):
            // The unclamped data point, so a node parked on the edge doesn't jump.
            start = CGPoint(x: geo.x(l.bands[i].frequency), y: geo.y(l.bands[i].gain + l.preamp))
        case .preamp:
            start = CGPoint(x: geo.plot.minX, y: geo.y(l.preamp))
        }
        drag = DragSession(target: target, layer: dragLayer, start: start)
        // Freeze the Y scale: a scale moving under the finger is disorienting.
        model.graphFrozenYMax = geo.yMax
        model.isDraggingGraph = true
    }

    private func updateDrag(_ translation: CGSize) {
        guard var s = drag else { return }
        let p = CGPoint(x: s.start.x + translation.width, y: s.start.y + translation.height)
        switch s.target {
        case .band(let i):
            let v = geo.bandValues(at: p, preamp: model.layerState(s.layer).preamp)
            model.updateBand(i, layer: s.layer) { $0.frequency = v.frequency; $0.gain = v.gain }
            if v.snapped != s.snapped {
                s.snapped = v.snapped
                if v.snapped { snapTick += 1 }
                drag = s
            }
        case .preamp:
            model.setPreamp(geo.preampValue(atY: p.y), layer: s.layer)
        }
    }

    private func endDrag() {
        guard let s = drag else { return }
        drag = nil
        switch s.target {
        case .band(let i): model.endGesture("Move Band \(i + 1)", owner: Self.dragOwner)
        case .preamp: model.endGesture("Change Preamp", owner: Self.dragOwner)
        }
        model.isDraggingGraph = false
        model.graphFrozenYMax = nil
    }

    // MARK: Pinch

    private func beginPinch(_ center: CGPoint) {
        let l = model.layerState(layer)
        let i: Int
        if model.bandHighlighted {
            i = model.selectedBandIndex
        } else {
            // Nothing selected: the band nearest the fingers.
            let points = nodePoints(l)
            i = points.indices.min {
                hypot(points[$0].x - center.x, points[$0].y - center.y)
                    < hypot(points[$1].x - center.x, points[$1].y - center.y)
            } ?? 0
        }
        let (pinchLayer, state) = model.openGraphGesture(band: i, owner: Self.pinchOwner, name: "Change Q")
        pinch = PinchSession(band: i, layer: pinchLayer, startQ: state.bands[i].q)
    }

    private func updatePinch(_ scale: CGFloat) {
        guard let s = pinch else { return }
        model.updateBand(s.band, layer: s.layer) { $0.q = GraphGeometry.pinchedQ(start: s.startQ, scale: scale) }
    }

    private func endPinch() {
        guard pinch != nil else { return }
        pinch = nil
        model.endGesture("Change Q", owner: Self.pinchOwner)
    }

    // MARK: Tap

    private func handleTap(_ p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTap, now - last.time < Self.doubleTapSeconds,
           hypot(last.point.x - p.x, last.point.y - p.y) < Self.doubleTapDistance {
            // Acts on what the first tap selected, so a stack can't surprise you.
            lastTap = nil
            switch last.target {
            case .band(let i): model.resetBandGain(i)
            case .preamp: model.autoPreamp()
            }
            return
        }

        let l = model.layerState(layer)
        let points = nodePoints(l)
        var target = resolve(p)
        // A later repeat tap on the same spot cycles through overlapping bands.
        if let last = lastTap, case .band(let previous) = last.target,
           hypot(last.point.x - p.x, last.point.y - p.y) < 6 {
            let stack = GraphHitTest.candidates(at: p, nodes: points)
            if stack.count > 1, let k = stack.firstIndex(of: previous) {
                target = .band(stack[(k + 1) % stack.count])
            }
        }

        switch target {
        case .band(let i):
            model.selectBand(i)
            lastTap = TapRecord(point: p, target: .band(i), time: now)
        case .preamp:
            lastTap = TapRecord(point: p, target: .preamp, time: now)
        case nil:
            model.selectBand(nil)
            lastTap = nil
        }
    }

    // MARK: Preamp handle (§7.4)

    private func preampHandle(_ l: EQLayerState) -> some View {
        let r = geo.preampTabRect(preamp: l.preamp)
        let active = drag?.target == .preamp
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Palette.stroke(layer).opacity(active ? 1 : 0.85))
                .frame(width: r.width, height: r.height)
            if active {
                Text("Preamp \(EQFormat.gain(l.preamp))")
                    .font(Typo.captionRounded)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1)
                    .floatingGlass(Capsule(), reduceTransparency: reduceTransparency)
                    .fixedSize()
                    .offset(x: r.width + 6)
            }
        }
        .frame(width: r.width, height: r.height, alignment: .leading)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layer == .target ? "Correction preamp" : "Tuning preamp")
        .accessibilityValue(EQFormat.gain(l.preamp))
        .accessibilityAdjustableAction { direction in
            model.commitPreamp(l.preamp + (direction == .increment ? 0.5 : -0.5))
        }
        .accessibilityAction(named: "Set automatically") { model.autoPreamp() }
        .accessibilityIdentifier("graph.preamp")
    }

    // MARK: Readout chip (§7.5)

    @ViewBuilder
    private func readoutChip(_ l: EQLayerState) -> some View {
        let active: Int? = {
            if case .band(let i)? = drag?.target { return i }
            return pinch?.band
        }()
        if let i = active {
            let b = l.bands[i]
            let text = "\(EQFormat.frequency(b.frequency)) \u{00B7} \(EQFormat.gain(b.gain)) \u{00B7} Q\u{00A0}\(EQFormat.q(b.q))"
            let node = geo.nodePoint(frequency: b.frequency, db: b.gain + l.preamp)
            // Well above the node: a finger is covering it.
            let clearance = GraphGeometry.hitRadius + Space.s2
            let aboveY = node.y - clearance - chipSize.height / 2
            let y = aboveY - chipSize.height / 2 < geo.plot.minY ? node.y + clearance + chipSize.height / 2 : aboveY
            let minX = geo.plot.minX + Space.s1 + chipSize.width / 2
            let maxX = geo.plot.maxX - Space.s1 - chipSize.width / 2
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
}

// MARK: - Node

struct BandNodeView: View {
    let index: Int
    let band: EQBand
    let layer: EQLayer
    let selected: Bool

    var body: some View {
        let stroke = Palette.stroke(layer)
        let size = GraphGeometry.nodeSize
        let shelf = band.filterType != .peak
        let width = shelf ? size + 10 : size      // a pill, so type doesn't depend on colour
        ZStack {
            if selected {
                nodeShape(shelf).stroke(Palette.textPrimary, lineWidth: 2).frame(width: width + 5, height: size + 5)
            }
            nodeShape(shelf)
                .fill(selected ? stroke : Palette.chassis)
                .frame(width: width, height: size)
            if band.isEnabled {
                nodeShape(shelf).stroke(stroke, lineWidth: 2)
                    .frame(width: width - 2, height: size - 2)
            } else {
                nodeShape(shelf).stroke(Palette.textTertiary, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .frame(width: width - 2, height: size - 2)
            }
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(selected ? Palette.onFill(layer) : (band.isEnabled ? Palette.ink(layer) : Palette.textSecondary))
                .minimumScaleFactor(0.8)
        }
        .frame(width: Space.touch, height: Space.touch)
        .allowsHitTesting(false)
    }

    private func nodeShape(_ shelf: Bool) -> AnyShape {
        shelf ? AnyShape(Capsule()) : AnyShape(Circle())
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
            .accessibilityAdjustableAction { direction in
                model.perform(name) { model.updateBand(index) { $0.gain += direction == .increment ? 0.5 : -0.5 } }
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
