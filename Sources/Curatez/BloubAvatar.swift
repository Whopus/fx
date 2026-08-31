import AppKit
import SwiftUI

/// A small, native SwiftUI adaptation of bloub's central idea: the rendered
/// frame is a pure sample of presentation + time, while the view only owns the
/// transition between two presentations.
struct BloubAvatar: View {
    let presentation: BloubPresentation
    var palette: BloubPalette = .inkOnPaper
    var followsPointer = false
    var isPaused = false

    @State private var previousPresentation: BloubPresentation
    @State private var transitionStartedAt: TimeInterval = 0
    @State private var clockStartedAt: TimeInterval
    @State private var neutralStartedAt: TimeInterval
    @State private var idleSequenceSeed: UInt64
    @State private var screenCenter: CGPoint?
    @State private var pointerTracker = BloubPointerGazeTracker()

    init(
        presentation: BloubPresentation,
        palette: BloubPalette = .inkOnPaper,
        followsPointer: Bool = false,
        isPaused: Bool = false
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        self.presentation = presentation
        self.palette = palette
        self.followsPointer = followsPointer
        self.isPaused = isPaused
        _previousPresentation = State(initialValue: presentation)
        _clockStartedAt = State(initialValue: now)
        _neutralStartedAt = State(initialValue: now)
        _idleSequenceSeed = State(initialValue: UInt64.random(in: .min ... .max))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let sceneTime = max(now - clockStartedAt, 0)
            let neutralElapsed = max(now - neutralStartedAt, 0)
            // AppKit screen APIs stay on the Timeline's main-thread update;
            // the asynchronous Canvas closure only receives plain values.
            let pointerGaze = pointerTracker.sample(
                at: sceneTime,
                enabled: followsPointer,
                pointer: followsPointer ? NSEvent.mouseLocation : .zero,
                avatarCenter: screenCenter
            )
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let elapsed = now - transitionStartedAt
                // bloub's engine clock begins at component mount. Feeding it
                // Date's absolute reference time shifts every periodic gaze
                // curve to an arbitrary phase; in particular, Excited can be
                // sampled while its eyes have drifted back toward the centre.
                let progress = transitionStartedAt == 0
                    ? 1
                    : BloubSampler.easeOutQuint(min(max(elapsed / 0.42, 0), 1))
                let oldFrame = BloubSampler.sample(
                    previousPresentation,
                    at: sceneTime,
                    neutralElapsed: neutralElapsed,
                    idleSequenceSeed: idleSequenceSeed,
                    gaze: pointerGaze
                )
                let newFrame = BloubSampler.sample(
                    presentation,
                    at: sceneTime,
                    neutralElapsed: neutralElapsed,
                    idleSequenceSeed: idleSequenceSeed,
                    gaze: pointerGaze
                )
                BloubRenderer.draw(
                    BloubFrame.interpolate(from: oldFrame, to: newFrame, progress: progress),
                    in: size,
                    palette: palette,
                    context: &context
                )
            }
        }
        .background {
            BloubScreenAnchorReader { center in
                if screenCenter != center {
                    screenCenter = center
                }
            }
        }
        .onChange(of: presentation) { oldValue, newValue in
            previousPresentation = oldValue
            transitionStartedAt = Date.timeIntervalSinceReferenceDate
            if newValue.expression == .neutral, oldValue.expression != .neutral {
                neutralStartedAt = transitionStartedAt
                idleSequenceSeed = UInt64.random(in: .min ... .max)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

struct BloubPointerTarget: Equatable {
    let yaw: Double
    let pitch: Double

    static func resolve(
        pointer: CGPoint,
        avatarCenter: CGPoint,
        screenFrame: CGRect
    ) -> BloubPointerTarget {
        let halfWidth = max(screenFrame.width / 2, 1)
        let halfHeight = max(screenFrame.height / 2, 1)
        let nx = min(max((pointer.x - avatarCenter.x) / halfWidth, -1), 1)
        // AppKit's Y axis points up, matching positive pitch. Unlike bloub's
        // customizer, Curatez has no side panel, so there is no fixed turn.
        let ny = min(max((pointer.y - avatarCenter.y) / halfHeight, -1), 1)
        return BloubPointerTarget(yaw: Double(nx) * 16, pitch: Double(ny) * 13)
    }
}

private struct BloubPointerGaze {
    let yaw: Double
    let pitch: Double
    let mix: CGFloat
}

private final class BloubPointerGazeTracker {
    private var yaw = 0.0
    private var pitch = 0.0
    private var mix: CGFloat = 0
    private var sampledAt: TimeInterval?

    func sample(
        at time: TimeInterval,
        enabled: Bool,
        pointer: CGPoint,
        avatarCenter: CGPoint?
    ) -> BloubPointerGaze? {
        let delta = sampledAt.map { min(max(time - $0, 0), 0.064) } ?? 0
        sampledAt = time
        let linear = min(max(CGFloat(delta / 0.24), 0), 1)
        let progress = BloubSampler.easeOutQuint(linear)

        if enabled,
           let avatarCenter,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(avatarCenter, $0.frame, false) }) {
            let target = BloubPointerTarget.resolve(
                pointer: pointer,
                avatarCenter: avatarCenter,
                screenFrame: screen.frame
            )
            if sampledAt == nil || mix == 0 {
                yaw = target.yaw
                pitch = target.pitch
            } else {
                yaw = lerp(yaw, target.yaw, Double(progress))
                pitch = lerp(pitch, target.pitch, Double(progress))
            }
            mix = lerp(mix, 1, progress)
        } else {
            mix = lerp(mix, 0, progress)
        }

        guard mix > 0.001 else { return nil }
        return BloubPointerGaze(yaw: yaw, pitch: pitch, mix: mix)
    }
}

