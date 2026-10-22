#if canImport(Metal)
import CoreGraphics
import Foundation
import Metal
import MyriaGeometry
import ZoneAtlas

public enum MetalMapRendererError: Error {
    case noDevice
    case creationFailed(String)
}

/// What to draw in one frame of the map.
public struct MapFrame: Sendable, Equatable {
    /// A zone group outlined on top of the map.
    public struct Highlight: Sendable, Hashable {
        public var group: Int
        /// Points.
        public var width: Double

        public init(group: Int, width: Double) {
            self.group = group
            self.width = width
        }
    }

    public var viewport: Viewport
    /// Pixels per point.
    public var contentsScale: Double
    /// 0 folds the map into a globe, 1 lays it flat.
    public var unfold: Double = 1
    public var date: Date
    public var style: MapStyle
    public var showNight = true
    public var showLand = true
    public var showCoastlines = true
    public var showBorders = true
    public var showCuts = false
    public var showMesh = false
    /// Outlines and labels are drawn on the flat map only.
    public var highlights: [Highlight] = []
    public var labels: [SceneText] = []

    public init(viewport: Viewport, contentsScale: Double, date: Date, style: MapStyle) {
        self.viewport = viewport
        self.contentsScale = contentsScale
        self.date = date
        self.style = style
    }

    public static func == (a: MapFrame, b: MapFrame) -> Bool {
        a.viewport == b.viewport && a.contentsScale == b.contentsScale && a.unfold == b.unfold && a.date == b.date
            && a.style == b.style && a.showNight == b.showNight && a.showLand == b.showLand
            && a.showCoastlines == b.showCoastlines && a.showBorders == b.showBorders && a.showCuts == b.showCuts
            && a.showMesh == b.showMesh && a.highlights == b.highlights
            && a.labels.elementsEqual(b.labels) {
                $0.text == $1.text && $0.position == $1.position && $0.size == $1.size && $0.color == $1.color
            }
    }
}

/// A mesh's geometry on the GPU, shared by every map cut from that mesh.
public final class GPUMesh: @unchecked Sendable {
    public let kind: MeshKind
    /// Kept to regroup each map's share of it.
    let source: RenderMesh
    let faceCount: Int
    let zoneVertices: Buffer
    let landVertices: Buffer
    let zoneOutlines: Buffer
    let faceCorners: Buffer
    let planes: Buffer

    init(device: MTLDevice, kind: MeshKind, mesh: RenderMesh) throws {
        self.kind = kind
        source = mesh
        faceCount = mesh.faceCount
        zoneVertices = try Buffer(device, mesh.zoneVertices, "zone corners")
        landVertices = try Buffer(device, mesh.landVertices, "land corners")
        zoneOutlines = try Buffer(device, mesh.zoneOutlines, "zone outlines")
        faceCorners = try Buffer(device, mesh.faceVertices, "face corners")
        planes = try Buffer(device, mesh.planes, "face planes")
    }
}

/// A map on the GPU: its mesh's geometry plus what depends on the cuts.
/// Built anywhere, then used from one thread at a time.
public final class GPUMap: @unchecked Sendable {
    public let map: MyriaMap
    public let mesh: GPUMesh
    let cells: MapCells
    let flatTransforms: Buffer
    let cuts: Buffer
    let zoneIndices: Buffer
    let landIndices: Buffer
    let faceIndices: Buffer
    /// The face corners on the flat map, worked out once in double
    /// precision, so faces meeting at a hinge share their corners exactly.
    let flatFaceCorners: Buffer
    let seals: Buffer
    let coastlines: Buffer
    let borders: Buffer
    let faceEdges: Buffer
    private var folding: Folding?
    /// Scratch space for folded frames.
    var poses: [Pose3] = []
    private var outlines: [Int: Buffer] = [:]
    private var colors: (style: MapStyle, buffer: Buffer)?

