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
            metalRenderer?.draw(in: view, drawable: drawable)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func redrawUsingLatestState(on view: PassthroughDanmakuMTKView)
        {
            guard
                latestRequestedViewportSize.width > 0,
                latestRequestedViewportSize.height > 0
            else {
                return
            }

            refresh(
                view: view,
                playbackTime: latestPlaybackTime,
                requestedViewportSize: latestRequestedViewportSize,
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
            if requestedViewportSize.width > 0.5,
                requestedViewportSize.height > 0.5
            {
                return requestedViewportSize
            }

            let boundsSize = view.bounds.size
            guard boundsSize.width > 0.5, boundsSize.height > 0.5 else {
                return .zero
            }
            return boundsSize
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
            contentScale: Float
        ) {
            let configuration = store.configuration
            let fontSignature = FontSignature(configuration: configuration)

            frameUniforms = GPUDanmakuUniforms(
                viewportSize: SIMD2(
                    Float(viewportSize.width),
                    Float(viewportSize.height)
                ),
                playbackTime: Float(playbackTime),
                horizontalInset: Float(metrics.horizontalInset),
                contentScale: contentScale,
                glyphCount: UInt32(glyphCount)
            )

            if preparedVersion != store.contentVersion
                || preparedViewport != viewportSize
                || preparedMetrics != metrics
                || preparedFontSignature != fontSignature
            {
                rebuildBuffers(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    configuration: configuration
                )
                preparedVersion = store.contentVersion
                preparedViewport = viewportSize
                preparedMetrics = metrics
                preparedFontSignature = fontSignature
            }

            uniformBuffer = Self.makeBuffer(
                device: device,
                value: frameUniforms
            )
        }

        func draw(in view: MTKView, drawable: CAMetalDrawable) {
            guard
                let descriptor = view.currentRenderPassDescriptor,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                return
            }

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

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func rebuildBuffers(
            store: DanmakuRendererStore,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            configuration: DanmakuRenderConfiguration
        ) {
            atlas.prepare(configuration: configuration)

            do {
                let snapshot = try buildSnapshot(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    configuration: configuration
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
                if !store.activeItems.isEmpty, snapshot.glyphs.isEmpty {
                    Self.logger.error(
                        "Prepared zero glyphs for \(store.activeItems.count) active danmaku items"
                    )
                }
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
            configuration: DanmakuRenderConfiguration
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
                    configuration: configuration
                )
            } catch DynamicMSDFAtlas.AtlasError.restartBuild {
                atlas.resetKeepingConfiguration()
                return try buildSnapshotPass(
                    store: store,
                    viewportSize: viewportSize,
                    metrics: metrics,
                    font: font,
                    configuration: configuration
                )
            }
        }

        private func buildSnapshotPass(
            store: DanmakuRendererStore,
            viewportSize: CGSize,
            metrics: DanmakuLayoutMetrics,
            font: CTFont,
            configuration: DanmakuRenderConfiguration
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
                                font: runFont
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
            return withUnsafeBytes(of: &copy) { rawBuffer in
                device.makeBuffer(
                    bytes: rawBuffer.baseAddress!,
                    length: rawBuffer.count,
                    options: .storageModeShared
                )
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
                uint glyphCount;
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

            fragment float4 danmakuFragmentMain(
                VertexOut in [[stage_in]],
                texture2d<float> atlas [[texture(0)]],
                sampler atlasSampler [[sampler(0)]]
            ) {
                if (in.color.a <= 0.0) {
                    discard_fragment();
                }

                float glyphAlpha = atlas.sample(atlasSampler, in.uv).a;
                float2 texel = 1.0 / float2(atlas.get_width(), atlas.get_height());
                float2 outlineTexel = texel * 1.75;
                float outlineSource = 0.0;
                const float2 outlineOffsets[8] = {
                    float2( 1.0,  0.0),
                    float2(-1.0,  0.0),
                    float2( 0.0,  1.0),
                    float2( 0.0, -1.0),
                    float2( 1.0,  1.0),
                    float2(-1.0,  1.0),
                    float2( 1.0, -1.0),
                    float2(-1.0, -1.0),
                };

                for (uint index = 0; index < 8; index++) {
                    outlineSource = max(
                        outlineSource,
                        atlas.sample(
                            atlasSampler,
                            in.uv + outlineOffsets[index] * outlineTexel
                        ).a
                    );
                }

                float fillAlpha = glyphAlpha * in.color.a;
                float outlineAlpha = clamp(outlineSource - glyphAlpha, 0.0, 1.0)
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

    private final class DynamicMSDFAtlas {
        enum AtlasError: Error {
            case restartBuild
        }

        struct GlyphEntry {
            let planeBounds: CGRect
            let uvMin: SIMD2<Float>
            let uvMax: SIMD2<Float>
        }

        private let device: MTLDevice
        private let atlasSize: Int
        private let pixelRange: Int
        private let atlasScale: CGFloat

        private(set) var texture: MTLTexture
        private var configurationSignature: FontSignature?
        private var nextOrigin = SIMD2<Int>(0, 0)
        private var currentRowHeight = 0
        private var glyphCache: [CGGlyph: GlyphEntry] = [:]

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

        func resetKeepingConfiguration() {
            nextOrigin = SIMD2<Int>(0, 0)
            currentRowHeight = 0
            glyphCache.removeAll(keepingCapacity: true)
            texture = Self.makeTexture(device: device, size: atlasSize)
        }

        func entry(for glyph: CGGlyph, font: CTFont) throws -> GlyphEntry? {
            if let cached = glyphCache[glyph] {
                return cached
            }

            var mutableGlyph = glyph
            let glyphBounds = CTFontGetBoundingRectsForGlyphs(
                font,
                .default,
                &mutableGlyph,
                nil,
                1
            )
            guard glyphBounds.width > 0, glyphBounds.height > 0 else {
                return nil
            }

            let padding = CGFloat(pixelRange) / atlasScale
            let planeBounds = glyphBounds.insetBy(dx: -padding, dy: -padding)
            let bitmapWidth = max(2, Int(ceil(planeBounds.width * atlasScale)))
            let bitmapHeight = max(
                2,
                Int(ceil(planeBounds.height * atlasScale))
            )
            let textureRect = try allocateRect(
                width: bitmapWidth,
                height: bitmapHeight
            )
            let bitmap = rasterizeGlyph(
                glyph,
                font: font,
                bounds: planeBounds,
                pixelWidth: bitmapWidth,
                pixelHeight: bitmapHeight
            )

            bitmap.withUnsafeBytes { rawBuffer in
                texture.replace(
                    region: MTLRegionMake2D(
                        Int(textureRect.origin.x),
                        Int(textureRect.origin.y),
                        bitmapWidth,
                        bitmapHeight
                    ),
                    mipmapLevel: 0,
                    withBytes: rawBuffer.baseAddress!,
                    bytesPerRow: bitmapWidth * 4
                )
            }

            let entry = GlyphEntry(
                planeBounds: planeBounds,
                uvMin: SIMD2(
                    Float(textureRect.minX) / Float(atlasSize),
                    Float(textureRect.minY) / Float(atlasSize)
                ),
                uvMax: SIMD2(
                    Float(textureRect.maxX) / Float(atlasSize),
                    Float(textureRect.maxY) / Float(atlasSize)
                )
            )
            glyphCache[glyph] = entry
            return entry
        }

        private func rasterizeGlyph(
            _ glyph: CGGlyph,
            font: CTFont,
            bounds: CGRect,
            pixelWidth: Int,
            pixelHeight: Int
        ) -> [UInt8] {
            var pixels = Array(
                repeating: UInt8(0),
                count: pixelWidth * pixelHeight * 4
            )
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            pixels.withUnsafeMutableBytes { rawBuffer in
                guard
                    let context = CGContext(
                        data: rawBuffer.baseAddress,
                        width: pixelWidth,
                        height: pixelHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: pixelWidth * 4,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else {
                    return
                }

                context.clear(
                    CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
                )
                context.setAllowsAntialiasing(true)
                context.setShouldAntialias(true)
                context.interpolationQuality = .high
                context.setFillColor(
                    CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                )
                context.translateBy(
                    x: -bounds.minX * atlasScale,
                    y: bounds.maxY * atlasScale
                )
                context.scaleBy(x: atlasScale, y: -atlasScale)

                var glyphCopy = glyph
                var position = CGPoint.zero
                CTFontDrawGlyphs(font, &glyphCopy, &position, 1, context)
            }

            return pixels
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
        var glyphCount: UInt32 = 0
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
        private struct Contour {
            var points: [CGPoint]
        }

        private struct Segment {
            let start: CGPoint
            let end: CGPoint
            let channel: Int

            func distanceSquared(to point: CGPoint) -> CGFloat {
                let dx = end.x - start.x
                let dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                guard lengthSquared > 0.000_001 else {
                    let px = point.x - start.x
                    let py = point.y - start.y
                    return px * px + py * py
                }

                let t = max(
                    0,
                    min(
                        1,
                        ((point.x - start.x) * dx + (point.y - start.y) * dy)
                            / lengthSquared
                    )
                )
                let projected = CGPoint(
                    x: start.x + dx * t,
                    y: start.y + dy * t
                )
                let px = point.x - projected.x
                let py = point.y - projected.y
                return px * px + py * py
            }
        }

        private let contours: [Contour]
        private let allSegments: [Segment]

        init(path: CGPath) {
            contours = Self.flattenContours(from: path)
            allSegments = contours.flatMap { contour in
                guard contour.points.count > 1 else { return [Segment]() }
                return contour.points.enumerated().compactMap { index, point in
                    let nextIndex = (index + 1) % contour.points.count
                    guard nextIndex != index else { return nil }
                    return Segment(
                        start: point,
                        end: contour.points[nextIndex],
                        channel: index % 3
                    )
                }
            }
        }

        func makeMSDFBitmap(
            bounds: CGRect,
            pixelWidth: Int,
            pixelHeight: Int,
            range: CGFloat
        ) -> [UInt8] {
            guard !allSegments.isEmpty else {
                return Array(repeating: 0, count: pixelWidth * pixelHeight * 4)
            }

            var pixels = Array(
                repeating: UInt8(0),
                count: pixelWidth * pixelHeight * 4
            )
            let scaleX = bounds.width / CGFloat(pixelWidth)
            let scaleY = bounds.height / CGFloat(pixelHeight)

            for row in 0..<pixelHeight {
                for column in 0..<pixelWidth {
                    let sample = CGPoint(
                        x: bounds.minX + (CGFloat(column) + 0.5) * scaleX,
                        y: bounds.maxY - (CGFloat(row) + 0.5) * scaleY
                    )
                    let inside = contains(sample)
                    let signedDistances = (0..<3).map { channel in
                        signedDistance(
                            to: sample,
                            channel: channel,
                            inside: inside
                        )
                    }

                    let base = (row * pixelWidth + column) * 4
                    pixels[base] = encode(
                        distance: signedDistances[0],
                        range: range
                    )
                    pixels[base + 1] = encode(
                        distance: signedDistances[1],
                        range: range
                    )
                    pixels[base + 2] = encode(
                        distance: signedDistances[2],
                        range: range
                    )
                    pixels[base + 3] = 255
                }
            }

            return pixels
        }

        private func signedDistance(
            to point: CGPoint,
            channel: Int,
            inside: Bool
        ) -> CGFloat {
            let channelSegments = allSegments.filter { $0.channel == channel }
            let segments =
                channelSegments.isEmpty ? allSegments : channelSegments
            let minimumDistanceSquared =
                segments.map { $0.distanceSquared(to: point) }.min() ?? 0
            let distance = sqrt(minimumDistanceSquared)
            return inside ? distance : -distance
        }

        private func contains(_ point: CGPoint) -> Bool {
            var windingCount = 0

            for segment in allSegments {
                let y1 = segment.start.y
                let y2 = segment.end.y
                let intersects = (y1 > point.y) != (y2 > point.y)
                guard intersects else { continue }

                let intersectionX =
                    (segment.end.x - segment.start.x) * (point.y - y1)
                    / (y2 - y1) + segment.start.x
                if point.x < intersectionX {
                    windingCount += 1
                }
            }

            return windingCount % 2 == 1
        }

        private func encode(distance: CGFloat, range: CGFloat) -> UInt8 {
            let normalized = min(max(0.5 + distance / (range * 2), 0), 1)
            return UInt8((normalized * 255).rounded())
        }

        private static func flattenContours(from path: CGPath) -> [Contour] {
            var contours: [Contour] = []
            var currentPoints: [CGPoint] = []
            var currentPoint = CGPoint.zero
            var subpathStart = CGPoint.zero

            path.applyWithBlock { pointer in
                let element = pointer.pointee
                switch element.type {
                case .moveToPoint:
                    if currentPoints.count > 1 {
                        contours.append(Contour(points: currentPoints))
                    }
                    let point = element.points[0]
                    currentPoints = [point]
                    currentPoint = point
                    subpathStart = point
                case .addLineToPoint:
                    let point = element.points[0]
                    currentPoints.append(point)
                    currentPoint = point
                case .addQuadCurveToPoint:
                    let control = element.points[0]
                    let end = element.points[1]
                    let samples = curveSampleCount(
                        from: currentPoint,
                        control: control,
                        end: end
                    )
                    for sampleIndex in 1...samples {
                        let t = CGFloat(sampleIndex) / CGFloat(samples)
                        currentPoints.append(
                            quadraticPoint(
                                start: currentPoint,
                                control: control,
                                end: end,
                                t: t
                            )
                        )
                    }
                    currentPoint = end
                case .addCurveToPoint:
                    let control1 = element.points[0]
                    let control2 = element.points[1]
                    let end = element.points[2]
                    let samples = cubicSampleCount(
                        from: currentPoint,
                        control1: control1,
                        control2: control2,
                        end: end
                    )
                    for sampleIndex in 1...samples {
                        let t = CGFloat(sampleIndex) / CGFloat(samples)
                        currentPoints.append(
                            cubicPoint(
                                start: currentPoint,
                                control1: control1,
                                control2: control2,
                                end: end,
                                t: t
                            )
                        )
                    }
                    currentPoint = end
                case .closeSubpath:
                    if currentPoints.count > 1 {
                        if currentPoints.last != subpathStart {
                            currentPoints.append(subpathStart)
                        }
                        contours.append(Contour(points: currentPoints))
                    }
                    currentPoints = []
                    currentPoint = subpathStart
                @unknown default:
                    break
                }
            }

            if currentPoints.count > 1 {
                contours.append(Contour(points: currentPoints))
            }

            return contours
        }

        private static func curveSampleCount(
            from start: CGPoint,
            control: CGPoint,
            end: CGPoint
        ) -> Int {
            let length =
                hypot(control.x - start.x, control.y - start.y)
                + hypot(end.x - control.x, end.y - control.y)
            return max(8, Int(length / 2))
        }

        private static func cubicSampleCount(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            end: CGPoint
        ) -> Int {
            let length =
                hypot(control1.x - start.x, control1.y - start.y)
                + hypot(control2.x - control1.x, control2.y - control1.y)
                + hypot(end.x - control2.x, end.y - control2.y)
            return max(10, Int(length / 2))
        }

        private static func quadraticPoint(
            start: CGPoint,
            control: CGPoint,
            end: CGPoint,
            t: CGFloat
        ) -> CGPoint {
            let oneMinusT = 1 - t
            let x =
                oneMinusT * oneMinusT * start.x
                + 2 * oneMinusT * t * control.x
                + t * t * end.x
            let y =
                oneMinusT * oneMinusT * start.y
                + 2 * oneMinusT * t * control.y
                + t * t * end.y
            return CGPoint(x: x, y: y)
        }

        private static func cubicPoint(
            start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            end: CGPoint,
            t: CGFloat
        ) -> CGPoint {
            let oneMinusT = 1 - t
            let x =
                oneMinusT * oneMinusT * oneMinusT * start.x
                + 3 * oneMinusT * oneMinusT * t * control1.x
                + 3 * oneMinusT * t * t * control2.x
                + t * t * t * end.x
            let y =
                oneMinusT * oneMinusT * oneMinusT * start.y
                + 3 * oneMinusT * oneMinusT * t * control1.y
                + 3 * oneMinusT * t * t * control2.y
                + t * t * t * end.y
            return CGPoint(x: x, y: y)
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