private struct BloubScreenAnchorReader: NSViewRepresentable {
    let onChange: @MainActor (CGPoint?) -> Void

    func makeNSView(context: Context) -> BloubScreenAnchorView {
        let view = BloubScreenAnchorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: BloubScreenAnchorView, context: Context) {
        view.onChange = onChange
        view.reportCenter()
    }
}

private final class BloubScreenAnchorView: NSView {
    var onChange: (@MainActor (CGPoint?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportCenter()
    }

    override func layout() {
        super.layout()
        reportCenter()
    }

    func reportCenter() {
        guard let window else {
            onChange?(nil)
            return
        }
        let pointInWindow = convert(
            CGPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(pointOnScreen)
        }
    }
}

enum BloubPalette {
    case inkOnPaper
    case paperOnInk

    fileprivate var bodyColor: Color {
        switch self {
        case .inkOnPaper: Color(red: 0.04, green: 0.04, blue: 0.05)
        case .paperOnInk: .white
        }
    }

    fileprivate var eyeColor: Color {
        switch self {
        case .inkOnPaper: .white
        case .paperOnInk: .black
        }
    }

}

private struct BloubEye {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// Affine basis projected from the eye's tangent plane on the sphere.
    /// Keeping all four terms matters: the outer eye is foreshortened and the
    /// projected axes are not generally perpendicular on screen.
    var a: CGFloat
    var b: CGFloat
    var c: CGFloat
    var d: CGFloat
    var opacity: CGFloat

    static func interpolate(from: BloubEye, to: BloubEye, progress: CGFloat) -> BloubEye {
        BloubEye(
            x: lerp(from.x, to.x, progress),
            y: lerp(from.y, to.y, progress),
            width: lerp(from.width, to.width, progress),
            height: lerp(from.height, to.height, progress),
            a: lerp(from.a, to.a, progress),
            b: lerp(from.b, to.b, progress),
            c: lerp(from.c, to.c, progress),
            d: lerp(from.d, to.d, progress),
            opacity: lerp(from.opacity, to.opacity, progress)
        )
    }
}

private struct BloubFrame {
    var bodyOffset: CGSize
    var bodyScale: CGSize
    var profile: [CGFloat]
    var eyes: [BloubEye]
    var notificationOpacity: CGFloat

