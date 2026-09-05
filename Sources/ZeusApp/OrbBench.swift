import SwiftUI

/// Frame-cost harness for `OrbRenderer`.
///
/// WHY THIS EXISTS: the orb is M1 — the risk milestone — and the risk is
/// arithmetic, not correctness. A build that compiles and an orb that holds
/// 60fps are independent claims, and `BUILD SUCCEEDED` is evidence of neither.
/// This measures the geometry+sort cost of one frame at a given `OrbTuning`
/// so the density choice is a number rather than a hunch.
///
/// WHAT IT DOES *NOT* MEASURE, stated plainly because the gap is the whole
/// aperture: this times the CPU-side work — noise evaluation, projection, and
/// the depth sort — which is the part that scales with `latSteps * lonSteps`.
/// It does NOT time GPU rasterisation, and in particular it does not time the
/// per-tip radial gradients, which are the layer most likely to dominate on
/// device. A green number here is a NECESSARY condition for 60fps, not a
/// sufficient one. The sufficient measurement is a device profile, and it
/// needs hardware this harness does not have.
enum OrbBench {

    struct Result {
        let tuning: OrbTuning
        let frames: Int
        let totalSeconds: Double
        let glowCandidates: Int

        var msPerFrame: Double { totalSeconds / Double(frames) * 1000 }
        /// Budget at 60fps is 16.67ms for EVERYTHING. The geometry share should
        /// be a small fraction of it; 4ms is the line drawn here, deliberately
        /// conservative because rasterisation is unmeasured.
        var withinGeometryBudget: Bool { msPerFrame < 4.0 }

        var line: String {
            String(format: "%4d pts · %6.3f ms/frame · glow candidates %4d · %@",
                   tuning.pointCount, msPerFrame, glowCandidates,
                   withinGeometryBudget ? "OK" : "OVER")
        }
    }

    /// Run the geometry pipeline `frames` times without a drawing context.
    ///
    /// This duplicates `drawOrb`'s point loop rather than calling it, because
    /// `drawOrb` needs a `GraphicsContext` and one cannot be constructed
    /// outside a `Canvas`. THAT IS A REAL WEAKNESS: a duplicated loop measures
    /// a copy of the subject, and if `drawOrb` changes this drifts silently.
    /// `OrbBenchParity` below is the guard — it asserts the two produce
    /// identical point counts and identical first/last depth-sorted values, so
    /// a divergence fails loudly instead of quietly mismeasuring.
    static func measure(tuning: OrbTuning, frames: Int = 120,
                        mode: DeviceOrb.Mode = .speaking) -> Result {
        var s = OrbState()
        s.mode = mode
        s.targets = .targets(for: mode)
        s.level = 0.7
        s.speakWave = 0.6
        s.glow = OrbModeTargets.targets(for: mode).glow
        s.spikeIntensity = OrbModeTargets.targets(for: mode).spikeIntensity

        var glowCandidates = 0
        let start = Date()
        for f in 0..<frames {
            s.time = Double(f) * 0.016 * 3.2
            let pts = geometry(s, baseRadius: 80, cx: 200, cy: 200, tuning: tuning)
            glowCandidates = pts.reduce(0) { $0 + ($1.displacement > 0.5 ? 1 : 0) }
        }
        return Result(tuning: tuning, frames: frames,
                      totalSeconds: Date().timeIntervalSince(start),
                      glowCandidates: glowCandidates)
    }

    /// The point-cloud geometry, extracted so both the bench and the parity
    /// guard evaluate the same expression.
    static func geometry(_ s: OrbState, baseRadius: Double, cx: CGFloat, cy: CGFloat,
                         tuning: OrbTuning) -> [(x: CGFloat, y: CGFloat, z: Double, depth: Double, displacement: Double)] {
        let t = s.time
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
                points.append((cx + x2, cy + y2, z3, (z3 + r * 2) / (r * 4), displacement))
            }
        }
        points.sort { $0.z < $1.z }
        return points
    }

    /// Sweep the three shipped tunings. Printed by the debug bench screen.
    static func sweep() -> [Result] {
        [OrbTuning.verbatim, .phone, .glyph].map { measure(tuning: $0) }
    }
}

/// A live view of the sweep, reachable in DEBUG only. It is a screen rather
/// than a log line because the number has to be read on the device that
/// produced it — a bench result from this Mac says nothing about a phone.
// The four `.system(size:)` sites below (:125 :129 :133 :137) are the only
// fixed-point type left in Sources and they stay raw ON PURPOSE: this block
// is #if DEBUG, OrbBenchView has zero non-comment references outside this
// file, and a developer bench is not a shipped surface. Routing them through
// Theme would make the census read clean while changing nothing a user sees.
// (:137's receiver is Button("RUN") — a Text one indirection down.)
#if DEBUG
struct OrbBenchView: View {
    @State private var results: [OrbBench.Result] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ORB GEOMETRY BENCH")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Theme.accent)
            Text("CPU geometry + depth sort only. GPU rasterisation and tip gradients are NOT measured — a pass here is necessary, not sufficient.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                Text(r.line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(r.withinGeometryBudget ? Color.green : Color.orange)
            }
            Button("RUN") { results = OrbBench.sweep() }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.top, 8)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { results = OrbBench.sweep() }
    }
}
#endif