    init(device: MTLDevice, map: MyriaMap, mesh: GPUMesh) throws {
        self.map = map
        self.mesh = mesh
        let cells = MapCells(map: map, mesh: mesh.source)
        self.cells = cells
        flatTransforms = try Buffer(device, map.flatFaceTransforms(), "flat transforms")
        cuts = try Buffer(device, map.cutSegments(), "cuts")
        zoneIndices = try Buffer(device, cells.zoneIndices, "zone triangles")
        landIndices = try Buffer(device, cells.landIndices, "land triangles")
        faceIndices = try Buffer(device, cells.faceIndices, "face triangles")
        flatFaceCorners = try Buffer(device, map.flatFaceCorners(mesh.source), "flat face corners")
        seals = try Buffer(device, cells.seals, "seals")
        coastlines = try Buffer(device, cells.coastlines, "coastlines")
        borders = try Buffer(device, cells.borders, "borders")
        faceEdges = try Buffer(device, cells.faceEdges, "face edges")
    }

    func foldingGeometry() -> Folding {
        if let folding { return folding }
        let made = map.folding()
        folding = made
        return made
    }

    func outline(ofGroup g: Int, device: MTLDevice) -> Buffer? {
        if let buffer = outlines[g] { return buffer }
        let buffer = try? Buffer(device, map.outlineSegments(ofGroup: g), "outline")
        outlines[g] = buffer
        return buffer
    }

    func regionColors(_ style: MapStyle, device: MTLDevice) -> Buffer? {
        if let colors, colors.style == style { return colors.buffer }
        // Groups are painted in order on the flat map; depth keeps that
        // order wherever pieces overlap.
        let groups = map.grouping.groups.count
        let regions = zip(map.regionColors(style: style), map.grouping.groupOfRegion).map { color, g in
            RegionStyle(color: color.simd, depth: Float(0.5 - 0.4 * Double(g + 1) / Double(groups + 1)))
        }
        guard let buffer = try? Buffer(device, regions, "region styles") else { return nil }
        colors = (style, buffer)
        return buffer
    }
}

/// An MTLBuffer with its element count.
struct Buffer {
    let buffer: MTLBuffer?
    let count: Int

    init<T>(_ device: MTLDevice, _ elements: [T], _ label: String) throws {
        count = elements.count
        guard !elements.isEmpty else {
            buffer = nil
            return
        }
        guard let buffer = elements.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw MetalMapRendererError.creationFailed(label) }
        buffer.label = label
        self.buffer = buffer
    }
}