    static func interpolate(from: BloubFrame, to: BloubFrame, progress: CGFloat) -> BloubFrame {
        BloubFrame(
            bodyOffset: CGSize(
                width: lerp(from.bodyOffset.width, to.bodyOffset.width, progress),
                height: lerp(from.bodyOffset.height, to.bodyOffset.height, progress)
            ),
            bodyScale: CGSize(
                width: lerp(from.bodyScale.width, to.bodyScale.width, progress),
                height: lerp(from.bodyScale.height, to.bodyScale.height, progress)
            ),
            profile: zip(from.profile, to.profile).map { lerp($0, $1, progress) },
            eyes: zip(from.eyes, to.eyes).map {
                BloubEye.interpolate(from: $0, to: $1, progress: progress)
            },
            notificationOpacity: lerp(
                from.notificationOpacity,
                to.notificationOpacity,
                progress
            )
        )
    }
}

/// A probabilistic, replayable idle animation. Randomness only decides whether
/// a time slot contains the sequence; once the seed and elapsed time are known,
/// every frame is deterministic and can be sampled in any order.
enum BloubIdleSequence {
    struct Blend {
        let from: BloubPresentation
        let to: BloubPresentation
        let progress: CGFloat
    }

    static let slotDuration: TimeInterval = 9
    static let opportunityAt: TimeInterval = 2
    static let triggerProbability = 0.55

    private static let transitionToCurious: TimeInterval = 0.22
    private static let curiousHold: TimeInterval = 1
    private static let transitionToShy: TimeInterval = 0.22
    private static let shyHold: TimeInterval = 1
    private static let transitionToNeutral: TimeInterval = 0.35

    static func blend(at elapsed: TimeInterval, seed: UInt64) -> Blend? {
        guard elapsed >= opportunityAt else { return nil }
        let slot = Int(floor(elapsed / slotDuration))
        let localTime = elapsed - TimeInterval(slot) * slotDuration
        guard localTime >= opportunityAt,
              unitRandom(seed: seed, slot: slot) < triggerProbability else {
            return nil
        }
        return sequenceBlend(at: localTime - opportunityAt)
    }

    static func sequenceBlend(at time: TimeInterval) -> Blend? {
        var cursor: TimeInterval = 0

        if time < cursor + transitionToCurious {
            return transition(
                from: .neutral,
                to: .curious,
                elapsed: time - cursor,
                duration: transitionToCurious
            )
        }
        cursor += transitionToCurious
        if time < cursor + curiousHold {
            return hold(.curious)
        }
        cursor += curiousHold

        if time < cursor + transitionToShy {
            return transition(
                from: .curious,
                to: .shy,
                elapsed: time - cursor,
                duration: transitionToShy
            )
        }
        cursor += transitionToShy
        if time < cursor + shyHold {
            return hold(.shy)
        }
        cursor += shyHold

        if time < cursor + transitionToNeutral {
            return transition(
                from: .shy,
                to: .neutral,
                elapsed: time - cursor,
                duration: transitionToNeutral
            )
        }
        return nil
    }

    private static func hold(_ expression: BloubExpression) -> Blend {
        let presentation = presentation(for: expression)
        return Blend(from: presentation, to: presentation, progress: 1)
    }

