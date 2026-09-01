import SwiftUI

/// The Zeus orb — the crimson sentient renderer, ported from the landed prototype
/// at the canonical git ref `817b19d3d:docs/prototypes/mobile/zeus/ZeusApp.jsx`
/// (the `DeviceOrb` component, :36-295).
///
/// This is a TRANSCRIPTION of a `<canvas>` 2D renderer onto SwiftUI `Canvas`.
/// Every constant below is copied from the source, and the line it came from is
/// cited beside it, because the constants are the design — a wrong `0.06` lerp
/// factor is not a bug that compiles differently, it is an orb that breathes
/// wrong, and nothing in the type system can tell the two apart.
///
/// FIVE LAYERS, drawn in the prototype's order (:287):
///   central glow → wireframe → particles → orb points → energy arcs
///
/// PERFORMANCE IS THE REASON THIS IS M1. The prototype evaluates
/// `(latSteps+1) * (lonSteps+1)` = 35 x 53 = 1855 points per frame, sorts them
/// by depth, and issues a `createRadialGradient` per point whose displacement
/// exceeds 0.5. On the JS main thread at 60fps that is the documented risk in
/// BUILD-PLAN.md. `OrbTuning` exposes the two knobs that dominate the cost so
/// the density is a measured decision rather than an inherited one — see
/// `OrbBench` for the harness that times a frame without a display attached.
struct DeviceOrb: View {

    /// The four states the prototype's `applyMode` switch enumerates (:90-107).
    /// `rage` is present in the source with **zero producers** — it is a fully
    /// built mode nothing can enter. It is carried here so the port is faithful
    /// and so the false affordance stays visible; PROTOTYPE-AUDIT.md defect ③
    /// is the decision to bind it or cut it, and it is not this file's to make.
    enum Mode: String, CaseIterable, Sendable {
        case dormant, thinking, speaking, rage
    }

    var mode: Mode = .dormant
    /// Audio level 0...1, read only in `speaking` (:173).
    var level: Double = 0
    /// When true the renderer holds the last frame instead of advancing (:258).
    /// The prototype caches pixels via `getImageData`; here the simulation clock
    /// simply stops, which is the same observable behaviour without the readback.
    var frozen: Bool = false
    var tuning: OrbTuning = .phone

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: frozen)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                sim.advance(to: timeline.date, mode: mode, level: level, frozen: frozen)
                OrbRenderer.draw(sim.state, in: &ctx, size: size, tuning: tuning)
            }
        }
        .accessibilityLabel("Zeus orb")
        .accessibilityValue(mode.rawValue)
    }

    /// The simulation is a reference type on purpose: `Canvas`'s closure runs on
    /// every tick and the state must survive across them. A `@State` struct would
    /// be copied per evaluation and the lerps would never converge.
    @StateObject private var sim = OrbSimulation()
}

// MARK: - Tuning

/// The two knobs that dominate frame cost, exposed so density is measurable.
///
/// `verbatim` reproduces the prototype exactly. `phone` is the candidate for
/// device use — and it is a CANDIDATE, not a conclusion: which one ships is
/// decided by `OrbBench` output on hardware, not by this comment.
struct OrbTuning: Equatable, Sendable {
    /// Latitude/longitude subdivision of the point cloud. Point count is
    /// `(lat + 1) * (lon + 1)` — the sole driver of the sort and the fill loop.
    var latSteps: Int
    var lonSteps: Int
    /// Maximum number of per-tip radial gradients emitted in one frame.
    /// The prototype has no cap (:194); every point over the displacement
    /// threshold gets one. Gradients are the most expensive primitive here,
    /// so an explicit budget is the difference between a smooth orb and a
    /// slideshow. `Int.max` restores the uncapped behaviour.
    var glowBudget: Int
    /// Orbiting dust particle count (:86).
    var particleCount: Int

    /// The prototype's own numbers, uncapped. The fidelity reference.
    static let verbatim = OrbTuning(latSteps: 34, lonSteps: 52, glowBudget: .max, particleCount: 110)
    /// Reduced density for phone hardware — 18 x 28 = 532 points, 1/3.5 the work.
    static let phone = OrbTuning(latSteps: 18, lonSteps: 28, glowBudget: 48, particleCount: 64)
    /// Inline glyph scale — a 24pt orb cannot resolve 1855 points, so drawing
    /// them is pure cost. Used by the composer and transcript avatars.
    static let glyph = OrbTuning(latSteps: 10, lonSteps: 16, glowBudget: 10, particleCount: 0)

    var pointCount: Int { (latSteps + 1) * (lonSteps + 1) }
}

