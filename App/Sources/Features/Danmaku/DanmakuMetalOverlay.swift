import CoreGraphics
import CoreText
import Foundation
import OSLog
import SwiftUI
import simd

#if canImport(MetalKit)
    import Metal
    import MetalKit

    #if canImport(AppKit)
        import AppKit
    #elseif canImport(UIKit)
        import UIKit
    #endif

    struct DanmakuMetalOverlay: View {
        let renderer: DanmakuRendererStore
        let timebase: PlaybackTimebase
        let viewport: CGSize
        let metrics: DanmakuLayoutMetrics

        var body: some View {
            if MTLCreateSystemDefaultDevice() == nil {
                Text("Danmaku requires Metal support.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 120.0,
                        paused: timebase.paused || !timebase.loaded
                    )
                ) { context in
                    DanmakuMetalContainerView(
                        renderer: renderer,
                        playbackTime: timebase.resolvedPosition(
                            at: context.date
                        ),
                        viewportSize: viewport,
                        metrics: metrics
                    )
                }
            }
        }
    }

    @MainActor
    func makeDanmakuMetalCaptureOverlay(
        store: DanmakuRendererStore,
        playbackTime: Double,
        viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics,
        outputSize: CGSize? = nil,
        contentScale: CGFloat = 1
    ) -> CGImage? {
        DanmakuMetalCaptureService.shared.capture(
            store: store,
            playbackTime: playbackTime,
            viewportSize: viewportSize,
            metrics: metrics,
            outputSize: outputSize,
            contentScale: contentScale
        )
    }

    #if os(macOS)
        private final class PassthroughDanmakuMTKView: MTKView {
            var onLayoutChange: ((PassthroughDanmakuMTKView) -> Void)?

            override var isOpaque: Bool { false }

            override func hitTest(_ point: NSPoint) -> NSView? {
                nil
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                onLayoutChange?(self)
            }

            override func layout() {
                super.layout()
                onLayoutChange?(self)
            }

            override func viewDidChangeBackingProperties() {
                super.viewDidChangeBackingProperties()
                onLayoutChange?(self)
            }
        }

        private struct DanmakuMetalContainerView: NSViewRepresentable {
            let renderer: DanmakuRendererStore
            let playbackTime: Double
            let viewportSize: CGSize
            let metrics: DanmakuLayoutMetrics

            func makeCoordinator() -> DanmakuMetalCoordinator {
                DanmakuMetalCoordinator(store: renderer)
            }

            func makeNSView(context: Context) -> PassthroughDanmakuMTKView {
                context.coordinator.makeView()
            }

            func updateNSView(
                _ view: PassthroughDanmakuMTKView,
                context: Context
            ) {
                context.coordinator.update(
                    view: view,
                    playbackTime: playbackTime,
                    viewportSize: viewportSize,
                    metrics: metrics
                )
            }
        }
    #else
        private final class PassthroughDanmakuMTKView: MTKView {
            var onLayoutChange: ((PassthroughDanmakuMTKView) -> Void)?

            override func point(
                inside point: CGPoint,
                with event: UIEvent?
            ) -> Bool {
                false
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                onLayoutChange?(self)
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                onLayoutChange?(self)
            }

            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                onLayoutChange?(self)
            }

            override func safeAreaInsetsDidChange() {
                super.safeAreaInsetsDidChange()
                onLayoutChange?(self)
            }

            override func traitCollectionDidChange(
                _ previousTraitCollection: UITraitCollection?
            ) {
                super.traitCollectionDidChange(previousTraitCollection)
                onLayoutChange?(self)
            }
        }

        private struct DanmakuMetalContainerView: UIViewRepresentable {
            let renderer: DanmakuRendererStore
            let playbackTime: Double
            let viewportSize: CGSize
            let metrics: DanmakuLayoutMetrics

            func makeCoordinator() -> DanmakuMetalCoordinator {
                DanmakuMetalCoordinator(store: renderer)
            }

            func makeUIView(context: Context) -> PassthroughDanmakuMTKView {
                context.coordinator.makeView()
            }

            func updateUIView(
                _ view: PassthroughDanmakuMTKView,
                context: Context
            ) {
                context.coordinator.update(
                    view: view,
                    playbackTime: playbackTime,
                    viewportSize: viewportSize,
                    metrics: metrics
                )
            }
        }
    #endif

    @MainActor
    private final class DanmakuMetalCoordinator: NSObject, MTKViewDelegate {
        private static let logger = Logger(
            subsystem: "Starmine",
            category: "DanmakuMetalCoordinator"
        )

        private let store: DanmakuRendererStore
        private let device = MTLCreateSystemDefaultDevice()
        private var latestPlaybackTime = 0.0
        private var latestRequestedViewportSize: CGSize = .zero
        private var latestMetrics: DanmakuLayoutMetrics = .playbackChrome
        private lazy var metalRenderer: DanmakuMetalRenderer? = {
            guard let device else {
                Self.logger.fault(
                    "Metal device unavailable for danmaku overlay"
                )
                return nil
            }
            return DanmakuMetalRenderer(device: device)
        }()

        init(store: DanmakuRendererStore) {
            self.store = store
        }

        func makeView() -> PassthroughDanmakuMTKView {
            let view = PassthroughDanmakuMTKView(frame: .zero, device: device)
            view.delegate = self
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.clearColor = MTLClearColorMake(0, 0, 0, 0)
            view.colorPixelFormat = .bgra8Unorm
            view.sampleCount = 1
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            #if os(iOS) || os(tvOS) || os(visionOS)
                view.isOpaque = false
                view.backgroundColor = .clear
                view.layer.isOpaque = false
                view.layer.backgroundColor = UIColor.clear.cgColor
                view.isUserInteractionEnabled = false
            #else
                view.wantsLayer = true
                view.layer?.isOpaque = false
                view.layer?.backgroundColor = NSColor.clear.cgColor
            #endif
            if let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.isOpaque = false
                metalLayer.backgroundColor = CGColor(
                    red: 0,
                    green: 0,
                    blue: 0,
                    alpha: 0
                )
                metalLayer.pixelFormat = .bgra8Unorm
                metalLayer.framebufferOnly = false
            }
            view.onLayoutChange = { [weak self] updatedView in
                self?.redrawUsingLatestState(on: updatedView)
            }
            return view
        }

        func update(
            view: MTKView,
            playbackTime: Double,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics
        ) {
            latestPlaybackTime = playbackTime
            latestRequestedViewportSize = viewportSize
            latestMetrics = metrics

            refresh(
                view: view,
                playbackTime: playbackTime,
                requestedViewportSize: viewportSize,
                metrics: metrics
            )
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else {
                scheduleDeferredRedraw(for: view)
                return
            }
            guard drawableMatchesView(drawable, view: view) else {
                scheduleDeferredRedraw(for: view)
                return
            }
            guard
                let descriptor = view.currentRenderPassDescriptor,
                renderPassDescriptor(descriptor, matches: drawable)
            else {
                scheduleDeferredRedraw(for: view)
                return
            }
            metalRenderer?.draw(descriptor: descriptor, drawable: drawable)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func redrawUsingLatestState(on view: PassthroughDanmakuMTKView)
        {
            let resolvedViewportSize = view.bounds.size
            guard
                resolvedViewportSize.width > 0.5,
                resolvedViewportSize.height > 0.5
            else {
                return
            }

            refresh(
                view: view,
                playbackTime: latestPlaybackTime,
                requestedViewportSize: resolvedViewportSize,
                metrics: latestMetrics
            )
        }

        private func refresh(
            view: MTKView,
            playbackTime: Double,
            requestedViewportSize: CGSize,
            metrics: DanmakuLayoutMetrics
        ) {
            let viewportSize = resolvedViewportSize(
                for: view,
                requestedViewportSize: requestedViewportSize
            )
            guard viewportSize.width > 0, viewportSize.height > 0 else {
                return
            }

            let scaleFactor = resolvedScaleFactor(for: view)
            #if os(iOS) || os(tvOS) || os(visionOS)
                view.contentScaleFactor = scaleFactor
                view.layer.contentsScale = scaleFactor
            #endif
            let drawableSize = CGSize(
                width: ceil(viewportSize.width * scaleFactor),
                height: ceil(viewportSize.height * scaleFactor)
            )
            let drawableSizeChanged =
                abs(view.drawableSize.width - drawableSize.width) > 0.5
                || abs(view.drawableSize.height - drawableSize.height) > 0.5
            if drawableSizeChanged {
                view.drawableSize = drawableSize
            }
            if let metalLayer = view.layer as? CAMetalLayer {
                let layerDrawableSizeChanged =
                    abs(metalLayer.drawableSize.width - drawableSize.width)
                    > 0.5
                    || abs(metalLayer.drawableSize.height - drawableSize.height)
                        > 0.5
                if layerDrawableSizeChanged {
                    metalLayer.drawableSize = drawableSize
                }
            }

            store.sync(
                playbackTime: playbackTime,
                viewportSize: viewportSize,
                metrics: metrics
            )

            metalRenderer?.prepareFrame(
                store: store,
                playbackTime: playbackTime,
                viewportSize: viewportSize,
                metrics: metrics,
                contentScale: Float(scaleFactor)
            )

            if drawableSizeChanged {
                scheduleDeferredRedraw(for: view)
            } else {
                view.draw()
            }
        }

        private func resolvedViewportSize(
            for view: MTKView,
            requestedViewportSize: CGSize
        ) -> CGSize {
            let boundsSize = view.bounds.size
            if boundsSize.width > 0.5, boundsSize.height > 0.5 {
                return boundsSize
            }
            if requestedViewportSize.width > 0.5,
                requestedViewportSize.height > 0.5
            {
                return requestedViewportSize
            }
            return .zero
        }

        private func resolvedScaleFactor(for view: MTKView) -> CGFloat {
            #if os(macOS)
                view.window?.screen?.backingScaleFactor ?? NSScreen.main?
                    .backingScaleFactor ?? 2
            #else
                view.window?.screen.scale ?? UIScreen.main.scale
            #endif
        }

        private func scheduleDeferredRedraw(for view: MTKView) {
            DispatchQueue.main.async { [weak view] in
                view?.draw()
            }
        }

        private func drawableMatchesView(
            _ drawable: CAMetalDrawable,
            view: MTKView
        ) -> Bool {
            let expectedDrawableSize = view.drawableSize
            guard
                expectedDrawableSize.width > 0.5,
                expectedDrawableSize.height > 0.5
            else {
                return false
            }

            return
                abs(
                    CGFloat(drawable.texture.width) - expectedDrawableSize.width
                )
                <= 1
                && abs(
                    CGFloat(drawable.texture.height)
                        - expectedDrawableSize.height
                ) <= 1
        }

        private func renderPassDescriptor(
            _ descriptor: MTLRenderPassDescriptor,
            matches drawable: CAMetalDrawable
        ) -> Bool {
            guard let colorAttachment = descriptor.colorAttachments[0].texture
            else {
                return false
            }

            return colorAttachment.width == drawable.texture.width
                && colorAttachment.height == drawable.texture.height
        }
    }

    private enum GlyphBuildMode {
        case asynchronous
        case synchronous
    }

    @MainActor
    private final class DanmakuMetalRenderer {
        private static let logger = Logger(
            subsystem: "Starmine",
            category: "DanmakuMetalRenderer"
        )

        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let renderPipeline: MTLRenderPipelineState
        private let computePipeline: MTLComputePipelineState
        private let samplerState: MTLSamplerState
        private let atlas: DynamicMSDFAtlas

        private var commentBuffer: MTLBuffer?
        private var glyphStaticBuffer: MTLBuffer?
        private var glyphRenderBuffer: MTLBuffer?
        private var uniformBuffer: MTLBuffer?
        private var glyphCount = 0

        private var preparedVersion: UInt64 = .max
        private var preparedViewport: CGSize = .zero
        private var preparedMetrics: DanmakuLayoutMetrics = .playbackChrome
        private var preparedFontSignature: FontSignature?
        private var preparedAtlasRevision: UInt64 = .max
        private var frameUniforms = GPUDanmakuUniforms()

        init?(device: MTLDevice) {
            self.device = device
            guard let commandQueue = device.makeCommandQueue() else {
                return nil
            }
            self.commandQueue = commandQueue
            atlas = DynamicMSDFAtlas(device: device)

            let library: MTLLibrary
            do {
                library = try device.makeLibrary(
                    source: Self.shaderSource,
                    options: nil
                )
            } catch {
                Self.logger.error(
                    "Failed to compile danmaku Metal library: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }

            guard
                let vertexFunction = library.makeFunction(
                    name: "danmakuVertexMain"
                ),
                let fragmentFunction = library.makeFunction(
                    name: "danmakuFragmentMain"
                ),
                let computeFunction = library.makeFunction(
                    name: "danmakuComputeMain"
                )
            else {
                Self.logger.error(
                    "Failed to resolve danmaku Metal shader functions"
                )
                return nil
            }

            let renderDescriptor = MTLRenderPipelineDescriptor()
            renderDescriptor.vertexFunction = vertexFunction
            renderDescriptor.fragmentFunction = fragmentFunction
            renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            renderDescriptor.colorAttachments[0].isBlendingEnabled = true
            renderDescriptor.colorAttachments[0].rgbBlendOperation = .add
            renderDescriptor.colorAttachments[0].alphaBlendOperation = .add
            renderDescriptor.colorAttachments[0].sourceRGBBlendFactor =
                .sourceAlpha
            renderDescriptor.colorAttachments[0].sourceAlphaBlendFactor =
                .sourceAlpha
            renderDescriptor.colorAttachments[0].destinationRGBBlendFactor =
                .oneMinusSourceAlpha
            renderDescriptor.colorAttachments[0].destinationAlphaBlendFactor =
                .oneMinusSourceAlpha

            guard
                let renderPipeline = try? device.makeRenderPipelineState(
                    descriptor: renderDescriptor
                ),
                let computePipeline = try? device.makeComputePipelineState(
                    function: computeFunction
                )
            else {
                Self.logger.error("Failed to build danmaku Metal pipelines")
                return nil
            }

            self.renderPipeline = renderPipeline
            self.computePipeline = computePipeline

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.mipFilter = .notMipmapped
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            guard
                let samplerState = device.makeSamplerState(
                    descriptor: samplerDescriptor
                )
            else {
                Self.logger.error(
                    "Failed to create danmaku Metal sampler state"
                )
                return nil
            }
            self.samplerState = samplerState
        }

        func prepareFrame(
            store: DanmakuRendererStore,
            playbackTime: Double,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            contentScale: Float,
            glyphBuildMode: GlyphBuildMode = .asynchronous
        ) {
            let configuration = store.configuration
            let fontSignature = FontSignature(configuration: configuration)
            atlas.prepare(configuration: configuration)
            _ = atlas.applyCompletedGlyphs()
            let atlasRevision = atlas.revision

            if preparedVersion != store.contentVersion
                || preparedViewport != viewportSize
                || preparedMetrics != metrics
                || preparedFontSignature != fontSignature
                || preparedAtlasRevision != atlasRevision
            {
                rebuildBuffers(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    configuration: configuration,
                    glyphBuildMode: glyphBuildMode
                )
                preparedVersion = store.contentVersion
                preparedViewport = viewportSize
                preparedMetrics = metrics
                preparedFontSignature = fontSignature
                preparedAtlasRevision = atlas.revision
            }

            frameUniforms = GPUDanmakuUniforms(
                viewportSize: SIMD2(
                    Float(viewportSize.width),
                    Float(viewportSize.height)
                ),
                playbackTime: Float(playbackTime),
                horizontalInset: Float(metrics.horizontalInset),
                contentScale: contentScale,
                msdfPixelRange: atlas.msdfPixelRange,
                outlineWidth: Float(
                    configuration.resolvedFontSize
                        * (max(2, configuration.resolvedFontSize * 0.16) / 100)
                ),
                glyphCount: UInt32(glyphCount)
            )

            uniformBuffer = Self.makeBuffer(
                device: device,
                value: frameUniforms
            )
        }

        func draw(
            descriptor: MTLRenderPassDescriptor,
            drawable: CAMetalDrawable
        ) {
            guard
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                return
            }
            encodeFrame(
                commandBuffer: commandBuffer,
                descriptor: descriptor
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func renderOffscreen(
            store: DanmakuRendererStore,
            playbackTime: Double,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            outputSize: CGSize,
            contentScale: Float
        ) -> CGImage? {
            prepareFrame(
                store: store,
                playbackTime: playbackTime,
                viewportSize: viewportSize,
                metrics: metrics,
                contentScale: contentScale,
                glyphBuildMode: .synchronous
            )

            let pixelWidth = max(
                1,
                Int(outputSize.width.rounded(.toNearestOrAwayFromZero))
            )
            let pixelHeight = max(
                1,
                Int(outputSize.height.rounded(.toNearestOrAwayFromZero))
            )
            guard
                let texture = Self.makeCaptureTexture(
                    device: device,
                    width: pixelWidth,
                    height: pixelHeight
                ),
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(
                0,
                0,
                0,
                0
            )

            encodeFrame(
                commandBuffer: commandBuffer,
                descriptor: descriptor
            )

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            guard commandBuffer.status == .completed else {
                return nil
            }

            return Self.makeImage(from: texture)
        }

        private func encodeFrame(
            commandBuffer: MTLCommandBuffer,
            descriptor: MTLRenderPassDescriptor
        ) {
            if glyphCount > 0,
                let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
                let commentBuffer,
                let glyphStaticBuffer,
                let glyphRenderBuffer,
                let uniformBuffer
            {
                computeEncoder.setComputePipelineState(computePipeline)
                computeEncoder.setBuffer(commentBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(glyphStaticBuffer, offset: 0, index: 1)
                computeEncoder.setBuffer(glyphRenderBuffer, offset: 0, index: 2)
                computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 3)

                let threadgroupWidth = max(
                    1,
                    min(
                        computePipeline.threadExecutionWidth,
                        computePipeline.maxTotalThreadsPerThreadgroup
                    )
                )
                let threadsPerThreadgroup = MTLSize(
                    width: threadgroupWidth,
                    height: 1,
                    depth: 1
                )
                let threadgroups = MTLSize(
                    width: (glyphCount + threadgroupWidth - 1)
                        / threadgroupWidth,
                    height: 1,
                    depth: 1
                )
                computeEncoder.dispatchThreadgroups(
                    threadgroups,
                    threadsPerThreadgroup: threadsPerThreadgroup
                )
                computeEncoder.endEncoding()
            }

            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            ) {
                renderEncoder.setRenderPipelineState(renderPipeline)
                renderEncoder.setFragmentSamplerState(samplerState, index: 0)
                renderEncoder.setFragmentTexture(atlas.texture, index: 0)

                if glyphCount > 0,
                    let glyphRenderBuffer,
                    let uniformBuffer
                {
                    renderEncoder.setVertexBuffer(
                        glyphRenderBuffer,
                        offset: 0,
                        index: 0
                    )
                    renderEncoder.setVertexBuffer(
                        uniformBuffer,
                        offset: 0,
                        index: 1
                    )
                    renderEncoder.setFragmentBuffer(
                        uniformBuffer,
                        offset: 0,
                        index: 0
                    )
                    renderEncoder.drawPrimitives(
                        type: .triangleStrip,
                        vertexStart: 0,
                        vertexCount: 4,
                        instanceCount: glyphCount
                    )
                }

                renderEncoder.endEncoding()
            }
        }

        private func rebuildBuffers(
            store: DanmakuRendererStore,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            configuration: DanmakuRenderConfiguration,
            glyphBuildMode: GlyphBuildMode
        ) {
            do {
                let snapshot = try buildSnapshot(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    configuration: configuration,
                    glyphBuildMode: glyphBuildMode
                )

                glyphCount = snapshot.glyphs.count
                commentBuffer = Self.makeBuffer(
                    device: device,
                    array: snapshot.comments
                )
                glyphStaticBuffer = Self.makeBuffer(
                    device: device,
                    array: snapshot.glyphs
                )
                glyphRenderBuffer = Self.makeBuffer(
                    device: device,
                    repeating: GPURenderGlyphInstance(),
                    count: max(snapshot.glyphs.count, 1)
                )
            } catch {
                Self.logger.error(
                    "Failed to rebuild danmaku buffers: \(error.localizedDescription, privacy: .public)"
                )
                glyphCount = 0
                commentBuffer = nil
                glyphStaticBuffer = nil
                glyphRenderBuffer = nil
            }
        }

        private func buildSnapshot(
            store: DanmakuRendererStore,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            configuration: DanmakuRenderConfiguration,
            glyphBuildMode: GlyphBuildMode
        ) throws -> PreparedSnapshot {
            let font = configuration.fontStyle.ctFont(
                ofSize: configuration.resolvedFontSize
            )

            do {
                return try buildSnapshotPass(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    font: font,
                    configuration: configuration,
                    glyphBuildMode: glyphBuildMode
                )
            } catch DynamicMSDFAtlas.AtlasError.restartBuild {
                return try buildSnapshotPass(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    font: font,
                    configuration: configuration,
                    glyphBuildMode: glyphBuildMode
                )
            }
        }

        private func buildSnapshotPass(
            store: DanmakuRendererStore,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            font: CTFont,
            configuration: DanmakuRenderConfiguration,
            glyphBuildMode: GlyphBuildMode
        ) throws -> PreparedSnapshot {
            var comments: [GPUCommentState] = []
            var glyphs: [GPUStaticGlyphInstance] = []
            comments.reserveCapacity(store.activeItems.count)

            for item in store.activeItems {
                let anchorY = Float(
                    store.point(
                        for: item,
                        playbackTime: max(item.startTime, item.comment.time),
                        viewportSize: viewportSize,
                        metrics: metrics
                    ).y
                )

                let commentIndex = UInt32(comments.count)
                comments.append(
                    GPUCommentState(
                        startTime: Float(item.startTime),
                        duration: Float(item.duration),
                        width: Float(item.widthEstimate),
                        anchorY: anchorY,
                        region: item.region.gpuValue
                    )
                )

                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: item.comment.text,
                        attributes: [
                            kCTFontAttributeName as NSAttributedString.Key: font
                        ]
                    )
                )
                let lineBounds = CTLineGetBoundsWithOptions(
                    line,
                    [.useGlyphPathBounds, .excludeTypographicLeading]
                )
                let renderCenterX = lineBounds.isNull ? 0 : lineBounds.midX
                let renderCenterY = lineBounds.isNull ? 0 : lineBounds.midY
                let runs = CTLineGetGlyphRuns(line) as NSArray

                for case let run as CTRun in runs {
                    let glyphCount = CTRunGetGlyphCount(run)
                    guard glyphCount > 0 else { continue }

                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let runFont =
                        (attributes[kCTFontAttributeName] as! CTFont?) ?? font

                    var runGlyphs = Array(
                        repeating: CGGlyph(),
                        count: glyphCount
                    )
                    var positions = Array(
                        repeating: CGPoint.zero,
                        count: glyphCount
                    )
                    CTRunGetGlyphs(
                        run,
                        CFRangeMake(0, 0),
                        &runGlyphs
                    )
                    CTRunGetPositions(
                        run,
                        CFRangeMake(0, 0),
                        &positions
                    )

                    for index in 0..<glyphCount {
                        let glyph = runGlyphs[index]
                        guard
                            let atlasEntry = try atlas.entry(
                                for: glyph,
                                font: runFont,
                                mode: glyphBuildMode
                            )
                        else {
                            continue
                        }

                        let quadRect = atlasEntry.planeBounds.offsetBy(
                            dx: positions[index].x,
                            dy: positions[index].y
                        )
                        glyphs.append(
                            GPUStaticGlyphInstance(
                                commentIndex: commentIndex,
                                offset: SIMD2(
                                    Float(quadRect.midX - renderCenterX),
                                    Float(renderCenterY - quadRect.midY)
                                ),
                                size: SIMD2(
                                    Float(quadRect.width),
                                    Float(quadRect.height)
                                ),
                                uvMin: atlasEntry.uvMin,
                                uvMax: atlasEntry.uvMax,
                                color: item.comment.color.metalRGBA(
                                    opacity: configuration.opacity
                                )
                            )
                        )
                    }
                }
            }

            return PreparedSnapshot(comments: comments, glyphs: glyphs)
        }

        private static func makeBuffer<T>(
            device: MTLDevice,
            value: T
        ) -> MTLBuffer? {
            var copy = value
            let size = MemoryLayout<T>.size
            let stride = MemoryLayout<T>.stride
            guard
                let buffer = device.makeBuffer(
                    length: stride,
                    options: .storageModeShared
                )
            else {
                return nil
            }

            // Metal validates constant-buffer arguments against the struct's
            // padded stride, not Swift's unpadded size.
            buffer.contents().initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: stride
            )
            return withUnsafeBytes(of: &copy) { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress, size > 0 {
                    buffer.contents().copyMemory(
                        from: baseAddress,
                        byteCount: size
                    )
                }
                return buffer
            }
        }

        private static func makeBuffer<T>(
            device: MTLDevice,
            array: [T]
        ) -> MTLBuffer? {
            guard !array.isEmpty else { return nil }
            return array.withUnsafeBytes { rawBuffer in
                device.makeBuffer(
                    bytes: rawBuffer.baseAddress!,
                    length: rawBuffer.count,
                    options: .storageModeShared
                )
            }
        }

        private static func makeBuffer<T>(
            device: MTLDevice,
            repeating value: T,
            count: Int
        ) -> MTLBuffer? {
            let array = Array(repeating: value, count: count)
            return makeBuffer(device: device, array: array)
        }

        private static func makeCaptureTexture(
            device: MTLDevice,
            width: Int,
            height: Int
        ) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget]
            return device.makeTexture(descriptor: descriptor)
        }

        private static func makeImage(from texture: MTLTexture) -> CGImage? {
            let bytesPerPixel = 4
            let bytesPerRow = texture.width * bytesPerPixel
            let byteCount = bytesPerRow * texture.height
            var bytes = Array(repeating: UInt8(0), count: byteCount)
            bytes.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                texture.getBytes(
                    baseAddress,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0
                )
            }

            let colorSpace =
                CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                )
            )
            let data = Data(bytes)
            guard let provider = CGDataProvider(data: data as CFData) else {
                return nil
            }
            return CGImage(
                width: texture.width,
                height: texture.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }

        private static let shaderSource = #"""
            #include <metal_stdlib>
            using namespace metal;

            struct GPUCommentState {
                float startTime;
                float duration;
                float width;
                float anchorY;
                uint region;
            };

            struct GPUStaticGlyphInstance {
                uint commentIndex;
                float2 offset;
                float2 size;
                float2 uvMin;
                float2 uvMax;
                float4 color;
            };

            struct GPURenderGlyphInstance {
                float2 center;
                float2 size;
                float2 uvMin;
                float2 uvMax;
                float4 color;
            };

            struct GPUDanmakuUniforms {
                float2 viewportSize;
                float playbackTime;
                float horizontalInset;
                float contentScale;
                float msdfPixelRange;
                float outlineWidth;
                uint glyphCount;
                uint _padding;
            };

            struct VertexOut {
                float4 position [[position]];
                float2 uv;
                float4 color;
            };

            constant uint DanmakuRegionScroll = 0;

            kernel void danmakuComputeMain(
                device const GPUCommentState *comments [[buffer(0)]],
                device const GPUStaticGlyphInstance *glyphs [[buffer(1)]],
                device GPURenderGlyphInstance *renderGlyphs [[buffer(2)]],
                constant GPUDanmakuUniforms &uniforms [[buffer(3)]],
                uint id [[thread_position_in_grid]]
            ) {
                if (id >= uniforms.glyphCount) {
                    return;
                }

                GPUStaticGlyphInstance glyph = glyphs[id];
                GPUCommentState comment = comments[glyph.commentIndex];

                float anchorX = uniforms.viewportSize.x * 0.5;
                if (comment.region == DanmakuRegionScroll) {
                    float progress = clamp(
                        (uniforms.playbackTime - comment.startTime) / max(comment.duration, 0.0001),
                        0.0,
                        1.0
                    );
                    float minX = uniforms.horizontalInset - comment.width * 0.5;
                    float maxX = uniforms.viewportSize.x - uniforms.horizontalInset + comment.width * 0.5;
                    anchorX = mix(maxX, minX, progress);
                }

                GPURenderGlyphInstance outGlyph;
                outGlyph.center = float2(anchorX, comment.anchorY) + glyph.offset;
                outGlyph.size = glyph.size;
                outGlyph.uvMin = glyph.uvMin;
                outGlyph.uvMax = glyph.uvMax;
                outGlyph.color = glyph.color;

                if (uniforms.playbackTime < comment.startTime
                    || uniforms.playbackTime > comment.startTime + comment.duration) {
                    outGlyph.color.a = 0.0;
                }

                renderGlyphs[id] = outGlyph;
            }

            vertex VertexOut danmakuVertexMain(
                uint vertexID [[vertex_id]],
                uint instanceID [[instance_id]],
                device const GPURenderGlyphInstance *glyphs [[buffer(0)]],
                constant GPUDanmakuUniforms &uniforms [[buffer(1)]]
            ) {
                const float2 quad[4] = {
                    float2(-0.5, -0.5),
                    float2( 0.5, -0.5),
                    float2(-0.5,  0.5),
                    float2( 0.5,  0.5),
                };
                const float2 uvQuad[4] = {
                    float2(0.0, 1.0),
                    float2(1.0, 1.0),
                    float2(0.0, 0.0),
                    float2(1.0, 0.0),
                };

                GPURenderGlyphInstance glyph = glyphs[instanceID];
                float2 point = glyph.center + quad[vertexID] * glyph.size;
                float2 ndc = float2(
                    point.x / max(uniforms.viewportSize.x, 0.0001) * 2.0 - 1.0,
                    1.0 - point.y / max(uniforms.viewportSize.y, 0.0001) * 2.0
                );

                VertexOut outVertex;
                outVertex.position = float4(ndc, 0.0, 1.0);
                outVertex.uv = mix(glyph.uvMin, glyph.uvMax, uvQuad[vertexID]);
                outVertex.color = glyph.color;
                return outVertex;
            }

            float median(float a, float b, float c) {
                return max(min(a, b), min(max(a, b), c));
            }

            fragment float4 danmakuFragmentMain(
                VertexOut in [[stage_in]],
                constant GPUDanmakuUniforms &uniforms [[buffer(0)]],
                texture2d<float> atlas [[texture(0)]],
                sampler atlasSampler [[sampler(0)]]
            ) {
                if (in.color.a <= 0.0) {
                    discard_fragment();
                }

                float3 sample = atlas.sample(atlasSampler, in.uv).rgb;
                float signedDistance =
                    median(sample.r, sample.g, sample.b) - 0.5;
                float2 unitRange = float2(uniforms.msdfPixelRange)
                    / float2(atlas.get_width(), atlas.get_height());
                float2 screenTexSize = 1.0 / max(
                    fwidth(in.uv),
                    float2(0.000001)
                );
                float screenPxRange = max(
                    1.0,
                    0.5 * dot(unitRange, screenTexSize)
                );
                float screenPxDistance = signedDistance * screenPxRange;
                float desiredOutlineWidth = max(
                    0.0,
                    uniforms.outlineWidth * uniforms.contentScale
                );
                float outlineWidth = min(
                    desiredOutlineWidth,
                    max(screenPxRange * 0.5 - 0.5, 0.0)
                );
                float fillShape = clamp(screenPxDistance + 0.5, 0.0, 1.0);
                float outlineShape = clamp(
                    screenPxDistance + outlineWidth + 0.5,
                    0.0,
                    1.0
                );
                float fillAlpha = fillShape * in.color.a;
                float outlineAlpha = max(outlineShape - fillShape, 0.0)
                    * in.color.a;
                float totalAlpha = fillAlpha + outlineAlpha * (1.0 - fillAlpha);
                if (totalAlpha <= 0.001) {
                    discard_fragment();
                }

                float3 rgb = in.color.rgb * (fillAlpha / max(totalAlpha, 0.0001));
                return float4(rgb, totalAlpha);
            }
            """#
    }

    @MainActor
    private final class DanmakuMetalCaptureService {
        static let shared = DanmakuMetalCaptureService()

        private let device = MTLCreateSystemDefaultDevice()
        private lazy var renderer: DanmakuMetalRenderer? = {
            guard let device else { return nil }
            return DanmakuMetalRenderer(device: device)
        }()

        func capture(
            store: DanmakuRendererStore,
            playbackTime: Double,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            outputSize: CGSize?,
            contentScale: CGFloat
        ) -> CGImage? {
            let resolvedOutputSize =
                outputSize
                ?? CGSize(
                    width: viewportSize.width * contentScale,
                    height: viewportSize.height * contentScale
                )
            return renderer?.renderOffscreen(
                store: store,
                playbackTime: playbackTime,
                viewportSize: viewportSize,
                metrics: metrics,
                outputSize: resolvedOutputSize,
                contentScale: Float(contentScale)
            )
        }
    }

    private final class DynamicMSDFAtlas {
        enum AtlasError: Error {
            case restartBuild
        }

        private static let logger = Logger(
            subsystem: "Starmine",
            category: "DynamicMSDFAtlas"
        )

        struct GlyphEntry {
            let planeBounds: CGRect
            let uvMin: SIMD2<Float>
            let uvMax: SIMD2<Float>
        }

        private struct GlyphCacheKey: Hashable {
            let glyph: CGGlyph
            let fontName: String
            let fontSizeQuarterPoints: Int

            init(glyph: CGGlyph, font: CTFont) {
                self.glyph = glyph
                fontName = CTFontCopyPostScriptName(font) as String
                fontSizeQuarterPoints = Int((CTFontGetSize(font) * 4).rounded())
            }
        }

        private struct CompletedGlyph {
            let key: GlyphCacheKey
            let planeBounds: CGRect
            let bitmapWidth: Int
            let bitmapHeight: Int
            let bitmap: [UInt8]
            let epoch: UInt64
        }

        private let device: MTLDevice
        private let atlasSize: Int
        private let pixelRange: Int
        private let atlasScale: CGFloat
        private let generationQueue = DispatchQueue(
            label: "Starmine.DynamicMSDFAtlas",
            qos: .userInitiated
        )
        private let stateLock = NSLock()

        private(set) var texture: MTLTexture
        var msdfPixelRange: Float { Float(pixelRange) }
        private(set) var revision: UInt64 = 0
        private var configurationSignature: FontSignature?
        private var nextOrigin = SIMD2<Int>(0, 0)
        private var currentRowHeight = 0
        private var glyphCache: [GlyphCacheKey: GlyphEntry] = [:]
        private var generationEpoch: UInt64 = 0
        private var pendingGlyphs: Set<GlyphCacheKey> = []
        private var completedGlyphs: [CompletedGlyph] = []

        init(
            device: MTLDevice,
            atlasSize: Int = 4096,
            pixelRange: Int = 6,
            atlasScale: CGFloat = 3
        ) {
            self.device = device
            self.atlasSize = atlasSize
            self.pixelRange = pixelRange
            self.atlasScale = atlasScale
            texture = Self.makeTexture(device: device, size: atlasSize)
        }

        func prepare(configuration: DanmakuRenderConfiguration) {
            let signature = FontSignature(configuration: configuration)
            guard signature != configurationSignature else { return }
            configurationSignature = signature
            resetKeepingConfiguration()
        }

        func applyCompletedGlyphs() -> Bool {
            let completedGlyphs = drainCompletedGlyphs()
            guard !completedGlyphs.isEmpty else { return false }

            do {
                try apply(completedGlyphs: completedGlyphs)
            } catch AtlasError.restartBuild {
                resetKeepingConfiguration()
            } catch {
                Self.logger.error(
                    "Failed to upload completed MSDF glyphs: \(error.localizedDescription, privacy: .public)"
                )
            }

            return true
        }

        func resetKeepingConfiguration() {
            nextOrigin = SIMD2<Int>(0, 0)
            currentRowHeight = 0
            glyphCache.removeAll(keepingCapacity: true)
            texture = Self.makeTexture(device: device, size: atlasSize)
            revision &+= 1

            stateLock.lock()
            generationEpoch &+= 1
            pendingGlyphs.removeAll(keepingCapacity: true)
            completedGlyphs.removeAll(keepingCapacity: true)
            stateLock.unlock()
        }

        func entry(
            for glyph: CGGlyph,
            font: CTFont,
            mode: GlyphBuildMode = .asynchronous
        ) throws -> GlyphEntry? {
            let cacheKey = GlyphCacheKey(glyph: glyph, font: font)
            if let cached = glyphCache[cacheKey] {
                return cached
            }

            switch mode {
            case .asynchronous:
                enqueueBuildIfNeeded(for: cacheKey, glyph: glyph, font: font)
                return nil
            case .synchronous:
                return try buildGlyphSynchronouslyIfNeeded(
                    for: cacheKey,
                    glyph: glyph,
                    font: font
                )
            }
        }

        private func buildGlyphSynchronouslyIfNeeded(
            for key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont
        ) throws -> GlyphEntry? {
            if let cached = glyphCache[key] {
                return cached
            }

            stateLock.lock()
            let epoch = generationEpoch
            stateLock.unlock()

            guard
                let completedGlyph = Self.buildCompletedGlyph(
                    key: key,
                    glyph: glyph,
                    font: font,
                    pixelRange: pixelRange,
                    atlasScale: atlasScale,
                    epoch: epoch
                )
            else {
                return nil
            }

            do {
                try apply(completedGlyphs: [completedGlyph])
            } catch AtlasError.restartBuild {
                resetKeepingConfiguration()
                throw AtlasError.restartBuild
            }

            return glyphCache[key]
        }

        private func enqueueBuildIfNeeded(
            for key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont
        ) {
            let epoch: UInt64
            let shouldSchedule: Bool

            stateLock.lock()
            epoch = generationEpoch
            shouldSchedule = pendingGlyphs.insert(key).inserted
            stateLock.unlock()

            guard shouldSchedule else { return }

            let pixelRange = self.pixelRange
            let atlasScale = self.atlasScale
            generationQueue.async { [weak self] in
                guard let self else { return }
                let completedGlyph = Self.buildCompletedGlyph(
                    key: key,
                    glyph: glyph,
                    font: font,
                    pixelRange: pixelRange,
                    atlasScale: atlasScale,
                    epoch: epoch
                )

                self.stateLock.lock()
                self.pendingGlyphs.remove(key)
                if let completedGlyph,
                    completedGlyph.epoch == self.generationEpoch
                {
                    self.completedGlyphs.append(completedGlyph)
                }
                self.stateLock.unlock()
            }
        }

        private func drainCompletedGlyphs() -> [CompletedGlyph] {
            stateLock.lock()
            let drainedGlyphs = self.completedGlyphs
            self.completedGlyphs.removeAll(keepingCapacity: true)
            stateLock.unlock()
            return drainedGlyphs
        }

        private func apply(completedGlyphs: [CompletedGlyph]) throws {
            var didUploadGlyph = false

            for completedGlyph in completedGlyphs {
                if glyphCache[completedGlyph.key] != nil {
                    continue
                }

                let textureRect = try allocateRect(
                    width: completedGlyph.bitmapWidth,
                    height: completedGlyph.bitmapHeight
                )
                completedGlyph.bitmap.withUnsafeBytes { rawBuffer in
                    texture.replace(
                        region: MTLRegionMake2D(
                            Int(textureRect.origin.x),
                            Int(textureRect.origin.y),
                            completedGlyph.bitmapWidth,
                            completedGlyph.bitmapHeight
                        ),
                        mipmapLevel: 0,
                        withBytes: rawBuffer.baseAddress!,
                        bytesPerRow: completedGlyph.bitmapWidth * 4
                    )
                }

                glyphCache[completedGlyph.key] = GlyphEntry(
                    planeBounds: completedGlyph.planeBounds,
                    uvMin: SIMD2(
                        Float(textureRect.minX) / Float(atlasSize),
                        Float(textureRect.minY) / Float(atlasSize)
                    ),
                    uvMax: SIMD2(
                        Float(textureRect.maxX) / Float(atlasSize),
                        Float(textureRect.maxY) / Float(atlasSize)
                    )
                )
                didUploadGlyph = true
            }

            if didUploadGlyph {
                revision &+= 1
            }
        }

        private static func buildCompletedGlyph(
            key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont,
            pixelRange: Int,
            atlasScale: CGFloat,
            epoch: UInt64
        ) -> CompletedGlyph? {
            guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
                return nil
            }

            let glyphBounds = path.boundingBoxOfPath
            guard !glyphBounds.isNull, glyphBounds.width > 0,
                glyphBounds.height > 0
            else {
                return nil
            }

            let padding = CGFloat(pixelRange) / atlasScale
            let planeBounds = glyphBounds.insetBy(dx: -padding, dy: -padding)
            let bitmapWidth = max(2, Int(ceil(planeBounds.width * atlasScale)))
            let bitmapHeight = max(
                2,
                Int(ceil(planeBounds.height * atlasScale))
            )

            return CompletedGlyph(
                key: key,
                planeBounds: planeBounds,
                bitmapWidth: bitmapWidth,
                bitmapHeight: bitmapHeight,
                bitmap: GlyphContours(path: path).makeMSDFBitmap(
                    bounds: planeBounds,
                    pixelWidth: bitmapWidth,
                    pixelHeight: bitmapHeight,
                    range: padding
                ),
                epoch: epoch
            )
        }

        private func allocateRect(width: Int, height: Int) throws -> CGRect {
            guard width < atlasSize, height < atlasSize else {
                throw AtlasError.restartBuild
            }

            if nextOrigin.x + width >= atlasSize {
                nextOrigin.x = 0
                nextOrigin.y += currentRowHeight
                currentRowHeight = 0
            }

            if nextOrigin.y + height >= atlasSize {
                throw AtlasError.restartBuild
            }

            let rect = CGRect(
                x: nextOrigin.x,
                y: nextOrigin.y,
                width: width,
                height: height
            )
            nextOrigin.x += width + 1
            currentRowHeight = max(currentRowHeight, height + 1)
            return rect
        }

        private static func makeTexture(device: MTLDevice, size: Int)
            -> MTLTexture
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: size,
                height: size,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            return device.makeTexture(descriptor: descriptor)!
        }
    }

    private struct PreparedSnapshot {
        let comments: [GPUCommentState]
        let glyphs: [GPUStaticGlyphInstance]
    }

    private struct FontSignature: Equatable {
        let style: DanmakuFontStyle
        let sizeQuarterPoints: Int

        init(configuration: DanmakuRenderConfiguration) {
            style = configuration.fontStyle
            sizeQuarterPoints = Int(
                (configuration.resolvedFontSize * 4).rounded()
            )
        }
    }

    private struct GPUCommentState {
        var startTime: Float = 0
        var duration: Float = 0
        var width: Float = 0
        var anchorY: Float = 0
        var region: UInt32 = 0
    }

    private struct GPUStaticGlyphInstance {
        var commentIndex: UInt32 = 0
        var offset: SIMD2<Float> = .zero
        var size: SIMD2<Float> = .zero
        var uvMin: SIMD2<Float> = .zero
        var uvMax: SIMD2<Float> = .zero
        var color: SIMD4<Float> = .zero
    }

    private struct GPURenderGlyphInstance {
        var center: SIMD2<Float> = .zero
        var size: SIMD2<Float> = .zero
        var uvMin: SIMD2<Float> = .zero
        var uvMax: SIMD2<Float> = .zero
        var color: SIMD4<Float> = .zero
    }

    private struct GPUDanmakuUniforms {
        var viewportSize: SIMD2<Float> = .zero
        var playbackTime: Float = 0
        var horizontalInset: Float = 0
        var contentScale: Float = 1
        var msdfPixelRange: Float = 0
        var outlineWidth: Float = 0
        var glyphCount: UInt32 = 0
        var padding: UInt32 = 0
    }

    extension DanmakuRegion {
        fileprivate var gpuValue: UInt32 {
            switch self {
            case .scroll:
                0
            case .top:
                1
            case .bottom:
                2
            }
        }
    }

    private struct GlyphContours {
        private let path: CGPath

        init(path: CGPath) {
            self.path = path
        }

        func makeMSDFBitmap(
            bounds: CGRect,
            pixelWidth: Int,
            pixelHeight: Int,
            range: CGFloat
        ) -> [UInt8] {
            guard pixelWidth > 0, pixelHeight > 0 else {
                return Array(repeating: 0, count: pixelWidth * pixelHeight * 4)
            }

            let mask = rasterizeMask(
                bounds: bounds,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            let signedDistances = Self.makeSignedDistanceField(
                from: mask,
                width: pixelWidth,
                height: pixelHeight
            )
            let scaleX = CGFloat(pixelWidth) / max(bounds.width, 0.000_001)
            let scaleY = CGFloat(pixelHeight) / max(bounds.height, 0.000_001)
            let pixelRange = max(1, Float(range * min(scaleX, scaleY)))
            var pixels = Array(
                repeating: UInt8(0),
                count: pixelWidth * pixelHeight * 4
            )

            for index in 0..<(pixelWidth * pixelHeight) {
                let encoded = encode(
                    distance: signedDistances[index],
                    range: pixelRange
                )
                let base = index * 4
                pixels[base] = encoded
                pixels[base + 1] = encoded
                pixels[base + 2] = encoded
                pixels[base + 3] = 255
            }

            return pixels
        }

        private func rasterizeMask(
            bounds: CGRect,
            pixelWidth: Int,
            pixelHeight: Int
        ) -> [UInt8] {
            var mask = Array(
                repeating: UInt8(0),
                count: pixelWidth * pixelHeight
            )
            let colorSpace = CGColorSpaceCreateDeviceGray()
            let scaleX = CGFloat(pixelWidth) / max(bounds.width, 0.000_001)
            let scaleY = CGFloat(pixelHeight) / max(bounds.height, 0.000_001)

            mask.withUnsafeMutableBytes { rawBuffer in
                guard
                    let context = CGContext(
                        data: rawBuffer.baseAddress,
                        width: pixelWidth,
                        height: pixelHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: pixelWidth,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.none.rawValue
                    )
                else {
                    return
                }

                context.setAllowsAntialiasing(false)
                context.setShouldAntialias(false)
                context.setFillColor(gray: 1, alpha: 1)
                context.translateBy(
                    x: -bounds.minX * scaleX,
                    y: bounds.maxY * scaleY
                )
                context.scaleBy(x: scaleX, y: -scaleY)
                context.addPath(path)
                context.fillPath()
            }

            return mask
        }

        private static func makeSignedDistanceField(
            from mask: [UInt8],
            width: Int,
            height: Int
        ) -> [Float] {
            let infinity: Float = 1e10
            var insideGrid = Array(repeating: infinity, count: mask.count)
            var outsideGrid = Array(repeating: infinity, count: mask.count)

            for index in mask.indices {
                if mask[index] >= 128 {
                    insideGrid[index] = 0
                } else {
                    outsideGrid[index] = 0
                }
            }

            let distanceToInside = distanceTransform(
                grid: insideGrid,
                width: width,
                height: height
            )
            let distanceToOutside = distanceTransform(
                grid: outsideGrid,
                width: width,
                height: height
            )

            var signedDistances = Array(repeating: Float(0), count: mask.count)
            for index in mask.indices {
                signedDistances[index] =
                    sqrt(distanceToOutside[index])
                    - sqrt(distanceToInside[index])
            }
            return signedDistances
        }

        private static func distanceTransform(
            grid: [Float],
            width: Int,
            height: Int
        ) -> [Float] {
            var intermediate = Array(repeating: Float(0), count: grid.count)
            var output = Array(repeating: Float(0), count: grid.count)
            var columnInput = Array(repeating: Float(0), count: height)
            var columnOutput = Array(repeating: Float(0), count: height)
            var rowInput = Array(repeating: Float(0), count: width)
            var rowOutput = Array(repeating: Float(0), count: width)
            var v = Array(repeating: 0, count: max(width, height))
            var z = Array(repeating: Float(0), count: max(width, height) + 1)

            for x in 0..<width {
                for y in 0..<height {
                    columnInput[y] = grid[y * width + x]
                }
                distanceTransform1D(
                    input: columnInput,
                    length: height,
                    output: &columnOutput,
                    v: &v,
                    z: &z
                )
                for y in 0..<height {
                    intermediate[y * width + x] = columnOutput[y]
                }
            }

            for y in 0..<height {
                for x in 0..<width {
                    rowInput[x] = intermediate[y * width + x]
                }
                distanceTransform1D(
                    input: rowInput,
                    length: width,
                    output: &rowOutput,
                    v: &v,
                    z: &z
                )
                for x in 0..<width {
                    output[y * width + x] = rowOutput[x]
                }
            }

            return output
        }

        private static func distanceTransform1D(
            input: [Float],
            length: Int,
            output: inout [Float],
            v: inout [Int],
            z: inout [Float]
        ) {
            guard length > 0 else { return }

            var k = 0
            v[0] = 0
            z[0] = -.greatestFiniteMagnitude
            z[1] = .greatestFiniteMagnitude

            for q in 1..<length {
                var intersection = Float(0)
                repeat {
                    let previous = v[k]
                    intersection =
                        ((input[q] + Float(q * q))
                            - (input[previous] + Float(previous * previous)))
                        / Float(2 * (q - previous))
                    if intersection <= z[k] {
                        k -= 1
                    } else {
                        break
                    }
                } while k > 0

                k += 1
                v[k] = q
                z[k] = intersection
                z[k + 1] = .greatestFiniteMagnitude
            }

            k = 0
            for q in 0..<length {
                while z[k + 1] < Float(q) {
                    k += 1
                }
                let delta = Float(q - v[k])
                output[q] = delta * delta + input[v[k]]
            }
        }

        private func encode(distance: Float, range: Float) -> UInt8 {
            let normalized = min(max(0.5 + distance / (range * 2), 0), 1)
            return UInt8((normalized * 255).rounded())
        }
    }
#else
    struct DanmakuMetalOverlay: View {
        let renderer: DanmakuRendererStore
        let timebase: PlaybackTimebase
        let viewport: CGSize
        let metrics: DanmakuLayoutMetrics

        var body: some View {
            Text("Danmaku requires Metal support.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
#endif
