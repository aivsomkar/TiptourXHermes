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
/// Renders two stacked SVG layers (`NormalState` = passive, `ActiveState` =
/// fully lit with the inner glow cursor blazing) and cross-fades between
/// them based on `activationLevel` (0 → fully passive, 1 → fully active).
///
/// Behaviour:
///   On appear            → soft scale + fade-in entrance, rests in passive
///   .idle                → passive (activationLevel = 0)
///   .listening / .responding / .processing
///                        → cross-fades by `audioPowerLevel` so the reactor
///                          breathes with the user's voice and Hermes' speech
///
/// Note: the reactor never flies during a point-at-element gesture. The
/// glow cursor (`ArcReactorGlowCursorView`) detaches and flies on its own —
/// the reactor stays anchored at the user's mouse cursor.
struct ArcReactorCursorView: View {

    let position: CGPoint
    let opacity: Double
    let voiceState: CompanionVoiceState
    /// 0…1 power level from the live mic / TTS audio. Used to cross-fade the
    /// reactor between passive and active in time with the user's voice or
    /// Hermes' reply, when the voice session is engaged.
    let audioPowerLevel: CGFloat

    private let displaySize: CGFloat = 56
    /// Smoothing time for activation changes — short enough to feel reactive,
    /// long enough that we don't strobe on every audio sample.
    private let activationSmoothing: Double = 0.18

    /// Where the cross-fade sits along the passive → active axis. Driven
    /// from `audioPowerLevel` + `voiceState` and animated on change.
    @State private var activationLevel: Double = 0.0
    /// Boot scale (0.6 → 1.0) so the reactor pops into existence rather than
    /// snapping in. Runs once per appear.
    @State private var bootScale: CGFloat = 0.6
    @State private var bootOpacity: Double = 0.0
    /// True after the launch sweep has finished and we've handed off control
    /// to `voiceState` + `audioPowerLevel`. Gates `recomputeActivationLevel`
    /// so audio-driven updates can't stomp the in-progress boot animation.
    @State private var bootSweepComplete: Bool = false

    var body: some View {
        ZStack {
            Image("NormalState")
                .resizable()
                .scaledToFit()
                .opacity(1.0 - activationLevel)
            Image("ActiveState")
                .resizable()
                .scaledToFit()
                .opacity(activationLevel)
        }
        .frame(width: displaySize, height: displaySize)
        .scaleEffect(bootScale)
        .opacity(opacity * bootOpacity)
        .position(position)
        .onAppear(perform: runBootEntrance)
        .onChange(of: voiceState) { _, _ in
            recomputeActivationLevel()
        }
        .onChange(of: audioPowerLevel) { _, _ in
            recomputeActivationLevel()
        }
    }

    /// Launch sequence: scale + fade in (passive), sweep up to fully active,
    /// hold briefly, then ease back down to passive — at which point we hand
    /// off to `voiceState` + `audioPowerLevel`. The reactor visibly "ignites"
    /// once at launch instead of just snapping in.
    private func runBootEntrance() {
        bootScale = 0.6
        bootOpacity = 0.0
        activationLevel = 0.0
        bootSweepComplete = false

        // Stage 1: scale + fade in while still passive.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
            bootScale = 1.0
            bootOpacity = 1.0
        }

        // Stage 2: sweep passive → fully active.
        withAnimation(.easeInOut(duration: 0.7).delay(0.25)) {
            activationLevel = 1.0
        }

        // Stage 3: ease back down to passive, then hand off to voiceState.
        withAnimation(.easeInOut(duration: 0.65).delay(1.15)) {
            activationLevel = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
            bootSweepComplete = true
            recomputeActivationLevel()
        }
    }

    /// Map (voiceState, audioPowerLevel) → 0…1 cross-fade target.
    ///
    /// `audioPowerLevel` is mic-derived so it's only meaningful while the
    /// user is speaking (during `.listening`). During `.responding` Hermes
    /// is speaking and the mic is effectively silent — we hold the reactor
    /// near full active so it visibly tracks "Hermes is talking" rather than
    /// dimming because there's no mic input.
    private func recomputeActivationLevel() {
        // Boot sweep owns activationLevel — don't fight it.
        guard bootSweepComplete else { return }
        let target: Double
        switch voiceState {
        case .idle:
            target = 0.0
        case .listening:
            let clamped = max(0, min(1, Double(audioPowerLevel)))
            // 0.25 floor so the reactor reads as "engaged" between syllables;
            // 0.75 head-room above that for the mic-driven breathing.
            target = 0.25 + (clamped * 0.75)
        case .responding:
            target = 0.95
        case .processing:
            target = 0.55
        }
        withAnimation(.easeOut(duration: activationSmoothing)) {
            activationLevel = target
        }
    }
}

/// The four-triangle "glow cursor" that detaches from the arc reactor and
/// flies to a UI element during a point-at gesture. Rendered separately from
/// `ArcReactorCursorView` so the reactor stays put at the user's mouse while
/// only the glow makes the trip.
struct ArcReactorGlowCursorView: View {
    let position: CGPoint
    let opacity: Double
    let scale: CGFloat
    let rotationDegrees: Double
    /// Visible frame size in points. Two callers today:
    ///   • Neko mode point-at flight uses ~110pt so the burst reads as a
    ///     dramatic projectile that just ejected from the reactor's core.
    ///   • Default cursor (Neko mode off) uses ~48pt so the glow lives at a
    ///     normal cursor size and doesn't dominate the screen.
    var displaySize: CGFloat = 110

    var body: some View {
        Image("GlowCursor")
            .resizable()
            .scaledToFit()
            .frame(width: displaySize, height: displaySize)
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(scale)
            .opacity(opacity)
            .position(position)
            .allowsHitTesting(false)
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