/// Draws the map with Metal: fills as triangles from static buffers,
/// lines and night computed on the GPU, so panning, zooming, folding and
/// moving through time only change a few uniforms.
public final class MetalMapRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    let queue: MTLCommandQueue
    let zonePipeline: MTLRenderPipelineState
    let underlayPipeline: MTLRenderPipelineState
    let sealPipeline: MTLRenderPipelineState
    let fillPipeline: MTLRenderPipelineState
    let coveragePipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let labelPipeline: MTLRenderPipelineState
    let depthAlways: MTLDepthStencilState
    let depthWrite: MTLDepthStencilState
    let depthTest: MTLDepthStencilState
    let sampler: MTLSamplerState
    let labelTextures: LabelTextures
    private var targets: Targets?
    /// Folded frames write their transforms into one of these in turn.
    private var transformRing: [MTLBuffer?] = [nil, nil, nil]
    private var ringIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)

    static let sampleCount = 4
    static let lineFormat = MTLPixelFormat.rgba8Unorm
    static let highlightFormat = MTLPixelFormat.r8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device else { throw MetalMapRendererError.noDevice }
        shaderLayoutChecks
        self.device = device
        self.pixelFormat = pixelFormat
        guard let queue = device.makeCommandQueue() else { throw MetalMapRendererError.creationFailed("queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: MetalShaders.source, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw MetalMapRendererError.creationFailed(name) }
            return f
        }

        /// Opaque, or premultiplied alpha over the target.
        func mainPass(_ vertex: String, _ fragment: String, blending: Bool = true) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try function(vertex)
            d.fragmentFunction = try function(fragment)
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = Self.depthFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = pixelFormat
            c.isBlendingEnabled = blending
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        // Opaque pipelines let the GPU skip fragments that end up covered.
        zonePipeline = try mainPass("fillVertex", "fillFragment", blending: false)
        underlayPipeline = try mainPass("underlayVertex", "fillFragment", blending: false)
        sealPipeline = try mainPass("sealVertex", "sealFragment", blending: false)
        fillPipeline = try mainPass("fillVertex", "fillFragment")
        compositePipeline = try mainPass("screenVertex", "compositeFragment")
        labelPipeline = try mainPass("labelVertex", "labelFragment")

        let coverage = MTLRenderPipelineDescriptor()
        coverage.vertexFunction = try function("coverageVertex")
        coverage.fragmentFunction = try function("coverageFragment")
        for (i, format) in [Self.lineFormat, Self.highlightFormat].enumerated() {
            let c = coverage.colorAttachments[i]!
            c.pixelFormat = format
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .max
            c.alphaBlendOperation = .max
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .one
            c.destinationAlphaBlendFactor = .one
        }
        coveragePipeline = try device.makeRenderPipelineState(descriptor: coverage)

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: d) else {
                throw MetalMapRendererError.creationFailed("depth state")
            }
            return state
        }
        depthAlways = try depthState(.always, write: false)
        depthWrite = try depthState(.less, write: true)
        depthTest = try depthState(.lessEqual, write: false)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: s) else {
            throw MetalMapRendererError.creationFailed("sampler")
        }
        self.sampler = sampler
        labelTextures = LabelTextures(device: device)
    }

    /// Uploads a mesh's geometry.
    public func makeMesh(_ mesh: RenderMesh, kind: MeshKind) throws -> GPUMesh {
        try GPUMesh(device: device, kind: kind, mesh: mesh)
    }

    /// Uploads what a map adds to its mesh.
    public func makeMap(_ map: MyriaMap, mesh: GPUMesh) throws -> GPUMap {
        try GPUMap(device: device, map: map, mesh: mesh)
    }

    /// Called on the main thread when label text that was missing has been
    /// rasterised, so the view can draw again.
    public var labelsDidChange: (@MainActor () -> Void)? {
        get { labelTextures.onReady }
        set { labelTextures.onReady = newValue }
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// Encodes a frame that ends up in `target`, a texture of the
    /// renderer's pixel format; the multisampled image is resolved there.
    /// Without a map, only the page colour is drawn.
    public func encode(_ frame: MapFrame, map gpu: GPUMap?, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        inFlight.wait()
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        let targets = targets(width: target.width, height: target.height)
        let style = frame.style
        let flat = frame.unfold >= 1
        let scale = frame.viewport.scale * frame.contentsScale
        let vp = frame.viewport
        var uniforms = FrameUniforms(
            mapScale: SIMD2(Float(scale), Float(-scale)),
            mapOffset: SIMD2(Float((vp.size.x / 2 - vp.center.x * vp.scale) * frame.contentsScale),
                             Float((vp.size.y / 2 + vp.center.y * vp.scale) * frame.contentsScale)),
            viewportSize: SIMD2(Float(target.width), Float(target.height)),
            depthScale: 0.05,
            folded: flat ? 0 : 1,
            sun: SIMD4(SolarPosition.sunDirection(at: frame.date).simd, flat && frame.showNight ? 1 : 0),
            night: style.night.simd,
            thresholds: SIMD4([0.0, 6, 12, 18].map { Float(-sin($0 * .pi / 180)) }),
            shade: style.surface.mixed(with: RGBA(0, 0, 0), 0.6).simd)

        var transforms: MTLBuffer?
        var colors: MTLBuffer?
        var runs: [Range<Int>] = []
        if let gpu {
            transforms = flat ? gpu.flatTransforms.buffer : foldedTransforms(gpu, unfold: frame.unfold)
            colors = gpu.regionColors(style, device: device)?.buffer
            // The flat map draws only the cells in view; a few points of
            // margin take in lines along the edge.
            let half = vp.size / 2 / vp.scale + Vec2(4, 4) / vp.scale
            let view = Rect2(minX: vp.center.x - half.x, minY: vp.center.y - half.y,
                             maxX: vp.center.x + half.x, maxY: vp.center.y + half.y)
            runs = flat ? gpu.cells.runs(overlapping: view) : gpu.cells.all
        }

        // Lines of one colour each, accumulated as coverage first.
        struct LineLayer {
            let segments: Buffer
            /// The parts in view.
            let spans: [Range<Int>]
            /// Which coverage channel the layer goes to.
            let lines: SIMD4<Float>
            let highlight: SIMD4<Float>
            /// Points.
            let width: Double
        }
        var lineLayers: [LineLayer] = []
        if let gpu, flat {
            func inView(_ segments: Buffer, _ part: KeyPath<MapCells.Cell, Range<Int>>, _ lines: SIMD4<Float>,
                        width: Double) -> LineLayer {
                LineLayer(segments: segments, spans: runs.map { gpu.cells.span($0, part) }, lines: lines, highlight: .zero,
                          width: width)
            }
            if frame.showCoastlines { lineLayers.append(inView(gpu.coastlines, \.coastlines, SIMD4(1, 0, 0, 0), width: 0.5)) }
            if frame.showBorders { lineLayers.append(inView(gpu.borders, \.borders, SIMD4(0, 1, 0, 0), width: 0.9)) }
            if frame.showMesh { lineLayers.append(inView(gpu.faceEdges, \.faceEdges, SIMD4(0, 0, 1, 0), width: 0.3)) }
            if frame.showCuts {
                lineLayers.append(LineLayer(segments: gpu.cuts, spans: [0..<gpu.cuts.count], lines: SIMD4(0, 0, 0, 1),
                                            highlight: .zero, width: 0.6))
            }
            for h in frame.highlights {
                if let outline = gpu.outline(ofGroup: h.group, device: device) {
                    lineLayers.append(LineLayer(segments: outline, spans: [0..<outline.count], lines: .zero,
                                                highlight: SIMD4(1, 0, 0, 0), width: h.width))
                }
            }
            lineLayers.removeAll { $0.segments.buffer == nil }
        }
        if !lineLayers.isEmpty, let transforms {
            let pass = MTLRenderPassDescriptor()
            for (i, texture) in [targets.lines, targets.highlight].enumerated() {
                pass.colorAttachments[i].texture = texture
                pass.colorAttachments[i].loadAction = .clear
                pass.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0)
                pass.colorAttachments[i].storeAction = .store
            }
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "line coverage"
                encoder.setRenderPipelineState(coveragePipeline)
                encoder.setVertexBuffer(transforms, offset: 0, index: 1)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 4)
                for layer in lineLayers {
                    var lineStyle = LineStyleUniforms(lines: layer.lines, highlight: layer.highlight,
                                                      width: Float(layer.width * frame.contentsScale), depthBias: 0)
                    encoder.setVertexBuffer(layer.segments.buffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&lineStyle, length: MemoryLayout<LineStyleUniforms>.stride, index: 5)
                    encoder.setFragmentBytes(&lineStyle, length: MemoryLayout<LineStyleUniforms>.stride, index: 0)
                    for span in layer.spans where !span.isEmpty {
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: span.count,
                                               baseInstance: span.lowerBound)
                    }
                }
                encoder.endEncoding()
            }
        }

        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = targets.color
        color.resolveTexture = target
        color.loadAction = .clear
        color.clearColor = MTLClearColorMake(style.page.r, style.page.g, style.page.b, 1)
        color.storeAction = .multisampleResolve
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "map"
        defer { encoder.endEncoding() }
        guard let gpu, let transforms, let colors else { return }
        let mesh = gpu.mesh

        encoder.setVertexBuffer(transforms, offset: 0, index: 1)
        encoder.setVertexBuffer(mesh.planes.buffer, offset: 0, index: 2)
        encoder.setVertexBuffer(colors, offset: 0, index: 3)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 4)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)

        func fill(_ corners: Buffer, _ triangles: Buffer, _ part: KeyPath<MapCells.Cell, Range<Int>>,
                  _ fillStyle: FillStyleUniforms, depth: MTLDepthStencilState, pipeline: MTLRenderPipelineState? = nil) {
            guard let vertices = corners.buffer, let indices = triangles.buffer else { return }
            var fillStyle = fillStyle
            encoder.setRenderPipelineState(pipeline ?? (fillStyle.useRegion == 1 ? zonePipeline : fillPipeline))
            encoder.setDepthStencilState(depth)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&fillStyle, length: MemoryLayout<FillStyleUniforms>.stride, index: 5)
            for run in runs {
                let span = gpu.cells.span(run, part)
                guard !span.isEmpty else { continue }
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: span.count, indexType: .uint32, indexBuffer: indices,
                                              indexBufferOffset: span.lowerBound * MemoryLayout<UInt32>.stride)
            }
        }

        // A hairline in the fill colour seals the slits that open between
        // rows inside a zone. On the flat map only cut edges part, and the
        // hairlines go underneath the fills, so they show in the slits only
        // and never on a neighbouring zone. While folding, every outline
        // also hides the seams between faces.
        func seal(_ segments: Buffer, _ spans: [Range<Int>]) {
            guard let buffer = segments.buffer else { return }
            var lineStyle = LineStyleUniforms(width: Float((flat ? 0.7 : 0.6) * frame.contentsScale),
                                              depthBias: flat ? 0 : 8e-6)
            encoder.setRenderPipelineState(sealPipeline)
            encoder.setDepthStencilState(flat ? depthAlways : depthTest)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&lineStyle, length: MemoryLayout<LineStyleUniforms>.stride, index: 5)
            for span in spans where !span.isEmpty {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: span.count,
                                       baseInstance: span.lowerBound)
            }
        }
        // Every face in its main zone's colour, under the fills: where
        // neighbouring triangles leave a hairline crack between them, it
        // shows that colour rather than the page. On the flat map its corners
        // are shared exactly, so it has no cracks of its own.
        encoder.setVertexBuffer(gpu.flatFaceCorners.buffer ?? mesh.faceCorners.buffer, offset: 0, index: 6)
        fill(mesh.faceCorners, gpu.faceIndices, \.faces, FillStyleUniforms(color: .zero, depthBias: 0, useRegion: 1),
             depth: flat ? depthAlways : depthWrite, pipeline: underlayPipeline)
        if flat { seal(gpu.seals, runs.map { gpu.cells.span($0, \.seals) }) }
        fill(mesh.zoneVertices, gpu.zoneIndices, \.zones, FillStyleUniforms(color: .zero, depthBias: 0, useRegion: 1),
             depth: depthWrite)
        if !flat { seal(mesh.zoneOutlines, [0..<mesh.zoneOutlines.count]) }
        if frame.showLand {
            fill(mesh.landVertices, gpu.landIndices, \.land,
                 FillStyleUniforms(color: style.land.simd, depthBias: flat ? 0 : 4e-6, useRegion: 0),
                 depth: flat ? depthAlways : depthTest)
        }

        guard flat else { return }
        encoder.setDepthStencilState(depthAlways)
        if !lineLayers.isEmpty {
            var palette = LineColors(coastline: style.coastline.simd, border: style.border.simd, mesh: style.mesh.simd,
                                     cut: style.cut.simd, highlight: style.highlight.simd)
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(targets.lines, index: 0)
            encoder.setFragmentTexture(targets.highlight, index: 1)
            encoder.setFragmentBytes(&palette, length: MemoryLayout<LineColors>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if !frame.labels.isEmpty {
            encoder.setRenderPipelineState(labelPipeline)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            for (quad, texture) in labelTextures.quads(for: frame) {
                var quad = quad
                encoder.setVertexBytes(&quad, length: MemoryLayout<LabelQuad>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
    }

    /// Writes the folded transforms into the next buffer of the ring.
    private func foldedTransforms(_ gpu: GPUMap, unfold: Double) -> MTLBuffer? {
        let length = (gpu.mesh.faceCount + 1) * MemoryLayout<FaceTransform>.stride
        ringIndex = (ringIndex + 1) % transformRing.count
        if (transformRing[ringIndex]?.length ?? 0) < length {
            transformRing[ringIndex] = device.makeBuffer(length: length, options: .storageModeShared)
            transformRing[ringIndex]?.label = "folded transforms"
        }
        guard let buffer = transformRing[ringIndex] else { return nil }
        gpu.map.writeFoldedFaceTransforms(unfold: unfold, folding: gpu.foldingGeometry(), poses: &gpu.poses,
                                          into: buffer.contents().assumingMemoryBound(to: FaceTransform.self))
        return buffer
    }

    private struct Targets {
        let width: Int
        let height: Int
        let color: MTLTexture
        let depth: MTLTexture
        let lines: MTLTexture
        let highlight: MTLTexture
    }

    private func targets(width: Int, height: Int) -> Targets {
        if let targets, targets.width == width, targets.height == height { return targets }
        // On Apple GPUs the multisampled image and depth live in tile memory.
        let memoryless = device.supportsFamily(.apple1)
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, transient: Bool) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = transient && memoryless ? .memoryless : .private
            return device.makeTexture(descriptor: d)!
        }
        let made = Targets(
            width: width, height: height,
            color: texture(pixelFormat, samples: Self.sampleCount, usage: .renderTarget, transient: true),
            depth: texture(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget, transient: true),
            lines: texture(Self.lineFormat, samples: 1, usage: [.renderTarget, .shaderRead], transient: false),
            highlight: texture(Self.highlightFormat, samples: 1, usage: [.renderTarget, .shaderRead], transient: false))
        targets = made
        return made
    }

    /// Renders a frame offscreen (tests, previews). Labels are rasterised
    /// on the spot.
    public func image(_ frame: MapFrame, map: GPUMap?, width: Int, height: Int) throws -> CGImage {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d), let commandBuffer = queue.makeCommandBuffer() else {
            throw MetalMapRendererError.creationFailed("offscreen target")
        }
        labelTextures.prepare(for: frame)
        encode(frame, map: map, into: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let bitmapInfo: UInt32 = pixelFormat == .bgra8Unorm
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo),
              let image = context.makeImage()
        else { throw MetalMapRendererError.creationFailed("image") }
        return image
    }
}