    private static func transition(
        from: BloubExpression,
        to: BloubExpression,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Blend {
        let linear = min(max(CGFloat(elapsed / duration), 0), 1)
        return Blend(
            from: presentation(for: from),
            to: presentation(for: to),
            progress: BloubSampler.easeOutQuint(linear)
        )
    }

    private static func presentation(for expression: BloubExpression) -> BloubPresentation {
        let motion: BloubMotion = switch expression {
        // These are expression changes on bloub's idle state. Only the eyes
        // morph; the body remains the same circle throughout the sequence.
        case .neutral, .attentive, .surprised, .excited, .curious, .shy: .breathe
        case .focused: .think
        case .pleased: .celebrate
        case .concerned: .shake
        case .sleeping: .doze
        }
        return BloubPresentation(
            expression: expression,
            motion: motion,
            showsNotificationDot: false,
            accessibilityLabel: "Curatez 空闲动画"
        )
    }

    private static func unitRandom(seed: UInt64, slot: Int) -> Double {
        var value = seed &+ UInt64(slot) &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53)
    }
}

private enum BloubSampler {
    static let sampleCount = 48

    static func sample(
        _ presentation: BloubPresentation,
        at time: TimeInterval,
        neutralElapsed: TimeInterval,
        idleSequenceSeed: UInt64,
        gaze: BloubPointerGaze?
    ) -> BloubFrame {
        if presentation.expression == .neutral,
           presentation.motion == .breathe,
           let blend = BloubIdleSequence.blend(
               at: neutralElapsed,
               seed: idleSequenceSeed
           ) {
            return BloubFrame.interpolate(
                from: sampleBase(blend.from, at: time, gaze: gaze),
                to: sampleBase(blend.to, at: time, gaze: gaze),
                progress: blend.progress
            )
        }
        return sampleBase(presentation, at: time, gaze: gaze)
    }

    private static func sampleBase(
        _ presentation: BloubPresentation,
        at time: TimeInterval,
        gaze: BloubPointerGaze?
    ) -> BloubFrame {
        var eyes = eyePose(for: presentation.expression, at: time, gaze: gaze)
        var offset = CGSize.zero
        var scale = CGSize(width: 1, height: 1)
        var deformation: CGFloat = 0.008
        var travellingPhase = CGFloat(time * 0.55)

        switch presentation.motion {
        case .breathe:
            // The idle body is a circle. Liveliness comes from the gaze and
            // blink; translating the circle is fine, changing its radial
            // profile or aspect ratio is not.
            offset.width = CGFloat(loopNoise(time, period: 7.9, seed: 1.9) * 0.006)
            offset.height = CGFloat(loopNoise(time, period: 5.3, seed: 0.3) * 0.007)
            scale = CGSize(width: 1, height: 1)
            deformation = 0
            travellingPhase = 0
            if presentation.expression == .neutral {
                applyNeutralGazeDrift(at: time, to: &eyes)
            }
            applyBlink(at: time, to: &eyes)
        case .think:
            let gaze = CGFloat(sin(time * 2.4)) * 0.10
            eyes.indices.forEach { eyes[$0].x += gaze }
            scale = CGSize(
                width: 1 + cos(time * 3.1) * 0.018,
                height: 1 - cos(time * 3.1) * 0.018
            )
            deformation = 0.045
            travellingPhase = CGFloat(time * 1.4)
        case .celebrate:
            let bounce = CGFloat((sin(time * 6.2) + 1) * 0.5)
            offset.height = -bounce * 0.08
            scale = CGSize(width: 1 + bounce * 0.025, height: 1 - bounce * 0.018)
            deformation = 0.025
            travellingPhase = CGFloat(time * 1.8)
        case .pulse:
            let pulse = CGFloat(0.5 + 0.5 * sin(time * 4.8))
            scale = CGSize(width: 1 + pulse * 0.045, height: 1 + pulse * 0.045)
            deformation = 0.018
            travellingPhase = CGFloat(time * 0.8)
        case .shake:
            offset.width = CGFloat(sin(time * 22)) * 0.055
            scale = CGSize(width: 0.98, height: 1.02)
            deformation = 0.035
            travellingPhase = CGFloat(time * 2.2)
        case .doze:
            offset.height = CGFloat(sin(time * 2.1)) * 0.055
            scale = CGSize(width: 1.02, height: 0.96)
            deformation = 0.012
            travellingPhase = CGFloat(time * 0.2)
        }

        let profile = (0..<sampleCount).map { index in
            let angle = CGFloat(index) / CGFloat(sampleCount) * .pi * 2
            let primary = sin(angle * 3 + travellingPhase) * deformation
            let secondary = cos(angle * 5 - travellingPhase * 0.7) * deformation * 0.38
            return 1 + primary + secondary
        }

        return BloubFrame(
            bodyOffset: offset,
            bodyScale: scale,
            profile: profile,
            eyes: eyes,
            notificationOpacity: presentation.showsNotificationDot ? 1 : 0
        )
    }

