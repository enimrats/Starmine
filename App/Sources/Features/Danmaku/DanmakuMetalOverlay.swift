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
        private static let atlasPrewarmLookAhead: Double = 3
        private static let atlasPrewarmBucketsPerSecond = 2.0
        private static let shapedLineCacheLimit = 1024
        private static let synchronousBootstrapGlyphLimit = 320
        private static let seekBootstrapBackstepThreshold: Double = 0.2
        private static let seekBootstrapJumpThreshold: Double = 8

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
        private var preheatedBucket: Int = .min
        private var preheatedVersion: UInt64 = .max
        private var preheatedFontSignature: FontSignature?
        private var shapedLineCache: [String: ShapedLine] = [:]
        private var shapedLineCacheFontSignature: FontSignature?
        private var lastPreparedPlaybackTime = -1.0
        private var frameUniforms = GPUDanmakuUniforms()

        init?(device: MTLDevice) {
            self.device = device
            guard let commandQueue = device.makeCommandQueue() else {
                return nil
            }
            self.commandQueue = commandQueue
            guard let atlas = DynamicMSDFAtlas(device: device) else {
                Self.logger.error(
                    "Failed to create dynamic MSDF atlas"
                )
                return nil
            }
            self.atlas = atlas

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
            let font = configuration.fontStyle.ctFont(
                ofSize: configuration.resolvedFontSize
            )
            if shapedLineCacheFontSignature != fontSignature {
                shapedLineCache.removeAll(keepingCapacity: true)
                shapedLineCacheFontSignature = fontSignature
            }
            atlas.prepare(configuration: configuration)
            if glyphBuildMode == .asynchronous {
                bootstrapVisibleGlyphsIfNeeded(
                    store: store,
                    playbackTime: playbackTime,
                    font: font,
                    fontSignature: fontSignature
                )
                prewarmAtlasIfNeeded(
                    store: store,
                    playbackTime: playbackTime,
                    font: font,
                    fontSignature: fontSignature
                )
            }
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
            lastPreparedPlaybackTime = playbackTime
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

                let shapedLine = shapedLine(
                    for: item.comment.text,
                    baseFont: font
                )
                let lineBounds = shapedLine.lineBounds
                let renderCenterX = lineBounds.isNull ? 0 : lineBounds.midX
                let renderCenterY = lineBounds.isNull ? 0 : lineBounds.midY

                for shapedGlyph in shapedLine.glyphs {
                    guard
                        let atlasEntry = try atlas.entry(
                            for: shapedGlyph.glyph,
                            font: shapedGlyph.font,
                            mode: glyphBuildMode
                        )
                    else {
                        continue
                    }

                    let quadRect = atlasEntry.planeBounds.offsetBy(
                        dx: shapedGlyph.position.x,
                        dy: shapedGlyph.position.y
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

            return PreparedSnapshot(comments: comments, glyphs: glyphs)
        }

        private func shapedLine(
            for text: String,
            baseFont: CTFont
        ) -> ShapedLine {
            if let cached = shapedLineCache[text] {
                return cached
            }

            let shapedLine = shapeGlyphs(
                in: text,
                baseFont: baseFont
            )
            if shapedLineCache.count >= Self.shapedLineCacheLimit {
                shapedLineCache.removeAll(keepingCapacity: true)
            }
            shapedLineCache[text] = shapedLine
            return shapedLine
        }

        private func prewarmAtlasIfNeeded(
            store: DanmakuRendererStore,
            playbackTime: Double,
            font: CTFont,
            fontSignature: FontSignature
        ) {
            let bucket = Int(
                floor(
                    playbackTime * Self.atlasPrewarmBucketsPerSecond
                )
            )
            guard
                bucket != preheatedBucket
                    || preheatedVersion != store.contentVersion
                    || preheatedFontSignature != fontSignature
            else {
                return
            }

            for item in store.activeItems {
                atlas.prewarm(
                    glyphs: shapedLine(
                        for: item.comment.text,
                        baseFont: font
                    ).glyphs
                )
            }
            for comment in store.commentsToPreheat(
                from: playbackTime,
                lookAhead: Self.atlasPrewarmLookAhead
            ) {
                atlas.prewarm(
                    glyphs: shapedLine(
                        for: comment.text,
                        baseFont: font
                    ).glyphs
                )
            }
            preheatedBucket = bucket
            preheatedVersion = store.contentVersion
            preheatedFontSignature = fontSignature
        }

        private func bootstrapVisibleGlyphsIfNeeded(
            store: DanmakuRendererStore,
            playbackTime: Double,
            font: CTFont,
            fontSignature: FontSignature
        ) {
            guard
                shouldBootstrapVisibleGlyphs(
                    store: store,
                    playbackTime: playbackTime,
                    fontSignature: fontSignature
                )
            else {
                return
            }

            var visibleGlyphs: [ShapedGlyph] = []
            visibleGlyphs.reserveCapacity(Self.synchronousBootstrapGlyphLimit)

            for item in store.activeItems {
                visibleGlyphs.append(
                    contentsOf: shapedLine(
                        for: item.comment.text,
                        baseFont: font
                    ).glyphs
                )
                if visibleGlyphs.count >= Self.synchronousBootstrapGlyphLimit {
                    break
                }
            }

            guard !visibleGlyphs.isEmpty else { return }

            do {
                try atlas.buildSynchronouslyIfNeeded(
                    glyphs: visibleGlyphs,
                    limit: Self.synchronousBootstrapGlyphLimit
                )
            } catch {
                Self.logger.error(
                    "Failed to bootstrap visible danmaku glyphs: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        private func shouldBootstrapVisibleGlyphs(
            store: DanmakuRendererStore,
            playbackTime: Double,
            fontSignature: FontSignature
        ) -> Bool {
            guard !store.activeItems.isEmpty else { return false }
            if preparedFontSignature != fontSignature {
                return true
            }
            guard lastPreparedPlaybackTime >= 0 else { return true }
            if playbackTime
                < lastPreparedPlaybackTime
                - Self.seekBootstrapBackstepThreshold
            {
                return true
            }
            return
                abs(playbackTime - lastPreparedPlaybackTime)
                > Self.seekBootstrapJumpThreshold
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

            float shapeAlpha(float distanceInPx) {
                return clamp(distanceInPx + 0.5, 0.0, 1.0);
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

                float4 sample = atlas.sample(atlasSampler, in.uv);
                float msdfDistance = median(sample.r, sample.g, sample.b) - 0.5;
                float sdfDistance = sample.a - 0.5;
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
                float msdfPxDistance = msdfDistance * screenPxRange;
                float sdfPxDistance = sdfDistance * screenPxRange;
                float channelSpread = max(
                    max(abs(sample.r - sample.g), abs(sample.g - sample.b)),
                    abs(sample.b - sample.r)
                );
                float seamWeight = smoothstep(
                    0.06,
                    0.22,
                    max(abs(msdfDistance - sdfDistance) * 2.0, channelSpread)
                );
                float desiredOutlineWidth = max(
                    0.0,
                    uniforms.outlineWidth * uniforms.contentScale
                );
                float outlineWidth = min(
                    desiredOutlineWidth,
                    max(screenPxRange * 0.5 - 0.5, 0.0)
                );
                float msdfFillShape = shapeAlpha(msdfPxDistance);
                float sdfFillShape = shapeAlpha(sdfPxDistance);
                float safePxDistance = max(msdfPxDistance, sdfPxDistance);
                float safeFillShape = shapeAlpha(safePxDistance);
                float fillShape = mix(
                    msdfFillShape,
                    safeFillShape,
                    max(seamWeight, 0.35)
                );
                float outlineShape = shapeAlpha(sdfPxDistance + outlineWidth);
                float fillAlpha = fillShape * in.color.a;
                float outlineAlpha = max(outlineShape - sdfFillShape, 0.0)
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
        private static let preprocessedGlyphCacheCostLimit =
            64 * 1_024 * 1_024

        enum AtlasError: Error {
            case restartBuild
        }

        private static let logger = Logger(
            subsystem: "Starmine",
            category: "DynamicMSDFAtlas"
        )

        private enum PreprocessedGlyphCachePolicy {
            case readOnly
            case readWrite
        }

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

        private struct PreparedGlyph {
            let key: GlyphCacheKey
            let texture: MTLTexture
            let planeBounds: CGRect
            let textureRect: CGRect
            let bitmapWidth: Int
            let bitmapHeight: Int
            let range: Float
            let segments: [GPUAtlasSegment]
            let alphaBitmap: [UInt8]
            let epoch: UInt64
        }

        private struct PreprocessedGlyph {
            let planeBounds: CGRect
            let bitmapWidth: Int
            let bitmapHeight: Int
            let range: Float
            let segments: [GPUAtlasSegment]
            let alphaBitmap: [UInt8]

            var estimatedCost: Int {
                segments.count * MemoryLayout<GPUAtlasSegment>.stride
                    + alphaBitmap.count
            }
        }

        private struct GlyphBuildRequest {
            let key: GlyphCacheKey
            let glyph: CGGlyph
            let font: CTFont
            let epoch: UInt64
        }

        private struct PreparedGlyphJob {
            let glyph: PreparedGlyph
            let segmentBuffer: MTLBuffer
            let uniformBuffer: MTLBuffer
            let alphaBuffer: MTLBuffer
            let threadgroups: MTLSize
        }

        private struct CompletedGlyph {
            let key: GlyphCacheKey
            let planeBounds: CGRect
            let textureRect: CGRect
            let epoch: UInt64
        }

        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let generationPipeline: MTLComputePipelineState
        private let atlasSize: Int
        private let pixelRange: Int
        private let atlasScale: CGFloat
        private let generationQueue = DispatchQueue(
            label: "Starmine.DynamicMSDFAtlas",
            qos: .userInitiated
        )
        private let stateLock = NSLock()
        private let preprocessedGlyphCacheLock = NSLock()

        private(set) var texture: MTLTexture
        var msdfPixelRange: Float { Float(pixelRange) }
        private(set) var revision: UInt64 = 0
        private var configurationSignature: FontSignature?
        private var nextOrigin = SIMD2<Int>(0, 0)
        private var currentRowHeight = 0
        private var glyphCache: [GlyphCacheKey: GlyphEntry] = [:]
        private var generationEpoch: UInt64 = 0
        private var pendingGlyphs: [GlyphCacheKey: UInt64] = [:]
        private var completedGlyphs: [CompletedGlyph] = []
        private var preprocessedGlyphCache: [GlyphCacheKey: PreprocessedGlyph] =
            [:]
        private var preprocessedGlyphCacheCost = 0
        private var resetRequestedEpoch: UInt64?

        init?(
            device: MTLDevice,
            atlasSize: Int = 4096,
            pixelRange: Int = 6,
            atlasScale: CGFloat = 3
        ) {
            guard
                let commandQueue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(
                    source: Self.shaderSource,
                    options: nil
                ),
                let generationFunction = library.makeFunction(
                    name: "generateMSDFGlyph"
                ),
                let generationPipeline = try? device.makeComputePipelineState(
                    function: generationFunction
                )
            else {
                Self.logger.error(
                    "Failed to create GPU MSDF generation pipeline"
                )
                return nil
            }

            self.device = device
            self.commandQueue = commandQueue
            self.generationPipeline = generationPipeline
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

        func prewarm(glyphs: [ShapedGlyph]) {
            guard !glyphs.isEmpty else { return }
            scheduleBuilds(
                reserveBuildRequestsIfNeeded(for: glyphs)
            )
        }

        func applyCompletedGlyphs() -> Bool {
            if consumeResetRequestIfNeeded() {
                resetKeepingConfiguration()
                return true
            }
            let completedGlyphs = drainCompletedGlyphs()
            guard !completedGlyphs.isEmpty else { return false }
            apply(completedGlyphs: completedGlyphs)
            return true
        }

        func resetKeepingConfiguration() {
            glyphCache.removeAll(keepingCapacity: true)
            texture = Self.makeTexture(device: device, size: atlasSize)
            revision &+= 1

            stateLock.lock()
            nextOrigin = SIMD2<Int>(0, 0)
            currentRowHeight = 0
            generationEpoch &+= 1
            pendingGlyphs.removeAll(keepingCapacity: true)
            completedGlyphs.removeAll(keepingCapacity: true)
            resetRequestedEpoch = nil
            stateLock.unlock()
        }

        func entry(
            for glyph: CGGlyph,
            font: CTFont,
            mode: GlyphBuildMode = .asynchronous
        ) throws -> GlyphEntry? {
            if consumeResetRequestIfNeeded() {
                resetKeepingConfiguration()
            }
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

            let glyphs = [
                ShapedGlyph(
                    glyph: glyph,
                    font: font,
                    position: .zero
                )
            ]
            try buildSynchronouslyIfNeeded(glyphs: glyphs, limit: 1)
            if let cached = glyphCache[key] {
                return cached
            }
            guard pendingGlyphs[key] == nil else {
                throw AtlasError.restartBuild
            }
            return nil
        }

        func buildSynchronouslyIfNeeded(
            glyphs: [ShapedGlyph],
            limit: Int = .max
        ) throws {
            let requests = reserveBuildRequestsIfNeeded(
                for: glyphs,
                limit: limit
            )
            guard !requests.isEmpty else {
                return
            }

            do {
                let preparedGlyphs = try makePreparedGlyphs(
                    for: requests,
                    cachePolicy: .readOnly
                )
                guard !preparedGlyphs.isEmpty else { return }
                try render(
                    preparedGlyphs: preparedGlyphs,
                    waitUntilCompleted: true
                )
            } catch AtlasError.restartBuild {
                requestReset(forEpoch: requests[0].epoch)
                resetKeepingConfiguration()
                throw AtlasError.restartBuild
            }

            _ = applyCompletedGlyphs()
        }

        private func enqueueBuildIfNeeded(
            for key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont
        ) {
            if glyphCache[key] != nil {
                return
            }

            guard
                let request = reserveBuildRequestIfNeeded(
                    for: key,
                    glyph: glyph,
                    font: font
                )
            else {
                return
            }
            scheduleBuilds([request])
        }

        private func currentGenerationEpoch() -> UInt64 {
            stateLock.lock()
            defer { stateLock.unlock() }
            return generationEpoch
        }

        private func makePreparedGlyph(
            for key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont,
            epoch: UInt64,
            cachePolicy: PreprocessedGlyphCachePolicy
        ) throws -> PreparedGlyph? {
            guard
                let preprocessedGlyph = makePreprocessedGlyph(
                    for: key,
                    glyph: glyph,
                    font: font,
                    cachePolicy: cachePolicy
                )
            else {
                return nil
            }

            let (textureRect, texture) = try reserveTextureRect(
                width: preprocessedGlyph.bitmapWidth,
                height: preprocessedGlyph.bitmapHeight,
                epoch: epoch
            )

            return PreparedGlyph(
                key: key,
                texture: texture,
                planeBounds: preprocessedGlyph.planeBounds,
                textureRect: textureRect,
                bitmapWidth: preprocessedGlyph.bitmapWidth,
                bitmapHeight: preprocessedGlyph.bitmapHeight,
                range: preprocessedGlyph.range,
                segments: preprocessedGlyph.segments,
                alphaBitmap: preprocessedGlyph.alphaBitmap,
                epoch: epoch
            )
        }

        private func finishRender(
            for preparedGlyph: PreparedGlyph,
            status: MTLCommandBufferStatus
        ) {
            stateLock.lock()
            defer { stateLock.unlock() }

            if pendingGlyphs[preparedGlyph.key] == preparedGlyph.epoch {
                pendingGlyphs.removeValue(forKey: preparedGlyph.key)
            }
            guard status == .completed,
                preparedGlyph.epoch == generationEpoch
            else {
                return
            }

            completedGlyphs.append(
                CompletedGlyph(
                    key: preparedGlyph.key,
                    planeBounds: preparedGlyph.planeBounds,
                    textureRect: preparedGlyph.textureRect,
                    epoch: preparedGlyph.epoch
                )
            )
        }

        private func drainCompletedGlyphs() -> [CompletedGlyph] {
            stateLock.lock()
            let drainedGlyphs = self.completedGlyphs
            self.completedGlyphs.removeAll(keepingCapacity: true)
            stateLock.unlock()
            return drainedGlyphs
        }

        private func apply(completedGlyphs: [CompletedGlyph]) {
            var didRegisterGlyph = false

            for completedGlyph in completedGlyphs {
                guard completedGlyph.epoch == generationEpoch else { continue }
                guard glyphCache[completedGlyph.key] == nil else { continue }

                let inset = SIMD2<Float>(
                    0.5 / Float(atlasSize),
                    0.5 / Float(atlasSize)
                )
                let uvMin =
                    SIMD2(
                        Float(completedGlyph.textureRect.minX)
                            / Float(atlasSize),
                        Float(completedGlyph.textureRect.minY)
                            / Float(atlasSize)
                    ) + inset
                let uvMax =
                    SIMD2(
                        Float(completedGlyph.textureRect.maxX)
                            / Float(atlasSize),
                        Float(completedGlyph.textureRect.maxY)
                            / Float(atlasSize)
                    ) - inset

                glyphCache[completedGlyph.key] = GlyphEntry(
                    planeBounds: completedGlyph.planeBounds,
                    uvMin: uvMin,
                    uvMax: uvMax
                )
                didRegisterGlyph = true
            }

            if didRegisterGlyph {
                revision &+= 1
            }
        }

        private func reserveBuildRequestIfNeeded(
            for key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont
        ) -> GlyphBuildRequest? {
            if glyphCache[key] != nil {
                return nil
            }

            stateLock.lock()
            defer { stateLock.unlock() }

            if pendingGlyphs[key] != nil {
                return nil
            }

            let epoch = generationEpoch
            pendingGlyphs[key] = epoch
            return GlyphBuildRequest(
                key: key,
                glyph: glyph,
                font: font,
                epoch: epoch
            )
        }

        private func reserveBuildRequestsIfNeeded(
            for glyphs: [ShapedGlyph],
            limit: Int = .max
        ) -> [GlyphBuildRequest] {
            guard !glyphs.isEmpty, limit > 0 else { return [] }

            var requests: [GlyphBuildRequest] = []
            requests.reserveCapacity(min(glyphs.count, limit))
            var seenKeys = Set<GlyphCacheKey>()

            for shapedGlyph in glyphs {
                let key = GlyphCacheKey(
                    glyph: shapedGlyph.glyph,
                    font: shapedGlyph.font
                )
                guard seenKeys.insert(key).inserted else { continue }
                guard
                    let request = reserveBuildRequestIfNeeded(
                        for: key,
                        glyph: shapedGlyph.glyph,
                        font: shapedGlyph.font
                    )
                else {
                    continue
                }
                requests.append(request)
                if requests.count >= limit {
                    break
                }
            }

            return requests
        }

        private func makePreprocessedGlyph(
            for key: GlyphCacheKey,
            glyph: CGGlyph,
            font: CTFont,
            cachePolicy: PreprocessedGlyphCachePolicy
        ) -> PreprocessedGlyph? {
            if let cached = cachedPreprocessedGlyph(for: key) {
                return cached
            }

            guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
                return nil
            }

            let glyphBounds = path.boundingBoxOfPath
            guard !glyphBounds.isNull,
                glyphBounds.width > 0,
                glyphBounds.height > 0
            else {
                return nil
            }

            let padding = CGFloat(pixelRange) / atlasScale
            let planeBounds = glyphBounds.insetBy(dx: -padding, dy: -padding)
            let bitmapWidth = max(
                2,
                Int(ceil(planeBounds.width * atlasScale))
            )
            let bitmapHeight = max(
                2,
                Int(ceil(planeBounds.height * atlasScale))
            )
            let flatness = max(0.2, padding * 0.08)
            let segments = GlyphContours(path: path).makeMSDFSegments(
                flatness: flatness
            )
            guard !segments.isEmpty else {
                return nil
            }
            let alphaBitmap = FilledGlyphDistanceField(path: path)
                .makeEncodedSDFAlphaBitmap(
                    bounds: planeBounds,
                    pixelWidth: bitmapWidth,
                    pixelHeight: bitmapHeight,
                    range: padding
                )

            let preprocessedGlyph = PreprocessedGlyph(
                planeBounds: planeBounds,
                bitmapWidth: bitmapWidth,
                bitmapHeight: bitmapHeight,
                range: Float(padding),
                segments: segments,
                alphaBitmap: alphaBitmap
            )
            if cachePolicy == .readWrite {
                cachePreprocessedGlyph(preprocessedGlyph, for: key)
            }
            return preprocessedGlyph
        }

        private func cachedPreprocessedGlyph(for key: GlyphCacheKey)
            -> PreprocessedGlyph?
        {
            preprocessedGlyphCacheLock.lock()
            defer { preprocessedGlyphCacheLock.unlock() }
            return preprocessedGlyphCache[key]
        }

        private func cachePreprocessedGlyph(
            _ preprocessedGlyph: PreprocessedGlyph,
            for key: GlyphCacheKey
        ) {
            preprocessedGlyphCacheLock.lock()
            defer { preprocessedGlyphCacheLock.unlock() }

            if preprocessedGlyphCache[key] != nil {
                return
            }

            let newCost = preprocessedGlyph.estimatedCost
            if preprocessedGlyphCacheCost + newCost
                > Self.preprocessedGlyphCacheCostLimit
            {
                preprocessedGlyphCache.removeAll(keepingCapacity: true)
                preprocessedGlyphCacheCost = 0
            }

            preprocessedGlyphCache[key] = preprocessedGlyph
            preprocessedGlyphCacheCost += newCost
        }

        private func scheduleBuilds(_ requests: [GlyphBuildRequest]) {
            guard !requests.isEmpty else { return }

            generationQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let preparedGlyphs = try self.makePreparedGlyphs(
                        for: requests,
                        cachePolicy: .readWrite
                    )
                    guard !preparedGlyphs.isEmpty else { return }
                    try self.render(
                        preparedGlyphs: preparedGlyphs,
                        waitUntilCompleted: false
                    )
                } catch AtlasError.restartBuild {
                    self.requestReset(forEpoch: requests[0].epoch)
                    for request in requests {
                        self.finishDiscardedBuild(
                            for: request.key,
                            epoch: request.epoch
                        )
                    }
                } catch {
                    Self.logger.error(
                        "Failed to enqueue GPU MSDF glyph build batch: \(error.localizedDescription, privacy: .public)"
                    )
                    for request in requests {
                        self.finishDiscardedBuild(
                            for: request.key,
                            epoch: request.epoch
                        )
                    }
                }
            }
        }

        private func makePreparedGlyphs(
            for requests: [GlyphBuildRequest],
            cachePolicy: PreprocessedGlyphCachePolicy
        ) throws -> [PreparedGlyph] {
            var preparedGlyphs: [PreparedGlyph] = []
            preparedGlyphs.reserveCapacity(requests.count)

            for request in requests {
                guard
                    let preparedGlyph = try makePreparedGlyph(
                        for: request.key,
                        glyph: request.glyph,
                        font: request.font,
                        epoch: request.epoch,
                        cachePolicy: cachePolicy
                    )
                else {
                    finishDiscardedBuild(
                        for: request.key,
                        epoch: request.epoch
                    )
                    continue
                }
                preparedGlyphs.append(preparedGlyph)
            }

            return preparedGlyphs
        }

        private func render(
            preparedGlyphs: [PreparedGlyph],
            waitUntilCompleted: Bool
        ) throws {
            guard !preparedGlyphs.isEmpty else { return }

            let jobs = try makePreparedGlyphJobs(for: preparedGlyphs)
            guard
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let computeEncoder =
                    commandBuffer
                    .makeComputeCommandEncoder()
            else {
                throw AtlasError.restartBuild
            }

            let threadgroupSize = MTLSize(
                width: 8,
                height: 8,
                depth: 1
            )

            computeEncoder.setComputePipelineState(generationPipeline)
            for job in jobs {
                computeEncoder.setBuffer(job.segmentBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(job.uniformBuffer, offset: 0, index: 1)
                computeEncoder.setBuffer(job.alphaBuffer, offset: 0, index: 2)
                computeEncoder.setTexture(job.glyph.texture, index: 0)
                computeEncoder.dispatchThreadgroups(
                    job.threadgroups,
                    threadsPerThreadgroup: threadgroupSize
                )
            }
            computeEncoder.endEncoding()

            if waitUntilCompleted {
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                guard commandBuffer.status == .completed else {
                    for job in jobs {
                        finishRender(
                            for: job.glyph,
                            status: commandBuffer.status
                        )
                    }
                    throw AtlasError.restartBuild
                }
                for job in jobs {
                    finishRender(for: job.glyph, status: .completed)
                }
            } else {
                commandBuffer.addCompletedHandler {
                    [weak self] completedBuffer in
                    for job in jobs {
                        self?.finishRender(
                            for: job.glyph,
                            status: completedBuffer.status
                        )
                    }
                }
                commandBuffer.commit()
            }
        }

        private func makePreparedGlyphJobs(
            for preparedGlyphs: [PreparedGlyph]
        ) throws -> [PreparedGlyphJob] {
            var jobs: [PreparedGlyphJob] = []
            jobs.reserveCapacity(preparedGlyphs.count)

            let threadgroupSize = MTLSize(
                width: 8,
                height: 8,
                depth: 1
            )

            for preparedGlyph in preparedGlyphs {
                let generationUniforms = GPUAtlasGenerationUniforms(
                    textureOrigin: SIMD2(
                        UInt32(Int(preparedGlyph.textureRect.minX)),
                        UInt32(Int(preparedGlyph.textureRect.minY))
                    ),
                    bitmapSize: SIMD2(
                        UInt32(preparedGlyph.bitmapWidth),
                        UInt32(preparedGlyph.bitmapHeight)
                    ),
                    planeMin: SIMD2(
                        Float(preparedGlyph.planeBounds.minX),
                        Float(preparedGlyph.planeBounds.minY)
                    ),
                    planeSize: SIMD2(
                        Float(preparedGlyph.planeBounds.width),
                        Float(preparedGlyph.planeBounds.height)
                    ),
                    range: preparedGlyph.range,
                    segmentCount: UInt32(preparedGlyph.segments.count),
                    maxDistance: max(
                        preparedGlyph.range * 4,
                        Float(
                            hypot(
                                preparedGlyph.planeBounds.width,
                                preparedGlyph.planeBounds.height
                            )
                        )
                    )
                )

                guard
                    let segmentBuffer = Self.makeBuffer(
                        device: device,
                        array: preparedGlyph.segments
                    ),
                    let uniformBuffer = Self.makeBuffer(
                        device: device,
                        value: generationUniforms
                    ),
                    let alphaBuffer = Self.makeBuffer(
                        device: device,
                        array: preparedGlyph.alphaBitmap
                    )
                else {
                    throw AtlasError.restartBuild
                }

                let threadgroups = MTLSize(
                    width: (preparedGlyph.bitmapWidth + threadgroupSize.width
                        - 1)
                        / threadgroupSize.width,
                    height: (preparedGlyph.bitmapHeight
                        + threadgroupSize.height - 1)
                        / threadgroupSize.height,
                    depth: 1
                )

                jobs.append(
                    PreparedGlyphJob(
                        glyph: preparedGlyph,
                        segmentBuffer: segmentBuffer,
                        uniformBuffer: uniformBuffer,
                        alphaBuffer: alphaBuffer,
                        threadgroups: threadgroups
                    )
                )
            }

            return jobs
        }

        private func finishDiscardedBuild(
            for key: GlyphCacheKey,
            epoch: UInt64
        ) {
            stateLock.lock()
            defer { stateLock.unlock() }
            if pendingGlyphs[key] == epoch {
                pendingGlyphs.removeValue(forKey: key)
            }
        }

        private func requestReset(forEpoch epoch: UInt64) {
            stateLock.lock()
            if let requestedEpoch = resetRequestedEpoch {
                resetRequestedEpoch = max(requestedEpoch, epoch)
            } else {
                resetRequestedEpoch = epoch
            }
            stateLock.unlock()
        }

        private func consumeResetRequestIfNeeded() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }

            guard let resetRequestedEpoch else { return false }
            if resetRequestedEpoch != generationEpoch {
                self.resetRequestedEpoch = nil
                return false
            }

            self.resetRequestedEpoch = nil
            return true
        }

        private func reserveTextureRect(
            width: Int,
            height: Int,
            epoch: UInt64
        ) throws -> (CGRect, MTLTexture) {
            stateLock.lock()
            defer { stateLock.unlock() }

            guard epoch == generationEpoch else {
                throw AtlasError.restartBuild
            }

            return (
                try allocateRectLocked(width: width, height: height),
                texture
            )
        }

        private func allocateRectLocked(width: Int, height: Int) throws
            -> CGRect
        {
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
                guard let baseAddress = rawBuffer.baseAddress else {
                    return nil
                }
                return device.makeBuffer(
                    bytes: baseAddress,
                    length: rawBuffer.count,
                    options: .storageModeShared
                )
            }
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
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: descriptor)!
        }

        private static let shaderSource = #"""
            #include <metal_stdlib>
            using namespace metal;

            struct GPUAtlasSegment {
                float2 start;
                float2 end;
                uint colorMask;
                uint _padding;
            };

            struct GPUAtlasGenerationUniforms {
                uint2 textureOrigin;
                uint2 bitmapSize;
                float2 planeMin;
                float2 planeSize;
                float range;
                uint segmentCount;
                float maxDistance;
                uint _padding;
            };

            float distanceToSegment(float2 point, float2 start, float2 end) {
                float2 delta = end - start;
                float lengthSquared = max(dot(delta, delta), 0.000001);
                float t = clamp(dot(point - start, delta) / lengthSquared, 0.0, 1.0);
                float2 nearest = start + delta * t;
                return length(point - nearest);
            }

            int windingContribution(float2 point, float2 start, float2 end) {
                bool upward = start.y <= point.y && end.y > point.y;
                bool downward = start.y > point.y && end.y <= point.y;
                if (!(upward || downward)) {
                    return 0;
                }

                float deltaY = end.y - start.y;
                float safeDeltaY = fabs(deltaY) < 0.000001
                    ? (deltaY >= 0.0 ? 0.000001 : -0.000001)
                    : deltaY;
                float crossX = start.x + (point.y - start.y) * (end.x - start.x)
                    / safeDeltaY;
                if (crossX <= point.x) {
                    return 0;
                }
                return upward ? 1 : -1;
            }

            float encodeDistance(float distance, float range) {
                return clamp(0.5 + distance / max(range * 2.0, 0.0001), 0.0, 1.0);
            }

            kernel void generateMSDFGlyph(
                texture2d<float, access::write> atlas [[texture(0)]],
                device const GPUAtlasSegment *segments [[buffer(0)]],
                constant GPUAtlasGenerationUniforms &uniforms [[buffer(1)]],
                device const uchar *alphaBytes [[buffer(2)]],
                uint2 gid [[thread_position_in_grid]]
            ) {
                if (gid.x >= uniforms.bitmapSize.x || gid.y >= uniforms.bitmapSize.y) {
                    return;
                }

                float2 bitmapSize = float2(
                    max(uniforms.bitmapSize.x, 1u),
                    max(uniforms.bitmapSize.y, 1u)
                );
                float2 point = uniforms.planeMin
                    + (float2(gid) + 0.5) / bitmapSize * uniforms.planeSize;

                float3 minDistance = float3(uniforms.maxDistance);
                int winding = 0;

                for (uint index = 0; index < uniforms.segmentCount; ++index) {
                    GPUAtlasSegment segment = segments[index];
                    float distance = distanceToSegment(
                        point,
                        segment.start,
                        segment.end
                    );

                    if ((segment.colorMask & 0x1u) != 0u) {
                        minDistance.x = min(minDistance.x, distance);
                    }
                    if ((segment.colorMask & 0x2u) != 0u) {
                        minDistance.y = min(minDistance.y, distance);
                    }
                    if ((segment.colorMask & 0x4u) != 0u) {
                        minDistance.z = min(minDistance.z, distance);
                    }
                    winding += windingContribution(point, segment.start, segment.end);
                }

                float sign = winding != 0 ? 1.0 : -1.0;
                uint alphaIndex = gid.y * uniforms.bitmapSize.x + gid.x;
                float alphaValue = float(alphaBytes[alphaIndex]) / 255.0;
                float4 encoded = float4(
                    encodeDistance(minDistance.x * sign, uniforms.range),
                    encodeDistance(minDistance.y * sign, uniforms.range),
                    encodeDistance(minDistance.z * sign, uniforms.range),
                    alphaValue
                );

                atlas.write(
                    encoded,
                    uint2(
                        gid.x + uniforms.textureOrigin.x,
                        gid.y + uniforms.textureOrigin.y
                    )
                );
            }
            """#
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

    private struct ShapedGlyph {
        let glyph: CGGlyph
        let font: CTFont
        let position: CGPoint
    }

    private struct ShapedLine {
        let lineBounds: CGRect
        let glyphs: [ShapedGlyph]
    }

    private struct GPUAtlasSegment {
        var start: SIMD2<Float> = .zero
        var end: SIMD2<Float> = .zero
        var colorMask: UInt32 = 0
        var padding: UInt32 = 0
    }

    private struct GPUAtlasGenerationUniforms {
        var textureOrigin: SIMD2<UInt32> = .zero
        var bitmapSize: SIMD2<UInt32> = .zero
        var planeMin: SIMD2<Float> = .zero
        var planeSize: SIMD2<Float> = .zero
        var range: Float = 0
        var segmentCount: UInt32 = 0
        var maxDistance: Float = 0
        var padding: UInt32 = 0
    }

    private func shapeGlyphs(
        in text: String,
        baseFont: CTFont
    ) -> ShapedLine {
        let attributedString = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: baseFont
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedString)
        let lineBounds = CTLineGetBoundsWithOptions(
            line,
            [.useGlyphPathBounds, .excludeTypographicLeading]
        )

        var shapedGlyphs: [ShapedGlyph] = []
        let runs = CTLineGetGlyphRuns(line) as NSArray
        for case let run as CTRun in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }

            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont =
                (attributes[kCTFontAttributeName] as! CTFont?) ?? baseFont

            var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
            var positions = Array(repeating: CGPoint.zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)

            shapedGlyphs.reserveCapacity(shapedGlyphs.count + glyphCount)
            for index in 0..<glyphCount {
                shapedGlyphs.append(
                    ShapedGlyph(
                        glyph: glyphs[index],
                        font: runFont,
                        position: positions[index]
                    )
                )
            }
        }

        return ShapedLine(
            lineBounds: lineBounds,
            glyphs: shapedGlyphs
        )
    }

    private struct GlyphContours {
        private static let edgeColorMasks: [UInt32] = [0x3, 0x6, 0x5]

        private let path: CGPath

        init(path: CGPath) {
            self.path = path
        }

        func makeMSDFSegments(flatness: CGFloat) -> [GPUAtlasSegment] {
            let contours = makeContours(flatness: max(flatness, 0.1))
            guard !contours.isEmpty else { return [] }

            var coloredSegments: [GPUAtlasSegment] = []
            for contour in contours {
                let colors = colorMasks(for: contour)
                for (edge, colorMask) in zip(contour.edges, colors) {
                    for segment in edge.segments {
                        coloredSegments.append(
                            GPUAtlasSegment(
                                start: segment.start.simd2,
                                end: segment.end.simd2,
                                colorMask: colorMask
                            )
                        )
                    }
                }
            }

            return coloredSegments
        }

        private func makeContours(flatness: CGFloat) -> [Contour] {
            var contours: [Contour] = []
            var currentEdges: [ContourEdge] = []
            var contourStart: CGPoint?
            var currentPoint: CGPoint?

            func flushCurrentContour(close: Bool) {
                guard let currentPoint, let contourStart else {
                    currentEdges.removeAll(keepingCapacity: true)
                    return
                }

                if close,
                    !Self.pointsAreNear(currentPoint, contourStart),
                    let closingEdge = Self.makeLineEdge(
                        from: currentPoint,
                        to: contourStart
                    )
                {
                    currentEdges.append(closingEdge)
                }

                if !currentEdges.isEmpty {
                    contours.append(Contour(edges: currentEdges))
                }

                currentEdges.removeAll(keepingCapacity: true)
            }

            path.forEach { element in
                let points = element.points

                switch element.type {
                case .moveToPoint:
                    flushCurrentContour(close: false)
                    contourStart = points[0]
                    currentPoint = points[0]

                case .addLineToPoint:
                    guard let current = currentPoint else { return }
                    if let edge = Self.makeLineEdge(
                        from: current,
                        to: points[0]
                    ) {
                        currentEdges.append(edge)
                    }
                    currentPoint = points[0]

                case .addQuadCurveToPoint:
                    guard let current = currentPoint else { return }
                    if let edge = Self.makeQuadraticEdge(
                        from: current,
                        control: points[0],
                        to: points[1],
                        flatness: flatness
                    ) {
                        currentEdges.append(edge)
                    }
                    currentPoint = points[1]

                case .addCurveToPoint:
                    guard let current = currentPoint else { return }
                    if let edge = Self.makeCubicEdge(
                        from: current,
                        control1: points[0],
                        control2: points[1],
                        to: points[2],
                        flatness: flatness
                    ) {
                        currentEdges.append(edge)
                    }
                    currentPoint = points[2]

                case .closeSubpath:
                    flushCurrentContour(close: true)
                    contourStart = nil
                    currentPoint = nil

                @unknown default:
                    break
                }
            }

            flushCurrentContour(close: false)
            return contours
        }

        private func colorMasks(for contour: Contour) -> [UInt32] {
            let edgeCount = contour.edges.count
            guard edgeCount > 0 else { return [] }
            guard edgeCount > 1 else { return [0x7] }

            let sharpCorners = contour.edges.indices.filter { index in
                let previous = contour.edges[
                    (index + edgeCount - 1) % edgeCount
                ]
                let current = contour.edges[index]
                return Self.isSharpCorner(
                    previous: previous.endTangent,
                    next: current.startTangent
                )
            }

            guard sharpCorners.count >= 3 else {
                return Self.distributedColorMasks(edgeCount: edgeCount)
            }

            let sharpSet = Set(sharpCorners)
            var currentColorIndex = 0
            var colors = Array(
                repeating: Self.edgeColorMasks[0],
                count: edgeCount
            )

            for index in 0..<edgeCount {
                colors[index] = Self.edgeColorMasks[currentColorIndex]
                let nextIndex = (index + 1) % edgeCount
                if sharpSet.contains(nextIndex) {
                    currentColorIndex =
                        (currentColorIndex + 1) % Self.edgeColorMasks.count
                }
            }

            return Set(colors).count >= 2
                ? colors
                : Self.distributedColorMasks(edgeCount: edgeCount)
        }

        private static func distributedColorMasks(edgeCount: Int) -> [UInt32] {
            guard edgeCount > 0 else { return [] }
            guard edgeCount > 1 else { return [0x7] }

            var colors = Array(repeating: UInt32(0), count: edgeCount)
            for index in 0..<edgeCount {
                let bucket = min(
                    edgeColorMasks.count - 1,
                    Int(
                        floor(
                            Double(index) * Double(edgeColorMasks.count)
                                / Double(edgeCount)
                        )
                    )
                )
                colors[index] = edgeColorMasks[bucket]
            }

            if Set(colors).count == 1 {
                for index in 0..<edgeCount {
                    colors[index] = edgeColorMasks[index % edgeColorMasks.count]
                }
            }
            return colors
        }

        private static func isSharpCorner(
            previous: SIMD2<Float>,
            next: SIMD2<Float>
        ) -> Bool {
            let dotValue = max(-1 as Float, min(1, simd_dot(previous, next)))
            let crossValue = abs(previous.x * next.y - previous.y * next.x)
            let turnAngle = atan2(crossValue, dotValue)
            return turnAngle > 0.32
        }

        private static func makeLineEdge(
            from start: CGPoint,
            to end: CGPoint
        ) -> ContourEdge? {
            makeEdge(from: [start, end])
        }

        private static func makeQuadraticEdge(
            from start: CGPoint,
            control: CGPoint,
            to end: CGPoint,
            flatness: CGFloat
        ) -> ContourEdge? {
            var points = [start]
            flattenQuadratic(
                from: start,
                control: control,
                to: end,
                flatness: flatness,
                into: &points
            )
            return makeEdge(from: points)
        }

        private static func makeCubicEdge(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            to end: CGPoint,
            flatness: CGFloat
        ) -> ContourEdge? {
            var points = [start]
            flattenCubic(
                from: start,
                control1: control1,
                control2: control2,
                to: end,
                flatness: flatness,
                into: &points
            )
            return makeEdge(from: points)
        }

        private static func makeEdge(from points: [CGPoint]) -> ContourEdge? {
            guard points.count >= 2 else { return nil }

            var segments: [LineSegment] = []
            segments.reserveCapacity(points.count - 1)
            for index in 1..<points.count {
                let start = points[index - 1]
                let end = points[index]
                guard !pointsAreNear(start, end) else { continue }
                segments.append(LineSegment(start: start, end: end))
            }

            guard
                let firstSegment = segments.first,
                let lastSegment = segments.last
            else {
                return nil
            }

            return ContourEdge(
                segments: segments,
                startTangent: normalizedDirection(
                    from: firstSegment.start,
                    to: firstSegment.end
                ),
                endTangent: normalizedDirection(
                    from: lastSegment.start,
                    to: lastSegment.end
                )
            )
        }

        private static func flattenQuadratic(
            from start: CGPoint,
            control: CGPoint,
            to end: CGPoint,
            flatness: CGFloat,
            into points: inout [CGPoint]
        ) {
            if quadraticFlatness(
                from: start,
                control: control,
                to: end
            ) <= flatness {
                points.append(end)
                return
            }

            let startControl = midpoint(start, control)
            let controlEnd = midpoint(control, end)
            let middle = midpoint(startControl, controlEnd)
            flattenQuadratic(
                from: start,
                control: startControl,
                to: middle,
                flatness: flatness,
                into: &points
            )
            flattenQuadratic(
                from: middle,
                control: controlEnd,
                to: end,
                flatness: flatness,
                into: &points
            )
        }

        private static func flattenCubic(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            to end: CGPoint,
            flatness: CGFloat,
            into points: inout [CGPoint]
        ) {
            if cubicFlatness(
                from: start,
                control1: control1,
                control2: control2,
                to: end
            ) <= flatness {
                points.append(end)
                return
            }

            let p01 = midpoint(start, control1)
            let p12 = midpoint(control1, control2)
            let p23 = midpoint(control2, end)
            let p012 = midpoint(p01, p12)
            let p123 = midpoint(p12, p23)
            let middle = midpoint(p012, p123)

            flattenCubic(
                from: start,
                control1: p01,
                control2: p012,
                to: middle,
                flatness: flatness,
                into: &points
            )
            flattenCubic(
                from: middle,
                control1: p123,
                control2: p23,
                to: end,
                flatness: flatness,
                into: &points
            )
        }

        private static func quadraticFlatness(
            from start: CGPoint,
            control: CGPoint,
            to end: CGPoint
        ) -> CGFloat {
            pointLineDistance(point: control, lineStart: start, lineEnd: end)
        }

        private static func cubicFlatness(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            to end: CGPoint
        ) -> CGFloat {
            max(
                pointLineDistance(
                    point: control1,
                    lineStart: start,
                    lineEnd: end
                ),
                pointLineDistance(
                    point: control2,
                    lineStart: start,
                    lineEnd: end
                )
            )
        }

        private static func pointLineDistance(
            point: CGPoint,
            lineStart: CGPoint,
            lineEnd: CGPoint
        ) -> CGFloat {
            let dx = lineEnd.x - lineStart.x
            let dy = lineEnd.y - lineStart.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0.000_001 else {
                return hypot(point.x - lineStart.x, point.y - lineStart.y)
            }

            let t = max(
                0,
                min(
                    1,
                    ((point.x - lineStart.x) * dx + (point.y - lineStart.y)
                        * dy)
                        / lengthSquared
                )
            )
            let nearest = CGPoint(
                x: lineStart.x + dx * t,
                y: lineStart.y + dy * t
            )
            return hypot(point.x - nearest.x, point.y - nearest.y)
        }

        private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint
        {
            CGPoint(x: (lhs.x + rhs.x) * 0.5, y: (lhs.y + rhs.y) * 0.5)
        }

        private static func normalizedDirection(
            from start: CGPoint,
            to end: CGPoint
        ) -> SIMD2<Float> {
            let delta = SIMD2(
                Float(end.x - start.x),
                Float(end.y - start.y)
            )
            let length = simd_length(delta)
            guard length > 0.000_001 else {
                return SIMD2(1, 0)
            }
            return delta / length
        }

        private static func pointsAreNear(
            _ lhs: CGPoint,
            _ rhs: CGPoint
        ) -> Bool {
            hypot(lhs.x - rhs.x, lhs.y - rhs.y) <= 0.000_5
        }

        private struct Contour {
            let edges: [ContourEdge]
        }

        private struct ContourEdge {
            let segments: [LineSegment]
            let startTangent: SIMD2<Float>
            let endTangent: SIMD2<Float>
        }

        private struct LineSegment {
            let start: CGPoint
            let end: CGPoint
        }
    }

    private struct FilledGlyphDistanceField {
        private let path: CGPath

        init(path: CGPath) {
            self.path = path
        }

        func makeEncodedSDFAlphaBitmap(
            bounds: CGRect,
            pixelWidth: Int,
            pixelHeight: Int,
            range: CGFloat
        ) -> [UInt8] {
            guard pixelWidth > 0, pixelHeight > 0 else { return [] }

            let mask = rasterizeMask(
                bounds: bounds,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            let scaleX = CGFloat(pixelWidth) / max(bounds.width, 0.000_001)
            let scaleY = CGFloat(pixelHeight) / max(bounds.height, 0.000_001)
            let pixelRange = max(1, Float(range * min(scaleX, scaleY)))

            let count = pixelWidth * pixelHeight
            var result = Array(repeating: UInt8(0), count: count)

            mask.withUnsafeBufferPointer { maskBuf in
                guard let maskPtr = maskBuf.baseAddress else { return }

                let infinity: Float = 1e10
                let grid = UnsafeMutablePointer<Float>.allocate(capacity: count)
                let intermediate = UnsafeMutablePointer<Float>.allocate(capacity: count)
                let distanceOut = UnsafeMutablePointer<Float>.allocate(capacity: count)
                let maxLen = max(pixelWidth, pixelHeight)
                let v = UnsafeMutablePointer<Int>.allocate(capacity: maxLen)
                let z = UnsafeMutablePointer<Float>.allocate(capacity: maxLen + 1)

                defer {
                    grid.deallocate()
                    intermediate.deallocate()
                    distanceOut.deallocate()
                    v.deallocate()
                    z.deallocate()
                }

                for i in 0..<count {
                    grid[i] = maskPtr[i] >= 128 ? 0 : infinity
                }

                Self.distanceTransform(
                    grid: grid,
                    width: pixelWidth,
                    height: pixelHeight,
                    output: distanceOut,
                    intermediate: intermediate,
                    v: v,
                    z: z
                )

                let signedDistances = UnsafeMutablePointer<Float>.allocate(capacity: count)
                defer { signedDistances.deallocate() }

                for i in 0..<count {
                    signedDistances[i] = -sqrt(distanceOut[i])
                }

                for i in 0..<count {
                    grid[i] = maskPtr[i] >= 128 ? infinity : 0
                }

                Self.distanceTransform(
                    grid: grid,
                    width: pixelWidth,
                    height: pixelHeight,
                    output: distanceOut,
                    intermediate: intermediate,
                    v: v,
                    z: z
                )

                result.withUnsafeMutableBufferPointer { resultBuf in
                    guard let resultPtr = resultBuf.baseAddress else { return }
                    let scale = 1.0 / (pixelRange * 2.0)
                    for i in 0..<count {
                        let distance = signedDistances[i] + sqrt(distanceOut[i])
                        let normalized = min(max(0.5 + distance * scale, 0), 1)
                        resultPtr[i] = UInt8((normalized * 255.0).rounded())
                    }
                }
            }

            return result
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

        private static func distanceTransform(
            grid: UnsafePointer<Float>,
            width: Int,
            height: Int,
            output: UnsafeMutablePointer<Float>,
            intermediate: UnsafeMutablePointer<Float>,
            v: UnsafeMutablePointer<Int>,
            z: UnsafeMutablePointer<Float>
        ) {
            for x in 0..<width {
                distanceTransform1D(
                    input: grid + x,
                    inputStride: width,
                    length: height,
                    output: intermediate + x,
                    outputStride: width,
                    v: v,
                    z: z
                )
            }

            for y in 0..<height {
                let offset = y * width
                distanceTransform1D(
                    input: intermediate + offset,
                    inputStride: 1,
                    length: width,
                    output: output + offset,
                    outputStride: 1,
                    v: v,
                    z: z
                )
            }
        }

        private static func distanceTransform1D(
            input: UnsafePointer<Float>,
            inputStride: Int,
            length: Int,
            output: UnsafeMutablePointer<Float>,
            outputStride: Int,
            v: UnsafeMutablePointer<Int>,
            z: UnsafeMutablePointer<Float>
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
                        ((input[q * inputStride] + Float(q * q))
                            - (input[previous * inputStride] + Float(previous * previous)))
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
                output[q * outputStride] = delta * delta + input[v[k] * inputStride]
            }
        }
    }

    extension CGPoint {
        fileprivate var simd2: SIMD2<Float> {
            SIMD2(Float(x), Float(y))
        }
    }

    extension CGPath {
        fileprivate func forEach(_ body: @escaping (CGPathElement) -> Void) {
            applyWithBlock { elementPointer in
                body(elementPointer.pointee)
            }
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
