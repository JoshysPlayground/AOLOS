import AppKit
import QuartzCore

/// Makes a notched mouse wheel scroll like a trackpad. Each notch adds distance to a target, and a display link
/// glides toward it with an ease-out curve, so fast spins accelerate and coast to a stop. The glide is delivered
/// to the web view as precise, phased scroll events, the same kind a trackpad sends, so WebKit scrolls nested
/// regions, rubber-bands at the edges and runs it on its scrolling thread.
@MainActor
final class SmoothScroller: NSObject {
    struct Tuning {
        /// Pixels per wheel notch.
        var step: CGFloat = 110
        /// Time constant of the ease-out, in seconds. Larger glides longer.
        var glide: Double = 0.11
        /// Notches closer together than this count as one spin and accelerate.
        var spinInterval: Double = 0.09
        /// Extra multiplier gained per notch within a spin, and its cap.
        var acceleration: CGFloat = 0.18
        var maxMultiplier: CGFloat = 4
    }

    var tuning = Tuning()
    var isEnabled = true

    private weak var target: NSView?
    private var remaining = CGVector.zero
    /// Sub-pixel motion not yet delivered. Scroll events carry whole points.
    private var carry = CGVector.zero
    private var multiplier: CGFloat = 1
    private var lastNotch: TimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var inGesture = false
    private var link: CADisplayLink?

    /// Takes a notched wheel event aimed at `view`. Returns false for events it leaves alone: trackpads,
    /// Magic Mouse, and anything with a phase.
    func handle(_ event: NSEvent, in view: NSView) -> Bool {
        guard isEnabled, event.type == .scrollWheel, !event.hasPreciseScrollingDeltas,
              event.phase.isEmpty, event.momentumPhase.isEmpty,
              !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option),
              view.window != nil else { return false }

        if target !== view { finish() }
        target = view

        let now = event.timestamp
        let sameDirection = remaining.dy * event.scrollingDeltaY >= 0 && remaining.dx * event.scrollingDeltaX >= 0
        if now - lastNotch < tuning.spinInterval, sameDirection {
            multiplier = min(tuning.maxMultiplier, multiplier + tuning.acceleration)
        } else {
            multiplier = 1
        }
        if !sameDirection { remaining = .zero; carry = .zero }
        lastNotch = now

        // For a notched wheel AppKit reports lines, usually 1 per notch, sometimes more when the system accelerates.
        let lines = CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        remaining.dx += Self.notches(lines.dx) * tuning.step * multiplier
        remaining.dy += Self.notches(lines.dy) * tuning.step * multiplier
        start(view)
        return true
    }

    /// The system's own wheel acceleration grows line counts with speed. Keep its direction and a dampened size,
    /// since the spin multiplier above already accelerates.
    nonisolated static func notches(_ lines: CGFloat) -> CGFloat {
        guard lines != 0 else { return 0 }
        return (lines < 0 ? -1 : 1) * min(3, max(1, abs(lines).squareRoot()))
    }

    private func start(_ view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 1.0 / 20)
        lastTick = now

        let fraction = CGFloat(1 - exp(-dt / tuning.glide))
        var move = CGVector(dx: remaining.dx * fraction, dy: remaining.dy * fraction)
        // Finish crisply instead of crawling the last few pixels.
        if abs(remaining.dx) < 1.5 { move.dx = remaining.dx }
        if abs(remaining.dy) < 1.5 { move.dy = remaining.dy }
        remaining.dx -= move.dx
        remaining.dy -= move.dy
        carry.dx += move.dx
        carry.dy += move.dy
        let whole = CGVector(dx: carry.dx.rounded(.towardZero), dy: carry.dy.rounded(.towardZero))
        carry.dx -= whole.dx
        carry.dy -= whole.dy

        if whole.dx != 0 || whole.dy != 0 {
            send(whole, phase: inGesture ? .changed : .began)
            inGesture = true
        }
        if remaining == .zero { finish() }
    }

    /// Ends the current glide. Called when it completes or when the pointer moves to another web view.
    func finish() {
        link?.invalidate()
        link = nil
        if inGesture { send(.zero, phase: .ended) }
        inGesture = false
        remaining = .zero
        carry = .zero
    }

    private func send(_ delta: CGVector, phase: CGScrollPhase) {
        guard let target, let window = target.window, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: Int32(delta.dy), wheel2: Int32(delta.dx), wheel3: 0) else { return }
        // An NSEvent made from a CGEvent has no window, and AppKit then reports the global location as its
        // locationInWindow. WebKit hit-tests with that, to pick which scrollable region moves, so place the
        // event where its window-less location equals the pointer's real position in the window.
        let p = window.mouseLocationOutsideOfEventStream
        cg.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta.dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(delta.dx))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta.dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(delta.dx))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        guard let event = NSEvent(cgEvent: cg) else { return }
        target.scrollWheel(with: event)
    }
}