// MARK: - Shader mirrors

// Sizes must match the structs in `MetalShaders`.
private let shaderLayoutChecks: Void = {
    precondition(MemoryLayout<FillVertex>.stride == 16 && MemoryLayout<LineSegment>.stride == 24)
    precondition(MemoryLayout<FaceTransform>.stride == 48 && MemoryLayout<FacePlane>.stride == 48)
    precondition(MemoryLayout<RegionStyle>.stride == 32 && MemoryLayout<FrameUniforms>.stride == 96)
    precondition(MemoryLayout<FillStyleUniforms>.stride == 32 && MemoryLayout<LineStyleUniforms>.stride == 48)
    precondition(MemoryLayout<LineColors>.stride == 80 && MemoryLayout<LabelQuad>.stride == 32)
}()

struct FrameUniforms {
    var mapScale: SIMD2<Float>
    var mapOffset: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    var depthScale: Float
    var folded: Float
    var sun: SIMD4<Float>
    var night: SIMD4<Float>
    var thresholds: SIMD4<Float>
    var shade: SIMD4<Float>
}

struct FillStyleUniforms {
    var color: SIMD4<Float>
    var depthBias: Float
    var useRegion: UInt32
    var pad = SIMD2<Float>.zero
}

struct LineStyleUniforms {
    var lines: SIMD4<Float> = .zero
    var highlight: SIMD4<Float> = .zero
    var width: Float
    var depthBias: Float
    var pad = SIMD2<Float>.zero
}

struct RegionStyle {
    var color: SIMD4<Float>
    var depth: Float
    var pad: (Float, Float, Float) = (0, 0, 0)
}

struct LineColors {
    var coastline: SIMD4<Float>
    var border: SIMD4<Float>
    var mesh: SIMD4<Float>
    var cut: SIMD4<Float>
    var highlight: SIMD4<Float>
}

struct LabelQuad {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

extension RGBA {
    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }
}

extension Vec3 {
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
}
#endif