// MARK: - Simulation

/// Mode targets, transcribed from `applyMode` (:88-108). Four fields per mode,
/// four modes — a struct rather than a switch so the table is readable as a
/// table and a missing case is a compile error rather than a silent no-op.
struct OrbModeTargets: Equatable, Sendable {
    var spikeIntensity: Double
    var glow: Double
    var pulseSpeed: Double
    var rotation: Double

    static func targets(for mode: DeviceOrb.Mode) -> OrbModeTargets {
        switch mode {
        case .dormant:  return .init(spikeIntensity: 0.28, glow: 0.38, pulseSpeed: 0.8,  rotation: 0.22)
        case .speaking: return .init(spikeIntensity: 0.62, glow: 0.90, pulseSpeed: 3.2,  rotation: 0.55)
        case .thinking: return .init(spikeIntensity: 0.30, glow: 0.60, pulseSpeed: 0.45, rotation: 0.13)
        case .rage:     return .init(spikeIntensity: 1.00, glow: 1.00, pulseSpeed: 5.0,  rotation: 1.20)
        }
    }
}

/// The mutable per-frame state of the orb — the prototype's `state` object (:66).
struct OrbState: Sendable {
    var mode: DeviceOrb.Mode = .dormant
    var level: Double = 0
    var time: Double = 0
    var spikeIntensity: Double = 0.35
    var glow: Double = 0.4
    var pulseSpeed: Double = 1
    var rotation: Double = 0.3
    var speakWave: Double = 0
    var breathPhase: Double = 0
    var targets: OrbModeTargets = .targets(for: .dormant)
    var particles: [OrbParticle] = []
}

/// One orbiting dust mote — `makeParticle` (:75-85).
struct OrbParticle: Sendable {
    var y: Double
    var size: Double
    var alpha: Double
    var speed: Double
    var orbitAngle: Double
    var orbitDist: Double
    var phase: Double
}

final class OrbSimulation: ObservableObject {
    private(set) var state = OrbState()
    private var lastDate: Date?
    private var seeded = false