    static func easeOutQuint(_ value: CGFloat) -> CGFloat {
        1 - pow(1 - value, 5)
    }

    private static func applyBlink(at time: TimeInterval, to eyes: inout [BloubEye]) {
        let phase = time.truncatingRemainder(dividingBy: 3.8)
        guard phase < 0.18 else { return }
        let normalized = phase / 0.18
        let lid = normalized < 0.45
            ? 1 - normalized / 0.45
            : (normalized - 0.45) / 0.55
        // bloub composes the blink after the tangent-plane projection: only
        // the screen-space Y row is compressed, while the eye's bounding-box
        // width stays unchanged. Shrinking the local capsule height makes a
        // tilted excited eye visibly slide sideways during a blink.
        let screenScale = 0.06 + 0.94 * max(CGFloat(lid), 0)
        eyes.indices.forEach {
            eyes[$0].b *= screenScale
            eyes[$0].d *= screenScale
        }
    }

    /// A deterministic approximation of bloub's resting gaze wander. Two
    /// incommensurate low-frequency waves keep the motion from reading as a
    /// simple loop while preserving `sample(presentation, time)` as a pure
    /// function. Both eyes receive the same translation, so their spacing and
    /// the measured Neutral expression remain intact.
    private static func applyNeutralGazeDrift(
        at time: TimeInterval,
        to eyes: inout [BloubEye]
    ) {
        let tau = Double.pi * 2
        let x = sin((time / 11.3) * tau + 0.4) * 0.150
            + sin((time / 3.7) * tau + 2.1) * 0.055
        let y = sin((time / 9.1) * tau + 1.3) * 0.110
            + sin((time / 4.3) * tau + 0.7) * 0.040
        eyes.indices.forEach {
            eyes[$0].x += CGFloat(x)
            eyes[$0].y += CGFloat(y)
        }
    }

