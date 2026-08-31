import AppKit
import MetalKit
import SwiftUI

private struct TransitionGeometry {
    let panelFrame: NSRect
    let sourceRect: NSRect
    let targetRect: NSRect
}

private final class PresentedFrameCompletion: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    func callOnMainActor() {
        DispatchQueue.main.async { [self] in
            body()
        }
    }
}

@MainActor
private final class DisplayLinkAnimationDriver: NSObject {
    private var frameLink: CADisplayLink?
    private var update: ((CFTimeInterval) -> Bool)?

    func start(for view: NSView, update: @escaping (CFTimeInterval) -> Bool) {
        stop()
        self.update = update
        let frameLink = view.displayLink(target: self, selector: #selector(step(_:)))
        frameLink.add(to: .main, forMode: .common)
        self.frameLink = frameLink
    }

    func stop() {
        frameLink?.invalidate()
        frameLink = nil
        update = nil
    }

    @objc private func step(_ frameLink: CADisplayLink) {
        if update?(CACurrentMediaTime()) == true {
            stop()
        }
    }
}

@MainActor
final class CuratezIslandWindowController {
    private let islandSize = NSSize(width: 252, height: 46)
    private let fallbackHandoffSize = NSSize(width: 120, height: 30)
    private let hardwareCutoutVisualWidthCompensation: CGFloat = 4
    private var panel: CuratezIslandPanel?
    private var transitionPanel: NSPanel?
    private var islandAnimationDriver: DisplayLinkAnimationDriver?
    private var activityController = CuratezIslandActivityController()

    init() {
        GenieTransitionView.prewarmMetal()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func observe(_ activityController: CuratezIslandActivityController) {
        precondition(panel == nil, "Attach the island activity before showing the panel")
        self.activityController = activityController
    }

    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        activityController.setIslandVisible(true)
        let panel = panel ?? makePanel()
        let finalFrame = islandFrame(on: screen)
        panel.setFrame(finalFrame, display: true)
        islandContainer(in: panel)?.setContentPresentation(opacity: 1, scale: 1)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func collapse(
        window: NSWindow,
        animated: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        let screen = window.screen ?? NSScreen.main
        guard animated, let screen, let snapshot = snapshot(of: window) else {
            window.orderOut(nil)
            show(on: screen)
            completion()
            return
        }

        let targetScreenFrame = screen.frame
        let geometry = transitionGeometry(for: window, on: screen)
        let transitionView = GenieTransitionView(
            image: snapshot,
            sourceRect: geometry.sourceRect,
            targetRect: geometry.targetRect,
            backingScaleFactor: screen.backingScaleFactor
        )
        let transitionPanel = makeTransitionPanel(frame: geometry.panelFrame, contentView: transitionView)
        self.transitionPanel = transitionPanel
        transitionView.prepare(from: 0, to: 1)
        transitionPanel.orderFrontRegardless()
        transitionPanel.displayIfNeeded()
        CATransaction.flush()

        transitionView.start(from: 0, to: 1, duration: 0.78) { [weak self] in
            guard let self else { return }
            let targetScreen = NSScreen.screens.first { $0.frame == targetScreenFrame }
                ?? NSScreen.main
                ?? screen
            self.handoffToIsland(on: targetScreen, transitionPanel: transitionPanel, completion: completion)
        }

        // Keep the real window under the prepared 0% frame until the next run-loop
        // turn. This prevents a one-frame flash between the live UI and its snapshot.
        DispatchQueue.main.async {
            window.orderOut(nil)
        }
    }

    func expand(
        window: NSWindow,
        animated: Bool = true,
        completion: @escaping @MainActor () -> Void
    ) {
        let screen = window.screen ?? NSScreen.main
        guard animated, let screen, let snapshot = snapshot(of: window) else {
            hideImmediately()
            window.makeKeyAndOrderFront(nil)
            completion()
            return
        }

        let geometry = transitionGeometry(for: window, on: screen)
        let transitionView = GenieTransitionView(
            image: snapshot,
            sourceRect: geometry.sourceRect,
            targetRect: geometry.targetRect,
            backingScaleFactor: screen.backingScaleFactor
        )
        let transitionPanel = makeTransitionPanel(frame: geometry.panelFrame, contentView: transitionView)
        self.transitionPanel?.orderOut(nil)
        self.transitionPanel = transitionPanel
        transitionView.prepare(from: 1, to: 0)
        transitionPanel.orderFrontRegardless()
        transitionPanel.displayIfNeeded()

        // Prime the real window while it is invisible and below the transition panel.
        // The first expansion otherwise has to allocate and composite the live window
        // at the exact moment the snapshot disappears, which can expose one blank frame.
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        contractIsland(on: screen) { [weak self] in
            guard let self else { return }
            self.hideImmediately()
            transitionView.start(from: 1, to: 0, duration: 0.78) { [weak self] in
                // The GPU has presented the exact 0% snapshot. Reveal the already
                // rendered live window below it, then retire the snapshot on the
                // following main-loop commit so there is never an uncovered frame.
                window.alphaValue = 1
                window.displayIfNeeded()
                CATransaction.flush()
                DispatchQueue.main.async {
                    transitionPanel.orderOut(nil)
                    self?.transitionPanel = nil
                    completion()
                }
            }
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                self.activityController.setIslandVisible(false)
            }
        })
    }