    /// Advance the simulation to `date`.
    ///
    /// The prototype hardcodes `dt = 0.016` (:271) — it advances one fixed step
    /// per `requestAnimationFrame` regardless of how long the frame took. That
    /// is deliberate there and preserved here: the lerp factors (0.06, 0.05, 0.1)
    /// are per-STEP, not per-second, so feeding a real elapsed time would change
    /// every transition rate. The clock is used only to detect that a tick
    /// happened, never to scale it.
    func advance(to date: Date, mode: DeviceOrb.Mode, level: Double, frozen: Bool) {
        if !seeded {
            state.time = Double.random(in: 0..<100)   // :67
            state.particles = Self.makeParticles(OrbTuning.verbatim.particleCount)
            state.targets = .targets(for: mode)
            state.mode = mode
            seeded = true
        }
        guard !frozen else { lastDate = date; return }
        guard lastDate != date else { return }
        lastDate = date

        if state.mode != mode {                        // :270
            state.mode = mode
            state.targets = .targets(for: mode)
        }
        state.level = level

        let dt = 0.016                                 // :271
        state.time += dt * state.pulseSpeed
        state.breathPhase += dt * state.pulseSpeed * 1.5
        state.spikeIntensity = Self.lerp(state.spikeIntensity, state.targets.spikeIntensity, 0.06)
        state.glow           = Self.lerp(state.glow,           state.targets.glow,           0.06)
        state.pulseSpeed     = Self.lerp(state.pulseSpeed,     state.targets.pulseSpeed,     0.05)
        state.rotation       = Self.lerp(state.rotation,       state.targets.rotation,       0.05)
        if mode == .speaking {                         // :278-282
            state.speakWave = Self.lerp(state.speakWave, 0.6 + sin(state.time * 8) * 0.4, 0.1)
        } else {
            state.speakWave = Self.lerp(state.speakWave, 0, 0.05)
        }

        let rotSpeed = state.rotation * 0.5            // :208
        for i in state.particles.indices {
            state.particles[i].orbitAngle += state.particles[i].speed * rotSpeed
        }
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func makeParticles(_ count: Int, baseRadius: Double = 80) -> [OrbParticle] {
        (0..<count).map { _ in
            let angle = Double.random(in: 0..<(2 * .pi))
            let dist = baseRadius * 1.4 + Double.random(in: 0..<1) * baseRadius * 2.5
            return OrbParticle(
                y: sin(angle) * dist,
                size: Double.random(in: 0..<1) * 2.5 + 0.5,
                alpha: Double.random(in: 0..<1) * 0.5 + 0.1,
                speed: Double.random(in: 0..<1) * 0.003 + 0.001,
                orbitAngle: angle,
                orbitDist: dist,
                phase: Double.random(in: 0..<(2 * .pi))
            )
        }
    }
}

// MARK: - Palette
//
// The `C` object (:26-34). These are the Igneous Precision crimson ramps and
// they are the ONLY thing that differs between the Zeus orb and the Optimus
// orb — same renderer, same constants, different palette. Keeping them in one
// namespace is what makes the second app a palette swap rather than a fork.

enum OrbPalette {
    /// `C.point` (:27) — the per-point body colour, ramped by displacement.
    static func point(_ i: Double, alpha: Double) -> Color {
        Color(.sRGB,
              red:   (185 + i * 70).rounded(.down) / 255,
              green: (45 + i * 150).rounded(.down) / 255,
              blue:  (15 + i * 55).rounded(.down) / 255,
              opacity: alpha)
    }
    /// `C.tipGlowInner` (:28).
    static func tipGlowInner(_ i: Double, _ a: Double) -> Color {
        Color(.sRGB, red: 1.0, green: (80 + i * 90).rounded(.down) / 255, blue: 40.0 / 255, opacity: a)
    }
    /// `C.tipGlowOuter` (:29) — fully transparent, the gradient's outer stop.
    static let tipGlowOuter = Color(.sRGB, red: 1.0, green: 60.0 / 255, blue: 20.0 / 255, opacity: 0)
    /// `C.wire` (:30).
    static func wire(_ a: Double) -> Color {
        Color(.sRGB, red: 1.0, green: 60.0 / 255, blue: 20.0 / 255, opacity: a)
    }
    /// `C.dust` (:31).
    static func dust(_ a: Double) -> Color {
        Color(.sRGB, red: 1.0, green: 215.0 / 255, blue: 185.0 / 255, opacity: a)
    }
    /// `C.glowStops` (:32-33) — four stops at 0 / 0.3 / 0.6 / 1.
    static func glowStops(_ a: Double) -> Gradient {
        Gradient(stops: [
            .init(color: Color(.sRGB, red: 1.0, green: 60.0 / 255, blue: 20.0 / 255, opacity: a), location: 0),
            .init(color: Color(.sRGB, red: 230.0 / 255, green: 45.0 / 255, blue: 10.0 / 255, opacity: a * 0.5), location: 0.3),
            .init(color: Color(.sRGB, red: 150.0 / 255, green: 25.0 / 255, blue: 5.0 / 255, opacity: a * 0.15), location: 0.6),
            .init(color: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0), location: 1),
        ])
    }
    /// `C.arc` (:34).
    static func arc(_ a: Double) -> Color {
        Color(.sRGB, red: 1.0, green: 145.0 / 255, blue: 85.0 / 255, opacity: max(0, min(1, a)))
    }
}

// MARK: - Renderer

/// Pure drawing — no state mutation, so the same entry point serves the live
/// view and the headless benchmark. That is the reason it is a static func on
/// an enum rather than a method on the view: a renderer only reachable from a
/// `body` cannot be timed without a screen.
enum OrbRenderer {

    static func draw(_ s: OrbState, in ctx: inout GraphicsContext, size: CGSize, tuning: OrbTuning) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let cx = w / 2, cy = h / 2
        let baseRadius = Double(min(w, h)) * 0.21          // :47 resize()
        let t = s.time

        // :283-284 — the trail fade. The prototype paints 28% black over the
        // previous frame instead of clearing, which is what produces the motion
        // trails. SwiftUI hands us a cleared context each tick, so the effect
        // is not reproducible by painting black here; it needs a persistent
        // drawable. NOT PORTED, and named so the gap is visible rather than
        // rediscovered as "the Swift orb looks crisper than the prototype".