    private static func eyePose(
        for expression: BloubExpression,
        at time: TimeInterval,
        gaze: BloubPointerGaze?
    ) -> [BloubEye] {
        switch expression {
        case .neutral:
            // Projected from bloub's measured REST_GAZE (yaw 28.49,
            // pitch 28.62, roll -13) and EYE_SPLIT 15.46. Neutral looks to the
            // upper-right; keeping the eyes centered makes it read as Attentive.
            // Its dimensions include the 1.45x optical correction requested
            // for the 20pt island icon; other expressions keep source sizing.
            return [
                eye(x: 0.134, y: -0.354, width: 0.254, height: 0.570, rotation: -26),
                eye(x: 0.563, y: -0.459, width: 0.180, height: 0.570, rotation: -26)
            ]
        case .attentive:
            let angles = gazeAngles(
                baseYaw: 4,
                basePitch: 5,
                baseRoll: -4,
                at: time,
                gaze: gaze
            )
            // The source size is intended for a large canvas. While the
            // pointer owns the gaze, boost it to the same visual weight as
            // Natural in the 20 pt island; interpolate to avoid a size pop.
            let pointerScale = lerp(CGFloat(1), 1.35, gaze?.mix ?? 0)
            return [
                projectedEye(
                    yaw: angles.yaw,
                    pitch: angles.pitch,
                    roll: angles.roll,
                    split: 16,
                    side: -1,
                    width: 0.21 * pointerScale,
                    height: 0.44 * pointerScale,
                    tilt: 0
                ),
                projectedEye(
                    yaw: angles.yaw,
                    pitch: angles.pitch,
                    roll: angles.roll,
                    split: 16,
                    side: 1,
                    width: 0.21 * pointerScale,
                    height: 0.44 * pointerScale,
                    tilt: 0
                )
            ]
        case .excited:
            // 1:1 port of bloub's `excite` expression. The source parameters
            // are gaze (6, -14, 0), split 19.5, eyes 0.40 x 0.56 and mirrored
            // local tilts (-10, +10). The idle gaze noise is applied before
            // the same orthographic sphere projection as src/bot/face.ts.
            let yaw = 6
                + loopNoise(time, period: 11.3, seed: 0.4) * 5.5
                + loopNoise(time, period: 3.7, seed: 2.1) * 1.6
            let pitch = -14
                + loopNoise(time, period: 9.1, seed: 1.3) * 4.2
                + loopNoise(time, period: 4.3, seed: 0.7) * 1.3
            let roll = loopNoise(time, period: 13.7, seed: 3.2) * 2.2
            return [
                projectedEye(
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    split: 19.5,
                    side: -1,
                    width: 0.40,
                    height: 0.56,
                    tilt: -10
                ),
                projectedEye(
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    split: 19.5,
                    side: 1,
                    width: 0.40,
                    height: 0.56,
                    tilt: 10
                )
            ]
        case .curious:
            // bloub `curieux`: gaze (16, -9, -15), split 16.5, asymmetric
            // eyes, both tilted -8 degrees. As with Neutral, the source sizes
            // need an optical boost to remain legible in the 20 pt island.
            let opticalScale: CGFloat = 1.4
            let yaw = 16
                + loopNoise(time, period: 11.3, seed: 0.4) * 5.5
                + loopNoise(time, period: 3.7, seed: 2.1) * 1.6
            let pitch = -9
                + loopNoise(time, period: 9.1, seed: 1.3) * 4.2
                + loopNoise(time, period: 4.3, seed: 0.7) * 1.3
            let roll = -15 + loopNoise(time, period: 13.7, seed: 3.2) * 2.2
            return [
                projectedEye(
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    split: 16.5,
                    side: -1,
                    width: 0.24 * opticalScale,
                    height: 0.46 * opticalScale,
                    tilt: -8
                ),
                projectedEye(
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    split: 16.5,
                    side: 1,
                    width: 0.20 * opticalScale,
                    height: 0.38 * opticalScale,
                    tilt: -8
                )
            ]
        case .shy:
            // bloub `timide`: gaze (-19, -14, -7), split 14, paired
            // eyes, enlarged for the same 20 pt optical size as Neutral.
            let opticalScale: CGFloat = 1.6
            let yaw = -19
                + loopNoise(time, period: 11.3, seed: 0.4) * 5.5
                + loopNoise(time, period: 3.7, seed: 2.1) * 1.6
            let pitch = -14
                + loopNoise(time, period: 9.1, seed: 1.3) * 4.2
                + loopNoise(time, period: 4.3, seed: 0.7) * 1.3
            let roll = -7 + loopNoise(time, period: 13.7, seed: 3.2) * 2.2
            return [
                projectedEye(
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    split: 14,
                    side: -1,
                    width: 0.17 * opticalScale,
                    height: 0.30 * opticalScale,
                    tilt: 0
                ),
                projectedEye(
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    split: 14,
                    side: 1,
                    width: 0.17 * opticalScale,
                    height: 0.30 * opticalScale,
                    tilt: 0
                )
            ]
        case .focused:
            return [
                eye(x: -0.22, y: 0, width: 0.20, height: 0.34, rotation: -9),
                eye(x: 0.22, y: 0, width: 0.20, height: 0.34, rotation: 9)
            ]
        case .pleased:
            return [
                eye(x: -0.20, y: -0.04, width: 0.21, height: 0.43, rotation: -7),
                eye(x: 0.25, y: 0.01, width: 0.38, height: 0.10, rotation: -5)
            ]
        case .surprised:
            return [
                eye(x: -0.23, y: -0.01, width: 0.45, height: 0.47, rotation: -4),
                eye(x: 0.23, y: -0.01, width: 0.45, height: 0.47, rotation: 4)
            ]
        case .concerned:
            return [
                eye(x: -0.22, y: 0.02, width: 0.18, height: 0.40, rotation: 20),
                eye(x: 0.22, y: 0.02, width: 0.18, height: 0.40, rotation: -20)
            ]
        case .sleeping:
            return [
                eye(x: -0.22, y: 0.04, width: 0.34, height: 0.09, rotation: -5),
                eye(x: 0.22, y: 0.04, width: 0.34, height: 0.09, rotation: 5)
            ]
        }
    }