    private func hideImmediately() {
        islandAnimationDriver?.stop()
        islandAnimationDriver = nil
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        activityController.setIslandVisible(false)
    }

    private func handoffToIsland(
        on screen: NSScreen,
        transitionPanel: NSPanel,
        completion: @escaping @MainActor () -> Void
    ) {
        activityController.setIslandVisible(true)
        let panel = panel ?? makePanel()
        let smallFrame = handoffFrame(on: screen)
        panel.setFrame(smallFrame, display: true)
        panel.alphaValue = 1
        islandContainer(in: panel)?.setContentPresentation(opacity: 0, scale: 0.92)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        self.panel = panel

        // Keep the final compressed snapshot over the cutout for one commit, then let the
        // real island continue the motion. The collapse intentionally does not recolor the
        // snapshot; the cutout hides the visual handoff at this size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            transitionPanel.orderOut(nil)
            self.transitionPanel = nil
            self.expandIslandPanel(panel, on: screen, completion: completion)
        }
    }

    private func expandIslandPanel(
        _ panel: CuratezIslandPanel,
        on screen: NSScreen,
        completion: @escaping @MainActor () -> Void
    ) {
        islandAnimationDriver?.stop()
        let startFrame = handoffFrame(on: screen)
        let startSize = startFrame.size
        let endSize = islandSize
        let animationDuration: CFTimeInterval = 0.62
        let startedAt = CACurrentMediaTime()

        guard let contentView = panel.contentView else { return }
        let driver = DisplayLinkAnimationDriver()
        islandAnimationDriver = driver
        driver.start(for: contentView) { [weak self, weak panel] timestamp in
            guard let self, let panel else { return true }
            let elapsed = timestamp - startedAt
            let timeProgress = min(max(CGFloat(elapsed / animationDuration), 0), 1)
            let spring = self.springProgress(time: CGFloat(elapsed), response: 0.42, damping: 0.78)
            let size = NSSize(
                width: startSize.width + (endSize.width - startSize.width) * spring,
                height: startSize.height + (endSize.height - startSize.height) * spring
            )
            let centerX = startFrame.midX + (screen.frame.midX - startFrame.midX) * spring
            panel.setFrame(
                self.topAnchoredFrame(centeredOn: screen, size: size, centerX: centerX),
                display: true
            )

            let contentProgress = self.smoothstep((timeProgress - 0.38) / 0.44)
            self.islandContainer(in: panel)?.setContentPresentation(
                opacity: contentProgress,
                scale: 0.92 + 0.08 * contentProgress
            )
            guard timeProgress >= 1 else { return false }
            panel.setFrame(self.islandFrame(on: screen), display: true)
            self.islandContainer(in: panel)?.setContentPresentation(opacity: 1, scale: 1)
            self.islandAnimationDriver = nil
            completion()
            return true
        }
    }

    private func contractIsland(on screen: NSScreen, completion: @escaping @MainActor () -> Void) {
        guard let panel, panel.isVisible else {
            completion()
            return
        }
        islandAnimationDriver?.stop()
        let startSize = panel.frame.size
        let endFrame = handoffFrame(on: screen)
        let endSize = endFrame.size
        let animationDuration: CFTimeInterval = 0.28
        let startedAt = CACurrentMediaTime()

        guard let contentView = panel.contentView else { return }
        let driver = DisplayLinkAnimationDriver()
        islandAnimationDriver = driver
        driver.start(for: contentView) { [weak self, weak panel] timestamp in
            guard let self, let panel else { return true }
            let elapsed = timestamp - startedAt
            let linear = min(max(CGFloat(elapsed / animationDuration), 0), 1)
            let eased = self.easeInOutCubic(linear)
            let size = NSSize(
                width: startSize.width + (endSize.width - startSize.width) * eased,
                height: startSize.height + (endSize.height - startSize.height) * eased
            )
            let centerX = screen.frame.midX + (endFrame.midX - screen.frame.midX) * eased
            panel.setFrame(
                self.topAnchoredFrame(centeredOn: screen, size: size, centerX: centerX),
                display: true
            )
            let contentProgress = 1 - self.smoothstep(linear / 0.68)
            self.islandContainer(in: panel)?.setContentPresentation(
                opacity: contentProgress,
                scale: 0.92 + 0.08 * contentProgress
            )
            guard linear >= 1 else { return false }
            panel.setFrame(endFrame, display: true)
            self.islandContainer(in: panel)?.setContentPresentation(opacity: 0, scale: 0.92)
            self.islandAnimationDriver = nil
            completion()
            return true
        }
    }

    private func islandContainer(in panel: NSPanel) -> CuratezIslandContainerView? {
        panel.contentView as? CuratezIslandContainerView
    }

    private func springProgress(time: CGFloat, response: CGFloat, damping: CGFloat) -> CGFloat {
        let angularFrequency = 2 * CGFloat.pi / response
        let dampedFrequency = angularFrequency * sqrt(max(1 - damping * damping, 0.0001))
        let coefficient = damping / sqrt(max(1 - damping * damping, 0.0001))
        return 1 - exp(-damping * angularFrequency * time)
            * (cos(dampedFrequency * time) + coefficient * sin(dampedFrequency * time))
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let value = min(max(value, 0), 1)
        return value * value * (3 - 2 * value)
    }

    private func easeInOutCubic(_ value: CGFloat) -> CGFloat {
        value < 0.5
            ? 4 * value * value * value
            : 1 - pow(-2 * value + 2, 3) / 2
    }

    private func islandFrame(on screen: NSScreen) -> NSRect {
        topAnchoredFrame(centeredOn: screen, size: islandSize)
    }

    private func topAnchoredFrame(
        centeredOn screen: NSScreen,
        size: NSSize,
        centerX: CGFloat? = nil
    ) -> NSRect {
        let scale = max(screen.backingScaleFactor, 1)
        let width = (size.width * scale).rounded() / scale
        let height = (size.height * scale).rounded() / scale
        let x = (((centerX ?? screen.frame.midX) - width / 2) * scale).rounded() / scale
        return NSRect(
            x: x,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func transitionGeometry(for window: NSWindow, on screen: NSScreen) -> TransitionGeometry {
        let sourceFrame = window.frame
        let targetFrame = handoffFrame(on: screen)
        let paddedBounds = sourceFrame
            .union(targetFrame)
            .insetBy(dx: -16, dy: -16)
        let panelFrame = paddedBounds.intersection(screen.frame)

        func localTopDownRect(for globalFrame: NSRect) -> NSRect {
            NSRect(
                x: globalFrame.minX - panelFrame.minX,
                y: panelFrame.maxY - globalFrame.maxY,
                width: globalFrame.width,
                height: globalFrame.height
            )
        }

        return TransitionGeometry(
            panelFrame: panelFrame,
            sourceRect: localTopDownRect(for: sourceFrame),
            targetRect: localTopDownRect(for: targetFrame)
        )
    }

    private func handoffFrame(on screen: NSScreen) -> NSRect {
        let geometry = hardwareCutoutGeometry(on: screen)
        let size = NSSize(
            width: geometry.map { $0.width + hardwareCutoutVisualWidthCompensation }
                ?? fallbackHandoffSize.width,
            height: fallbackHandoffSize.height
        )
        return topAnchoredFrame(
            centeredOn: screen,
            size: size,
            centerX: geometry?.centerX ?? screen.frame.midX
        )
    }

    private func hardwareCutoutGeometry(on screen: NSScreen) -> (width: CGFloat, centerX: CGFloat)? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }
        let width = rightArea.minX - leftArea.maxX
        guard width > 1, screen.safeAreaInsets.top > 0 else { return nil }
        return (width, (leftArea.maxX + rightArea.minX) / 2)
    }

    private func snapshot(of window: NSWindow) -> NSImage? {
        guard let contentView = window.contentView else { return nil }
        let bounds = contentView.bounds
        guard bounds.width > 1, bounds.height > 1,
              let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func makeTransitionPanel(frame: NSRect, contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = .mainMenu + 2
        panel.contentView = contentView
        return panel
    }

    private func makePanel() -> CuratezIslandPanel {
        let panel = CuratezIslandPanel(
            contentRect: NSRect(origin: .zero, size: islandSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = CuratezIslandContainerView(
            frame: NSRect(origin: .zero, size: islandSize),
            activityController: activityController
        )
        return panel
    }
}

@MainActor
private final class GenieTransitionView: MTKView, MTKViewDelegate {
    private static var cachedPipelineState: MTLRenderPipelineState?

    private let sourceRect: NSRect
    private let targetRect: NSRect
    private let rowCount: Int
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let snapshotTexture: MTLTexture
    private let islandMaskTexture: MTLTexture

    private var progress: CGFloat = 0
    private var isAnimatingTransition = false
    private var startedAt: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.78
    private var completion: (() -> Void)?
    private var startProgress: CGFloat = 0
    private var endProgress: CGFloat = 1

    override var isOpaque: Bool { false }

    static func prewarmMetal() {
        guard cachedPipelineState == nil,
              let device = MTLCreateSystemDefaultDevice() else { return }
        cachedPipelineState = makePipelineState(device: device, sampleCount: 4)
    }

    override var isFlipped: Bool { true }

    init(
        image: NSImage,
        sourceRect: NSRect,
        targetRect: NSRect,
        backingScaleFactor: CGFloat
    ) {
        let rowCount = 240
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let vertexBuffer = device.makeBuffer(
                length: (rowCount + 1) * 2 * MemoryLayout<MetalGenieVertex>.stride,
                options: .storageModeShared
              ) else {
            fatalError("Metal is required for the morph transition")
        }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: [.interpolation: NSImageInterpolation.high]
        ) else {
            fatalError("Unable to create the transition texture")
        }
        let textureLoader = MTKTextureLoader(device: device)
        guard let snapshotTexture = try? textureLoader.newTexture(
            cgImage: cgImage,
            options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false
            ]
        ), let islandMaskTexture = Self.makeIslandMaskTexture(
            device: device,
            textureLoader: textureLoader,
            size: targetRect.size,
            scale: max(backingScaleFactor, 1)
        ) else {
            fatalError("Unable to upload the transition textures")
        }

        self.sourceRect = sourceRect
        self.targetRect = targetRect
        self.rowCount = rowCount
        self.commandQueue = commandQueue
        self.vertexBuffer = vertexBuffer
        self.snapshotTexture = snapshotTexture
        self.islandMaskTexture = islandMaskTexture
        self.pipelineState = Self.makePipelineState(device: device, sampleCount: 4)

        let vertexPointer = vertexBuffer.contents().bindMemory(
            to: MetalGenieVertex.self,
            capacity: (rowCount + 1) * 2
        )
        for row in 0...rowCount {
            let rowProgress = Float(row) / Float(rowCount)
            vertexPointer[row * 2] = MetalGenieVertex(
                meshCoordinate: SIMD2(0, rowProgress)
            )
            vertexPointer[row * 2 + 1] = MetalGenieVertex(
                meshCoordinate: SIMD2(1, rowProgress)
            )
        }
        super.init(frame: .zero, device: device)

        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        sampleCount = 4
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = true
        preferredFramesPerSecond = 120
        presentsWithTransaction = false
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare(from startProgress: CGFloat, to endProgress: CGFloat) {
        self.startProgress = startProgress
        self.endProgress = endProgress
        progress = startProgress
        isAnimatingTransition = false
        isPaused = true
    }

    func start(
        from startProgress: CGFloat,
        to endProgress: CGFloat,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        self.startProgress = startProgress
        self.endProgress = endProgress
        self.duration = duration
        self.completion = completion
        startedAt = CACurrentMediaTime()
        progress = startProgress
        isAnimatingTransition = true
        isPaused = false
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard bounds.width > 1, bounds.height > 1,
              let renderPassDescriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        var didFinish = false
        if isAnimatingTransition {
            let elapsed = CACurrentMediaTime() - startedAt
            let linearProgress = min(max(elapsed / duration, 0), 1)
            let easedProgress = easeInOutCubic(CGFloat(linearProgress))
            progress = startProgress + (endProgress - startProgress) * easedProgress
            didFinish = linearProgress >= 1
        }

        // The black silhouette is useful while expanding because it matches the real island
        // at the start of that transition. During collapse, keep the app snapshot's colors
        // intact all the way into the cutout instead of visibly fading the app to black.
        let silhouetteBlend = startProgress > endProgress
            ? smoothstep((progress - 0.72) / 0.28)
            : 0
        var uniforms = MetalGenieUniforms(
            viewportAndProgress: SIMD4(
                Float(max(bounds.width, 1)),
                Float(max(bounds.height, 1)),
                Float(progress),
                Float(silhouetteBlend)
            ),
            sourceRect: SIMD4(
                Float(sourceRect.minX),
                Float(sourceRect.minY),
                Float(sourceRect.width),
                Float(sourceRect.height)
            ),
            targetRect: SIMD4(
                Float(targetRect.minX),
                Float(targetRect.minY),
                Float(targetRect.width),
                Float(targetRect.height)
            )
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<MetalGenieUniforms>.stride,
            index: 1
        )
        encoder.setFragmentTexture(snapshotTexture, index: 0)
        encoder.setFragmentTexture(islandMaskTexture, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<MetalGenieUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: (rowCount + 1) * 2
        )
        encoder.endEncoding()
        if didFinish {
            isAnimatingTransition = false
            isPaused = true
            let completion = completion
            self.completion = nil
            if let completion {
                let presentedCompletion = PresentedFrameCompletion(completion)
                drawable.addPresentedHandler { _ in
                    presentedCompletion.callOnMainActor()
                }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipelineState(device: MTLDevice, sampleCount: Int) -> MTLRenderPipelineState {
        if let cachedPipelineState {
            return cachedPipelineState
        }
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 meshCoordinate;
        };

        struct Uniforms {
            float4 viewportAndProgress;
            float4 sourceRect;
            float4 targetRect;
        };

        struct RasterData {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        vertex RasterData genieVertex(
            const device VertexIn *vertices [[buffer(0)]],
            constant Uniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            float2 meshCoordinate = vertices[vertexID].meshCoordinate;
            float2 viewportSize = uniforms.viewportAndProgress.xy;
            float progress = uniforms.viewportAndProgress.z;
            float4 sourceRect = uniforms.sourceRect;
            float4 targetRect = uniforms.targetRect;

            float sourceTop = sourceRect.y;
            float sourceBottom = sourceRect.y + sourceRect.w;
            float targetTop = targetRect.y;
            float targetBottom = targetRect.y + targetRect.w;
            bool targetIsAbove = (targetTop + targetBottom) * 0.5
                < (sourceTop + sourceBottom) * 0.5;
            float direction = targetIsAbove ? 1.0 : -1.0;
            float farSourceY = max(direction * sourceTop, direction * sourceBottom);
            float nearSourceY = min(direction * sourceTop, direction * sourceBottom);
            float farTargetY = max(direction * targetTop, direction * targetBottom);
            float nearTargetY = min(direction * targetTop, direction * targetBottom);
            float travelRange = max(farSourceY - farTargetY, 1.0);

            float slideProgress = clamp(progress / 0.55, 0.0, 1.0);
            float translateProgress = clamp((progress - 0.32) / 0.68, 0.0, 1.0);
            float travel = farTargetY - farSourceY;
            float movingFarY = farSourceY + translateProgress * travel;
            float movingNearY = max(nearSourceY + translateProgress * travel, nearTargetY);

            float signedY = targetIsAbove
                ? mix(movingNearY, movingFarY, meshCoordinate.y)
                : mix(movingFarY, movingNearY, meshCoordinate.y);
            float y = direction * signedY;

            float sourceLeft = sourceRect.x;
            float sourceRight = sourceRect.x + sourceRect.z;
            float movingLeft = mix(sourceLeft, targetRect.x, slideProgress);
            float movingRight = mix(sourceRight, targetRect.x + targetRect.z, slideProgress);
            float normalized = clamp((signedY - farTargetY) / travelRange, 0.0, 1.0);
            float eased = normalized < 0.5
                ? 2.0 * normalized * normalized
                : 1.0 - pow(-2.0 * normalized + 2.0, 2.0) * 0.5;
            float left = signedY < farTargetY
                ? movingLeft
                : (signedY >= farSourceY ? sourceLeft : mix(movingLeft, sourceLeft, eased));
            float right = signedY < farTargetY
                ? movingRight
                : (signedY >= farSourceY ? sourceRight : mix(movingRight, sourceRight, eased));
            float x = mix(left, right, meshCoordinate.x);

            RasterData out;
            out.position = float4(
                2.0 * x / viewportSize.x - 1.0,
                1.0 - 2.0 * y / viewportSize.y,
                0.0,
                1.0
            );
            out.textureCoordinate = meshCoordinate;
            return out;
        }

        fragment float4 genieFragment(
            RasterData in [[stage_in]],
            texture2d<float> snapshot [[texture(0)]],
            texture2d<float> islandMask [[texture(1)]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            constexpr sampler textureSampler(
                mag_filter::linear,
                min_filter::linear,
                mip_filter::none,
                address::clamp_to_edge
            );
            float4 source = snapshot.sample(textureSampler, in.textureCoordinate);
            float maskAlpha = islandMask.sample(textureSampler, in.textureCoordinate).a;
            float4 target = float4(0.0, 0.0, 0.0, maskAlpha);
            return mix(source, target, uniforms.viewportAndProgress.w);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "genieVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "genieFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.rasterSampleCount = sampleCount
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            cachedPipelineState = pipelineState
            return pipelineState
        } catch {
            fatalError("Unable to create the Metal morph pipeline: \(error)")
        }
    }

    private static func makeIslandMaskTexture(
        device: MTLDevice,
        textureLoader: MTKTextureLoader,
        size: NSSize,
        scale: CGFloat
    ) -> MTLTexture? {
        let pixelWidth = max(Int(ceil(size.width * scale)), 1)
        let pixelHeight = max(Int(ceil(size.height * scale)), 1)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(curatezIslandPath(in: CGRect(origin: .zero, size: size)))
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return try? textureLoader.newTexture(
            cgImage: image,
            options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false
            ]
        )
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let value = clamp(value)
        return value * value * (3 - 2 * value)
    }

    private func easeInOutCubic(_ value: CGFloat) -> CGFloat {
        value < 0.5
            ? 4 * value * value * value
            : 1 - pow(-2 * value + 2, 3) / 2
    }
}

private struct MetalGenieVertex {
    let meshCoordinate: SIMD2<Float>
}

private struct MetalGenieUniforms {
    let viewportAndProgress: SIMD4<Float>
    let sourceRect: SIMD4<Float>
    let targetRect: SIMD4<Float>
}

private func curatezIslandPath(in rect: CGRect) -> CGPath {
    let topRadius = min(CGFloat(7), rect.height / 2)
    let bottomRadius = min(CGFloat(15), rect.height / 2)
    let leftBodyX = rect.minX + topRadius
    let rightBodyX = rect.maxX - topRadius
    let path = CGMutablePath()

    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(
        to: CGPoint(x: leftBodyX, y: rect.minY + topRadius),
        control: CGPoint(x: leftBodyX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: leftBodyX, y: rect.maxY - bottomRadius))
    path.addQuadCurve(
        to: CGPoint(x: leftBodyX + bottomRadius, y: rect.maxY),
        control: CGPoint(x: leftBodyX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rightBodyX - bottomRadius, y: rect.maxY))
    path.addQuadCurve(
        to: CGPoint(x: rightBodyX, y: rect.maxY - bottomRadius),
        control: CGPoint(x: rightBodyX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rightBodyX, y: rect.minY + topRadius))
    path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: rect.minY),
        control: CGPoint(x: rightBodyX, y: rect.minY)
    )
    path.closeSubpath()
    return path
}

private final class CuratezIslandPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        level = .mainMenu + 3
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CuratezIslandContainerView: NSView {
    private let backgroundView = NSHostingView(rootView: CuratezIslandBackgroundView())
    private let hostingView: NSHostingView<CuratezIslandView>

    init(frame frameRect: NSRect, activityController: CuratezIslandActivityController) {
        hostingView = NSHostingView(
            rootView: CuratezIslandView(activityController: activityController)
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        addSubview(backgroundView)
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContentPresentation(opacity: CGFloat, scale: CGFloat) {
        hostingView.alphaValue = min(max(opacity, 0), 1)
        hostingView.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct CuratezIslandBackgroundView: View {
    var body: some View {
        Color.black
            .clipShape(CuratezIslandShape())
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, 7)
            }
    }
}

private struct CuratezIslandView: View {
    @ObservedObject var activityController: CuratezIslandActivityController

    var body: some View {
        HStack(spacing: 10) {
            BloubAvatar(
                presentation: activityController.activity.bloubPresentation,
                palette: .paperOnInk,
                followsPointer: activityController.activity.status == .ready,
                isPaused: !activityController.isIslandVisible
            )
            .frame(width: 20, height: 20)

            Text("Curatez")
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 12)

            Text("⌘⌃ 展开")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CuratezIslandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topRadius: CGFloat = 7
        let bottomRadius: CGFloat = 15
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