        drawCentralGlow(s, &ctx, cx: cx, cy: cy, baseRadius: baseRadius, t: t)
        drawWireframe(s, &ctx, cx: cx, cy: cy, baseRadius: baseRadius, t: t)
        drawParticles(s, &ctx, cx: cx, cy: cy, t: t, tuning: tuning)
        drawOrb(s, &ctx, cx: cx, cy: cy, baseRadius: baseRadius, t: t, tuning: tuning)
        drawEnergyArcs(s, &ctx, cx: cx, cy: cy, baseRadius: baseRadius, t: t)
    }

    /// :222-231
    static func drawCentralGlow(_ s: OrbState, _ ctx: inout GraphicsContext,
                                cx: CGFloat, cy: CGFloat, baseRadius: Double, t: Double) {
        let pulse = sin(t * 2) * 0.15 + 0.85
        let r = baseRadius * (1.8 + s.glow * 0.8) * pulse
        let center = CGPoint(x: cx, y: cy)
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
            with: .radialGradient(OrbPalette.glowStops(0.15 + s.glow * 0.25),
                                  center: center, startRadius: 0, endRadius: r)
        )
    }

    /// :114-151 — latitude rings and every second longitude meridian.
    static func drawWireframe(_ s: OrbState, _ ctx: inout GraphicsContext,
                              cx: CGFloat, cy: CGFloat, baseRadius: Double, t: Double) {
        let r = baseRadius * 1.55
        let segments = 28, rings = 16
        let rotY = t * s.rotation, rotX = t * s.rotation * 0.6
        let cosY = cos(rotY), sinY = sin(rotY), cosX = cos(rotX), sinX = sin(rotX)
        let stroke = GraphicsContext.Shading.color(OrbPalette.wire(0.06 + s.glow * 0.04))
        let style = StrokeStyle(lineWidth: 0.5)

        for i in 1..<rings {
            let phi = Double(i) / Double(rings) * .pi
            let rr = r * sin(phi), yy = r * cos(phi)
            var path = Path()
            for j in 0...segments {
                let theta = Double(j) / Double(segments) * 2 * .pi
                let p = project(x: rr * cos(theta), y: yy, z: rr * sin(theta),
                                cosY: cosY, sinY: sinY, cosX: cosX, sinX: sinX, cx: cx, cy: cy)
                if j == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: stroke, style: style)
        }
        for j in stride(from: 0, to: segments, by: 2) {
            let theta = Double(j) / Double(segments) * 2 * .pi
            var path = Path()
            for i in 0...rings {
                let phi = Double(i) / Double(rings) * .pi
                let p = project(x: r * sin(phi) * cos(theta), y: r * cos(phi), z: r * sin(phi) * sin(theta),
                                cosY: cosY, sinY: sinY, cosX: cosX, sinX: sinX, cx: cx, cy: cy)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: stroke, style: style)
        }
    }

    /// :207-220
    static func drawParticles(_ s: OrbState, _ ctx: inout GraphicsContext,
                              cx: CGFloat, cy: CGFloat, t: Double, tuning: OrbTuning) {
        guard tuning.particleCount > 0 else { return }
        for p in s.particles.prefix(tuning.particleCount) {
            let wobble = sin(t * 2 + p.phase) * 8
            let x = cos(p.orbitAngle) * p.orbitDist + wobble
            let y = p.y + sin(t * 1.5 + p.phase) * 3
            let z = sin(p.orbitAngle) * p.orbitDist * 0.6
            let scale = 1 / (1 + z * 0.001)
            let flicker = 0.5 + sin(t * 3 + p.phase) * 0.5
            let sz = p.size * scale
            let rect = CGRect(x: cx + x * scale - p.size * 0.5,
                              y: cy + y * scale - p.size * 0.5,
                              width: sz, height: sz)
            ctx.fill(Path(rect), with: .color(OrbPalette.dust(p.alpha * flicker * (0.3 + s.glow * 0.7))))
        }
    }

    /// :153-205 — the point cloud. The expensive layer, and the one `OrbTuning`
    /// governs. Depth-sorted back-to-front, then filled; points whose noise
    /// displacement exceeds 0.5 additionally get a radial tip glow, capped by
    /// `glowBudget` (the prototype has no cap).
    static func drawOrb(_ s: OrbState, _ ctx: inout GraphicsContext,
                        cx: CGFloat, cy: CGFloat, baseRadius: Double, t: Double, tuning: OrbTuning) {
        let breath = sin(s.breathPhase) * 0.04 + 1
        let r = baseRadius * breath
        let spikeH = r * s.spikeIntensity
        let rotY = t * s.rotation, rotX = t * s.rotation * 0.6
        let cosRY = cos(rotY), sinRY = sin(rotY), cosRX = cos(rotX), sinRX = sin(rotX)
        let lat = tuning.latSteps, lon = tuning.lonSteps

        var points: [(x: CGFloat, y: CGFloat, z: Double, depth: Double, displacement: Double)] = []
        points.reserveCapacity((lat + 1) * (lon + 1))

        for i in 0...lat {
            let phi = Double(i) / Double(lat) * .pi
            for j in 0...lon {
                let theta = Double(j) / Double(lon) * 2 * .pi
                let n1 = sin(phi * 8 + t * 2.5) * cos(theta * 6 + t * 1.8)
                let n2 = sin(phi * 12 - t * 3.2) * cos(theta * 10 + t * 2.1)
                let n3 = sin(phi * 4 + theta * 5 + t * 1.5)
                let speakNoise = s.mode == .speaking
                    ? sin(phi * 20 + t * 12) * cos(theta * 15 + t * 8) * (s.speakWave * 0.4 + s.level * 0.5)
                    : 0
                let displacement = max(0, n1 * 0.5 + n2 * 0.3 + n3 * 0.2 + speakNoise)
                let totalR = r + displacement * spikeH
                let x = totalR * sin(phi) * cos(theta)
                let z = totalR * sin(phi) * sin(theta)
                let y = totalR * cos(phi)
                let x2 = x * cosRY - z * sinRY, z2 = x * sinRY + z * cosRY
                let y2 = y * cosRX - z2 * sinRX, z3 = y * sinRX + z2 * cosRX
                let depth = (z3 + r * 2) / (r * 4)
                points.append((cx + x2, cy + y2, z3, depth, displacement))
            }
        }
        points.sort { $0.z < $1.z }                    // :187, back to front

        var glowsDrawn = 0
        for p in points {
            let intensity = p.displacement
            let depthFade = max(0.1, p.depth)
            let alpha = depthFade * (0.4 + intensity * 0.6)
            let size = (1 + intensity * 3.5) * depthFade
            if intensity > 0.5 && glowsDrawn < tuning.glowBudget {
                glowsDrawn += 1
                let glowR = size * (2 + s.glow * 3)
                let g = Gradient(stops: [
                    .init(color: OrbPalette.tipGlowInner(intensity, alpha * 0.5 * s.glow), location: 0),
                    .init(color: OrbPalette.tipGlowOuter, location: 1),
                ])
                ctx.fill(
                    Path(CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                    with: .radialGradient(g, center: CGPoint(x: p.x, y: p.y),
                                          startRadius: 0, endRadius: glowR)
                )
            }
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)),
                with: .color(OrbPalette.point(intensity, alpha: alpha))
            )
        }
    }

    /// :233-254 — only above a glow threshold, arc count varies by mode.
    /// Note the source calls `Math.random()` inside the draw (:246-251): the
    /// arcs jitter per frame by design, they are not a smooth animation.
    static func drawEnergyArcs(_ s: OrbState, _ ctx: inout GraphicsContext,
                               cx: CGFloat, cy: CGFloat, baseRadius: Double, t: Double) {
        guard s.glow >= 0.5 else { return }
        let numArcs = s.mode == .rage ? 8 : (s.mode == .speaking ? 5 : 2)
        let r = baseRadius * 0.9
        for a in 0..<numArcs {
            let baseAngle = Double(a) / Double(numArcs) * 2 * .pi + t
            var path = Path()
            path.move(to: CGPoint(x: cx, y: cy))
            for step in 1...6 {
                let progress = Double(step) / 6
                let angle = baseAngle + sin(t * 5 + Double(a) + Double(step)) * 0.8
                let dist = r * progress * 1.2
                path.addLine(to: CGPoint(
                    x: cx + cos(angle) * dist + (Double.random(in: 0..<1) - 0.5) * 20,
                    y: cy + sin(angle) * dist + (Double.random(in: 0..<1) - 0.5) * 20
                ))
            }
            ctx.stroke(path,
                       with: .color(OrbPalette.arc((s.glow - 0.4) * 1.5 * (0.3 + Double.random(in: 0..<1) * 0.7))),
                       style: StrokeStyle(lineWidth: 1 + Double.random(in: 0..<1) * 1.5))
        }
    }

    /// The shared Y-then-X rotation with the prototype's perspective divide.
    /// `0.0008` (:131, :146) is the wireframe's constant; the point cloud uses
    /// no divide at all (:181-184) — that asymmetry is in the source and is
    /// preserved rather than "fixed", because unifying it changes the look.
    @inline(__always)
    static func project(x: Double, y: Double, z: Double,
                        cosY: Double, sinY: Double, cosX: Double, sinX: Double,
                        cx: CGFloat, cy: CGFloat) -> CGPoint {
        let x2 = x * cosY - z * sinY, z2 = x * sinY + z * cosY
        let y2 = y * cosX - z2 * sinX, z3 = y * sinX + z2 * cosX
        let scale = 1 / (1 + z3 * 0.0008)
        return CGPoint(x: cx + x2 * scale, y: cy + y2 * scale)
    }
}
