//
//  NekoCursorView.swift
//  TipTour
//
//  Pixel-art cat that replaces the blue triangle cursor in Neko mode.
//  Based on the classic oneko sprites (Masayuki Koba, 1989), vendored
//  from github.com/crgimenes/neko under BSD-2-Clause — see the
//  LICENSE-NEKO.txt file alongside the sprite assets.
//
//  The cat picks one of 8 directional sprite pairs based on the
//  velocity of the cursor position, alternates between frame 1 and
//  frame 2 for a running animation, and falls asleep after a period
//  of no movement. Pixel art is scaled up 3× with nearest-neighbor
//  interpolation so it stays crisp on Retina displays.
//

import AppKit
import SwiftUI

/// Color palette for the Arc Reactor cursor, derived from the Iron Man
/// Arc Reactor Figma design (teal/cyan on dark).
enum ArcReactorColors {
    static let arcTeal         = Color(red: 0,     green: 0.831, blue: 0.753) // #00D4C0
    static let arcDarkBase     = Color(red: 0.067, green: 0.114, blue: 0.114) // #111D1D
    static let arcPanelDivider = Color(red: 0.039, green: 0.082, blue: 0.082) // #0A1515
}

/// Equilateral triangle pointing downward (∇). Kept for reference.
struct InvertedTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 9-point tri-star: equilateral ∇ main triangle with one small equilateral
/// spike at each vertex, matching the Figma design. Coordinates derived from
/// exact equilateral geometry — accent side = 23% of main side (61 / 264 pt).
struct ArcReactorInnerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let W = rect.width
        let H = rect.height
        var path = Path()

        // Clockwise from the top edge, right of the TL spike.
        path.move(to: CGPoint(x: 0.21 * W, y: 0.09 * H))   // top edge — right of TL spike
        path.addLine(to: CGPoint(x: 0.00 * W, y: 0.00 * H)) // TL spike tip
        path.addLine(to: CGPoint(x: 0.17 * W, y: 0.17 * H)) // left edge — below TL
        path.addLine(to: CGPoint(x: 0.46 * W, y: 0.74 * H)) // left edge — above B
        path.addLine(to: CGPoint(x: 0.50 * W, y: 1.00 * H)) // B spike tip
        path.addLine(to: CGPoint(x: 0.54 * W, y: 0.74 * H)) // right edge — above B
        path.addLine(to: CGPoint(x: 0.83 * W, y: 0.17 * H)) // right edge — below TR
        path.addLine(to: CGPoint(x: 1.00 * W, y: 0.00 * H)) // TR spike tip
        path.addLine(to: CGPoint(x: 0.79 * W, y: 0.09 * H)) // top edge — left of TR spike
        path.closeSubpath()

        return path
    }
}

/// 8-way compass direction derived from a velocity vector. Used to
/// pick which sprite pair to render.
enum NekoDirection: String, CaseIterable {
    case up, down, left, right
    case upLeft, upRight, downLeft, downRight

    /// Convert a velocity vector into one of the 8 compass directions.
    /// Returns nil when the vector is below a minimum magnitude —
    /// caller uses that to switch the neko to idle/sleep.
    static func from(velocityVector: CGVector, minimumMagnitude: CGFloat = 1.5) -> NekoDirection? {
        let magnitude = hypot(velocityVector.dx, velocityVector.dy)
        guard magnitude >= minimumMagnitude else { return nil }

        // SwiftUI Y axis points DOWN, so a positive dy is "moving down".
        // atan2(dy, dx) gives the angle in radians with 0 = right, π/2 = down.
        let angleRadians = atan2(velocityVector.dy, velocityVector.dx)
        let angleDegrees = angleRadians * 180.0 / .pi  // -180…180

        // Split the circle into 8 slices of 45° each, offset by 22.5°
        // so each direction's "natural" angle sits in the middle of its slice.
        let normalized = (angleDegrees + 360).truncatingRemainder(dividingBy: 360)
        switch normalized {
        case 0..<22.5, 337.5..<360:  return .right
        case 22.5..<67.5:            return .downRight
        case 67.5..<112.5:           return .down
        case 112.5..<157.5:          return .downLeft
        case 157.5..<202.5:          return .left
        case 202.5..<247.5:          return .upLeft
        case 247.5..<292.5:          return .up
        case 292.5..<337.5:          return .upRight
        default:                     return .right
        }
    }

    /// Sprite filename prefix for this direction — matches the oneko
    /// asset naming (e.g. "upleft1.png", "upleft2.png").
    var spriteFilenamePrefix: String {
        switch self {
        case .up:        return "up"
        case .down:      return "down"
        case .left:      return "left"
        case .right:     return "right"
        case .upLeft:    return "upleft"
        case .upRight:   return "upright"
        case .downLeft:  return "downleft"
        case .downRight: return "downright"
        }
    }
}

/// Arc Reactor cursor driven by TipTour's voice state.
///
/// Frame mapping (ReactorFrame1–5 assets):
///   Frame 1 = inactive/dim (reactor offline)
///   Frame 5 = fully active (reactor at full power)
///
/// Behaviour:
///   On appear  → boot animation Frame 1 → 2 → 3 → 4 → 5 (once)
///   .idle      → hold Frame 1
///   .listening → hold Frame 3 (awake, waiting)
///   .responding → fast blink Frame 4 ↔ 5 (reactor pulses with speech)
///   .processing → wave sweep Frame 1 → 5 → 1 (reactor scanning/thinking)
struct ArcReactorCursorView: View {

