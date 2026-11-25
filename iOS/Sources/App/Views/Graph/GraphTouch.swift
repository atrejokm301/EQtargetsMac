//
//  GraphTouch.swift
//  EQtargets (iOS)
//
//  One UIKit recognizer for every touch on the plot. The graph lives inside a
//  scrolling page, and a SwiftUI drag over the whole plot would make the page
//  impossible to scroll from there. This recognizer claims a touch only when it
//  means something:
//
//    finger on a node or the preamp handle, then moves   drag (the page stays put)
//    finger on empty plot, then moves                    fails, so the page scrolls
//    two fingers                                         pinch (Q)
//    finger lifts without moving                         tap
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

enum GraphTouchEvent {
    case dragBegan(GraphTarget)
    case dragChanged(translation: CGSize)
    case dragEnded
    case pinchBegan(center: CGPoint)
    case pinchChanged(scale: CGFloat)
    case pinchEnded
    case tap(CGPoint)
}

final class GraphTouchRecognizer: UIGestureRecognizer {
    /// Movement that turns a press on a node into a drag. A real tap rolls a few
    /// points, and on a phone-width graph 2 pt is already 5 % in frequency.
    static let dragThreshold: CGFloat = 8
    /// Movement that gives a press on the empty plot to the scroll view.
    static let scrollThreshold: CGFloat = 10

    var resolve: (CGPoint) -> GraphTarget? = { _ in nil }
    var emit: (GraphTouchEvent) -> Void = { _ in }

    private enum Phase {
        case idle
        case pressed(GraphTarget?, start: CGPoint)
        case dragging(start: CGPoint)
        case pinching(startDistance: CGFloat)
    }

    private var phase = Phase.idle
    private var tracked: [UITouch] = []
    /// The two fingers a pinch started with. A third finger never takes over.
    private var pinchPair: (UITouch, UITouch)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked.append(contentsOf: touches)
        switch phase {
        case .idle:
            if tracked.count >= 2 {
                beginPinch()
            } else if let touch = tracked.first {
                let p = touch.location(in: view)
                phase = .pressed(resolve(p), start: p)
            }
        case .pressed:
            beginPinch()
        case .dragging:
            // A second finger during a drag turns it into a pinch of that band.
            finishActive()
            beginPinch()
        case .pinching:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        switch phase {
        case .idle:
            break
        case .pressed(let target, let start):
            guard let touch = tracked.first else { return }
            let p = touch.location(in: view)
            let moved = hypot(p.x - start.x, p.y - start.y)
            if let target {
                guard moved >= Self.dragThreshold else { return }
                // Measured from here, so the slop itself never moves the band.
                phase = .dragging(start: p)
                emit(.dragBegan(target))
                emit(.dragChanged(translation: .zero))
                state = .began
            } else if moved >= Self.scrollThreshold {
                state = .failed
            }
        case .dragging(let start):
            guard let touch = tracked.first else { return }
            let p = touch.location(in: view)
            emit(.dragChanged(translation: CGSize(width: p.x - start.x, height: p.y - start.y)))
            state = .changed
        case .pinching(let startDistance):
            guard pinchPair != nil else { return }
            emit(.pinchChanged(scale: fingerDistance() / startDistance))
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let lifted = touches.first?.location(in: view)
        tracked.removeAll { touches.contains($0) }
        switch phase {
        case .idle:
            state = .failed
        case .pressed:
            if let lifted { emit(.tap(lifted)) }
            state = .ended
        case .dragging:
            guard tracked.isEmpty else { return }
            finishActive()
            state = .ended
        case .pinching:
            // Either original finger lifting ends it, or Q would jump to the
            // distance between two different fingers.
            guard let pair = pinchPair, touches.contains(pair.0) || touches.contains(pair.1) else { return }
            finishActive()
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked.removeAll { touches.contains($0) }
        switch phase {
        case .dragging, .pinching:
            finishActive()
            state = .cancelled
        case .idle, .pressed:
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        finishActive()      // UIKit can reset without another touch callback
        phase = .idle
        tracked = []
        pinchPair = nil
    }

    /// Reports the end of a running drag or pinch, exactly once.
    private func finishActive() {
        switch phase {
        case .dragging: emit(.dragEnded)
        case .pinching: emit(.pinchEnded)
        case .idle, .pressed: break
        }
        phase = .idle
    }

    private func beginPinch() {
        guard tracked.count >= 2 else { return }
        let distance = fingerDistance()
        guard distance > 1 else { return }
        let a = tracked[0].location(in: view), b = tracked[1].location(in: view)
        pinchPair = (tracked[0], tracked[1])
        phase = .pinching(startDistance: distance)
        emit(.pinchBegan(center: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        state = state == .possible ? .began : .changed
    }

    private func fingerDistance() -> CGFloat {
        let first = pinchPair?.0 ?? tracked[0], second = pinchPair?.1 ?? tracked[1]
        let a = first.location(in: view), b = second.location(in: view)
        return hypot(a.x - b.x, a.y - b.y)
    }
}

/// A transparent surface that owns the recognizer. A real UIView keeps normal
/// UIKit arbitration with the page's scroll view.
struct GraphTouchLayer: UIViewRepresentable {
    let resolve: (CGPoint) -> GraphTarget?
    let emit: (GraphTouchEvent) -> Void

    final class Coordinator {
        let recognizer = GraphTouchRecognizer(target: nil, action: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.addGestureRecognizer(context.coordinator.recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.recognizer.resolve = resolve
        context.coordinator.recognizer.emit = emit
    }
}