    private static func eye(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        rotation: Double
    ) -> BloubEye {
        let radians = rotation * .pi / 180
        return BloubEye(
            x: x,
            y: y,
            width: width,
            height: height,
            a: CGFloat(cos(radians)),
            b: CGFloat(sin(radians)),
            c: CGFloat(-sin(radians)),
            d: CGFloat(cos(radians)),
            opacity: 1
        )
    }

    private struct Vector3 {
        var x: Double
        var y: Double
        var z: Double
    }

    private static func projectedEye(
        yaw: Double,
        pitch: Double,
        roll: Double,
        split: Double,
        side: Double,
        width: CGFloat,
        height: CGFloat,
        tilt: Double
    ) -> BloubEye {
        var forward = Vector3(x: 0, y: 0, z: 1)
        var right = Vector3(x: 1, y: 0, z: 0)
        var down = Vector3(x: 0, y: 1, z: 0)

        (forward, right) = spin(forward, right, by: degrees(yaw))
        (down, forward) = spin(down, forward, by: degrees(pitch))
        (right, down) = spin(right, down, by: degrees(roll))

        let (eyeForward, eyeRight) = spin(
            forward,
            right,
            by: degrees(split * side)
        )
        let phi = degrees(tilt)
        let cosine = cos(phi)
        let sine = sin(phi)

        return BloubEye(
            x: CGFloat(eyeForward.x),
            y: CGFloat(eyeForward.y),
            width: width,
            height: height,
            a: CGFloat(eyeRight.x * cosine + down.x * sine),
            b: CGFloat(eyeRight.y * cosine + down.y * sine),
            c: CGFloat(-eyeRight.x * sine + down.x * cosine),
            d: CGFloat(-eyeRight.y * sine + down.y * cosine),
            opacity: 1
        )
    }

    private static func spin(
        _ u: Vector3,
        _ v: Vector3,
        by angle: Double
    ) -> (Vector3, Vector3) {
        let cosine = cos(angle)
        let sine = sin(angle)
        return (
            Vector3(
                x: u.x * cosine + v.x * sine,
                y: u.y * cosine + v.y * sine,
                z: u.z * cosine + v.z * sine
            ),
            Vector3(
                x: v.x * cosine - u.x * sine,
                y: v.y * cosine - u.y * sine,
                z: v.z * cosine - u.z * sine
            )
        )
    }

    private static func degrees(_ value: Double) -> Double {
        value * .pi / 180
    }