    let position: CGPoint
    let opacity: Double
    let flightScale: CGFloat
    let voiceState: CompanionVoiceState

    private let displaySize: CGFloat = 56
    /// Seconds between each blink tick — drives the responding blink and
    /// the processing wave sweep.
    private let blinkTickInterval: Double = 0.13

    /// Continuous position in the 1–5 frame range. SwiftUI interpolates this
    /// value during withAnimation blocks, producing seamless blends between
    /// adjacent frames rather than discrete cuts.
    @State private var frameProgress: Double = 1.0
    @State private var bootComplete: Bool = false
    @State private var waveStepIndex: Int = 0

    private static let wavePattern: [Int] = [1, 2, 3, 4, 5, 4, 3, 2]

    var body: some View {
        TimelineView(.animation(minimumInterval: blinkTickInterval, paused: false)) { context in
            reactorImageView
                .frame(width: displaySize, height: displaySize)
                .scaleEffect(flightScale)
                .opacity(opacity)
                .position(position)
                .onChange(of: context.date) { _, _ in
                    advanceBlinkTick()
                }
                .onChange(of: voiceState) { _, newState in
                    applyVoiceStateTransition(newState)
                }
        }
        .onAppear {
            runBootAnimation()
        }
    }

    @ViewBuilder
    private var reactorImageView: some View {
        ZStack {
            ForEach(1...5, id: \.self) { frameIndex in
                Image("ReactorFrame\(frameIndex)")
                    .resizable()
                    .scaledToFit()
                    .opacity(opacityForFrame(frameIndex))
            }
        }
        .mask(
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.85),
                    .init(color: .clear,  location: 1.0)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: displaySize / 2
            )
        )
    }

    /// Opacity for a given frame based on its distance from frameProgress.
    /// Adjacent frames blend together as frameProgress passes between them.
    private func opacityForFrame(_ index: Int) -> Double {
        max(0.0, 1.0 - abs(frameProgress - Double(index)))
    }

    /// One smooth easeInOut sweep from Frame 1 to Frame 5, then holds before
    /// handing off to voiceState.
    private func runBootAnimation() {
        withAnimation(.easeInOut(duration: 1.4)) {
            frameProgress = 5.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            bootComplete = true
            applyVoiceStateTransition(voiceState)
        }
    }

    private func applyVoiceStateTransition(_ newState: CompanionVoiceState) {
        guard bootComplete else { return }
        switch newState {
        case .idle:
            withAnimation(.easeInOut(duration: 0.5)) { frameProgress = 1.0 }
        case .listening:
            withAnimation(.easeInOut(duration: 0.5)) { frameProgress = 3.0 }
        case .responding, .processing:
            break
        }
    }

    /// Drives the responding blink (4 ↔ 5) and processing wave each tick.
    private func advanceBlinkTick() {
        guard bootComplete else { return }
        switch voiceState {
        case .responding:
            let target: Double = (frameProgress >= 4.5) ? 4.0 : 5.0
            withAnimation(.easeInOut(duration: 0.09)) { frameProgress = target }
        case .processing:
            waveStepIndex = (waveStepIndex + 1) % Self.wavePattern.count
            let target = Double(Self.wavePattern[waveStepIndex])
            withAnimation(.easeInOut(duration: 0.09)) { frameProgress = target }
        case .idle, .listening:
            break
        }
    }
}

/// Energy-particle trail rendered behind the Arc Reactor during a bezier
/// flight. Replaces the paw-print footprints used by the cat. Each trail
/// point becomes a small teal glowing dot; older dots fade toward transparent.
struct ArcReactorTrailView: View {
    let trailPoints: [CGPoint]

    /// Render every Nth point so particles don't stack into a smear.
    private let spacingStride: Int = 3

    /// Diameter of the solid inner dot.
    private let particleInnerSize: CGFloat = 6

    /// Diameter of the blurred outer halo around each particle.
    private let particleHaloSize: CGFloat = 10

    var body: some View {
        ZStack {
            ForEach(Array(stridedTrailPoints.enumerated()), id: \.offset) { renderIndex, point in
                let ageRatio = Double(renderIndex) / Double(max(stridedTrailPoints.count - 1, 1))
                // Oldest particles (low renderIndex) are near-transparent;
                // newest particle at the reactor's tail is most opaque.
                let particleOpacity = 0.1 + (0.45 * ageRatio)

                ZStack {
                    // Blurred halo behind each particle.
                    Circle()
                        .fill(ArcReactorColors.arcTeal.opacity(particleOpacity * 0.6))
                        .frame(width: particleHaloSize, height: particleHaloSize)
                        .blur(radius: 4)

                    // Solid inner dot.
                    Circle()
                        .fill(ArcReactorColors.arcTeal.opacity(particleOpacity))
                        .frame(width: particleInnerSize, height: particleInnerSize)
                }
                .position(point)
            }
        }
        .allowsHitTesting(false)
    }

    /// Applies the stride so particles aren't stacked on top of each other.
    private var stridedTrailPoints: [CGPoint] {
        guard trailPoints.count >= 2 else { return [] }
        return stride(from: 1, to: trailPoints.count, by: spacingStride).map { trailPoints[$0] }
    }
}