    private static func gazeAngles(
        baseYaw: Double,
        basePitch: Double,
        baseRoll: Double,
        at time: TimeInterval,
        gaze: BloubPointerGaze?
    ) -> (yaw: Double, pitch: Double, roll: Double) {
        let lifeYaw = loopNoise(time, period: 11.3, seed: 0.4) * 5.5
            + loopNoise(time, period: 3.7, seed: 2.1) * 1.6
        let lifePitch = loopNoise(time, period: 9.1, seed: 1.3) * 4.2
            + loopNoise(time, period: 4.3, seed: 0.7) * 1.3
        let lifeRoll = loopNoise(time, period: 13.7, seed: 3.2) * 2.2
        guard let gaze else {
            return (
                baseYaw + lifeYaw,
                basePitch + lifePitch,
                baseRoll + lifeRoll
            )
        }
        let mix = Double(gaze.mix)
        return (
            lerp(baseYaw + lifeYaw, gaze.yaw, mix),
            lerp(basePitch + lifePitch, gaze.pitch, mix),
            lerp(baseRoll + lifeRoll, baseRoll, mix)
        )
    }

    private static func loopNoise(
        _ time: TimeInterval,
        period: Double,
        seed: Double
    ) -> Double {
        let phase = (time / period) * .pi * 2
        return 0.55 * sin(phase + seed)
            + 0.30 * sin(2 * phase + seed * 1.7 + 1.1)
            + 0.15 * sin(3 * phase + seed * 2.3 + 2.4)
    }
}

private enum BloubRenderer {
    static func draw(
        _ frame: BloubFrame,
        in size: CGSize,
        palette: BloubPalette,
        context: inout GraphicsContext
    ) {
        let radius = min(size.width, size.height) * 0.40
        let center = CGPoint(
            x: size.width / 2 + frame.bodyOffset.width * radius,
            y: size.height / 2 + frame.bodyOffset.height * radius
        )
        let bodyPath = path(
            center: center,
            radius: radius,
            scale: frame.bodyScale,
            profile: frame.profile
        )
        context.fill(bodyPath, with: .color(palette.bodyColor))

        for eye in frame.eyes {
            let eyeCenter = CGPoint(
                x: center.x + eye.x * radius,
                y: center.y + eye.y * radius
            )
            let rect = CGRect(
                x: -eye.width * radius / 2,
                y: -eye.height * radius / 2,
                width: eye.width * radius,
                height: eye.height * radius
            )
            let transform = CGAffineTransform(
                a: eye.a,
                b: eye.b,
                c: eye.c,
                d: eye.d,
                tx: eyeCenter.x,
                ty: eyeCenter.y
            )
            var eyeContext = context
            eyeContext.opacity = eye.opacity
            eyeContext.fill(
                Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
                    .applying(transform),
                with: .color(palette.eyeColor)
            )
        }

        if frame.notificationOpacity > 0.001 {
            let dotRadius = radius * 0.16
            let dotCenter = CGPoint(
                x: center.x + radius * 0.70,
                y: center.y - radius * 0.68
            )
            context.opacity = frame.notificationOpacity
            context.fill(
                Path(ellipseIn: CGRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )),
                with: .color(Color(red: 0.18, green: 0.49, blue: 1))
            )
        }
    }

    private static func path(
        center: CGPoint,
        radius: CGFloat,
        scale: CGSize,
        profile: [CGFloat]
    ) -> Path {
        let count = profile.count
        let points = profile.enumerated().map { index, sample in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(
                x: center.x + cos(angle) * radius * sample * scale.width,
                y: center.y + sin(angle) * radius * sample * scale.height
            )
        }
        guard points.count >= 3 else { return Path() }

        var path = Path()
        path.move(to: points[0])
        for index in 0..<points.count {
            let p0 = points[(index - 1 + count) % count]
            let p1 = points[index]
            let p2 = points[(index + 1) % count]
            let p3 = points[(index + 2) % count]
            path.addCurve(
                to: p2,
                control1: CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6,
                    y: p1.y + (p2.y - p0.y) / 6
                ),
                control2: CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6,
                    y: p2.y - (p3.y - p1.y) / 6
                )
            )
        }
        path.closeSubpath()
        return path
    }
}

private func lerp<T: BinaryFloatingPoint>(_ from: T, _ to: T, _ progress: T) -> T {
    from + (to - from) * progress
}
