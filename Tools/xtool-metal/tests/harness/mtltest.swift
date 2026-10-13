// Loads a metallib, reports its functions, and runs test cases described in JSON, writing raw outputs.
// Usage:
//   mtltest info <lib.metallib>
//   mtltest run <lib.metallib> <case.json> <out.bin>
import Foundation
import Metal
#if canImport(SwiftUI)
import SwiftUI
#endif

struct BufferSpec: Codable {
    var index: Int
    var floats: [Float]?
    var uints: [UInt32]?
    var ints: [Int32]?
    var halfs: [Float]?
    var bytes: Int?          // zero-filled buffer of this size
    var output: Bool?        // compute: read back after dispatch
}
struct TextureSpec: Codable {
    var index: Int
    var width: Int
    var height: Int
    var format: String       // rgba8Unorm | rgba16Float | rgba32Float | r32Float
    var pattern: String      // gradient | checker | noise
    var output: Bool?        // compute: written by kernel, read back
}
struct SamplerSpec: Codable {
    var index: Int
    var filter: String?
    var address: String?
}
struct Case: Codable {
    var kind: String         // render | compute | visible
    var vertex: String?
    var fragment: String?
    var kernel: String?
    var function: String?    // visible: stitchable function used as SwiftUI colorEffect
    var width: Int?
    var height: Int?
    var pixelFormat: String?
    var vertexCount: Int?
    var instanceCount: Int?
    var primitive: String?   // triangle | point | triangleStrip | line
    var vertexBuffers: [BufferSpec]?
    var fragmentBuffers: [BufferSpec]?
    var fragmentTextures: [TextureSpec]?
    var vertexTextures: [TextureSpec]?
    var fragmentSamplers: [SamplerSpec]?
    var buffers: [BufferSpec]?
    var textures: [TextureSpec]?
    var samplers: [SamplerSpec]?
    var threadgroupMemory: [Int]?
    var grid: [Int]?
    var threadgroup: [Int]?
    var constants: [String: Float]?
    var args: [Float]?       // visible: float arguments after the implicit position/color
    var effect: String?      // visible: color (default) | layer | distortion
    var noBounds: Bool?      // visible: do not pass the bounds float4 first
}

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

guard let dev = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
let queue = dev.makeCommandQueue()!

func loadLib(_ path: String) -> MTLLibrary {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let dd = data.withUnsafeBytes { DispatchData(bytes: $0) }
    do { return try dev.makeLibrary(data: dd as __DispatchData) } catch { fail("makeLibrary failed: \(error)") }
}

func pixelFormat(_ s: String) -> MTLPixelFormat {
    switch s {
    case "rgba8Unorm": return .rgba8Unorm
    case "bgra8Unorm": return .bgra8Unorm
    case "rgba16Float": return .rgba16Float
    case "rgba32Float": return .rgba32Float
    case "r32Float": return .r32Float
    case "r32Uint": return .r32Uint
    case "rgba32Uint": return .rgba32Uint
    case "rgba32Sint": return .rgba32Sint
    default: fail("unknown pixel format \(s)")
    }
}
func bytesPerPixel(_ f: MTLPixelFormat) -> Int {
    switch f {
    case .rgba8Unorm, .bgra8Unorm, .r32Float, .r32Uint: return 4
    case .rgba16Float: return 8
    case .rgba32Float, .rgba32Uint, .rgba32Sint: return 16
    default: return 4
    }
}

func makeBuffer(_ b: BufferSpec) -> MTLBuffer {
    var data = Data()
    if let f = b.floats { f.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
    if let u = b.uints { u.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
    if let i = b.ints { i.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
    if let h = b.halfs { let hs = h.map { Float16($0) }; hs.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
    if let n = b.bytes { data.append(Data(count: n)) }
    if data.isEmpty { data = Data(count: 16) }
    return data.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: data.count, options: .storageModeShared)! }
}

func makeTexture(_ t: TextureSpec, usage: MTLTextureUsage) -> MTLTexture {
    let fmt = pixelFormat(t.format)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: t.width, height: t.height, mipmapped: false)
    d.usage = usage
    d.storageMode = .shared
    let tex = dev.makeTexture(descriptor: d)!
    var rgba = [Float](repeating: 0, count: t.width * t.height * 4)
    var seed: UInt32 = 12345
    for y in 0..<t.height {
        for x in 0..<t.width {
            let i = (y * t.width + x) * 4
            switch t.pattern {
            case "checker":
                let c: Float = ((x / 4 + y / 4) % 2 == 0) ? 1 : 0.1
                rgba[i] = c; rgba[i + 1] = 1 - c; rgba[i + 2] = 0.5; rgba[i + 3] = ((x + y) % 3 == 0) ? 0.5 : 1
            case "noise":
                for k in 0..<4 { seed = seed &* 1664525 &+ 1013904223; rgba[i + k] = Float(seed >> 8) / Float(1 << 24) }
            default:
                rgba[i] = Float(x) / Float(max(t.width - 1, 1)); rgba[i + 1] = Float(y) / Float(max(t.height - 1, 1))
                rgba[i + 2] = 0.25; rgba[i + 3] = 0.5 + 0.5 * Float(x) / Float(max(t.width - 1, 1))
            }
        }
    }
    let region = MTLRegionMake2D(0, 0, t.width, t.height)
    switch fmt {
    case .rgba8Unorm:
        let px = rgba.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        tex.replace(region: region, mipmapLevel: 0, withBytes: px, bytesPerRow: t.width * 4)
    case .rgba16Float:
        let px = rgba.map { Float16($0) }
        tex.replace(region: region, mipmapLevel: 0, withBytes: px, bytesPerRow: t.width * 8)
    case .rgba32Float:
        tex.replace(region: region, mipmapLevel: 0, withBytes: rgba, bytesPerRow: t.width * 16)
    case .r32Float:
        let px = stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }
        tex.replace(region: region, mipmapLevel: 0, withBytes: px, bytesPerRow: t.width * 4)
    default:
        let px = [UInt8](repeating: 0, count: t.width * t.height * bytesPerPixel(fmt))
        tex.replace(region: region, mipmapLevel: 0, withBytes: px, bytesPerRow: t.width * bytesPerPixel(fmt))
    }
    return tex
}

func makeSampler(_ s: SamplerSpec) -> MTLSamplerState {
    let d = MTLSamplerDescriptor()
    let f: MTLSamplerMinMagFilter = (s.filter == "nearest") ? .nearest : .linear
    d.minFilter = f; d.magFilter = f
    let a: MTLSamplerAddressMode = (s.address == "repeat") ? .repeat : .clampToEdge
    d.sAddressMode = a; d.tAddressMode = a
    return dev.makeSamplerState(descriptor: d)!
}

func readTexture(_ tex: MTLTexture) -> Data {
    let bpp = bytesPerPixel(tex.pixelFormat)
    var out = Data(count: tex.width * tex.height * bpp)
    out.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: tex.width * bpp, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0) }
    return out
}

func function(_ lib: MTLLibrary, _ name: String, _ consts: [String: Float]?) -> MTLFunction {
    if let consts = consts, !consts.isEmpty {
        let cv = MTLFunctionConstantValues()
        for (k, v) in consts {
            var f = v
            if k.hasPrefix("b:") { var b: Bool = v != 0; cv.setConstantValue(&b, type: .bool, withName: String(k.dropFirst(2))) }
            else if k.hasPrefix("i:") { var i = Int32(v); cv.setConstantValue(&i, type: .int, withName: String(k.dropFirst(2))) }
            else { cv.setConstantValue(&f, type: .float, withName: k) }
        }
        do { return try lib.makeFunction(name: name, constantValues: cv) } catch { fail("makeFunction(\(name)) with constants: \(error)") }
    }
    guard let f = lib.makeFunction(name: name) else { fail("no function \(name)") }
    return f
}

func runRender(_ lib: MTLLibrary, _ c: Case) -> Data {
    let w = c.width ?? 64, h = c.height ?? 64
    let fmt = pixelFormat(c.pixelFormat ?? "rgba32Float")
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = function(lib, c.vertex!, c.constants)
    pd.fragmentFunction = function(lib, c.fragment!, c.constants)
    pd.colorAttachments[0].pixelFormat = fmt
    let ps: MTLRenderPipelineState
    do { ps = try dev.makeRenderPipelineState(descriptor: pd) } catch { fail("render pipeline: \(error)") }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let target = dev.makeTexture(descriptor: td)!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
    rp.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setRenderPipelineState(ps)
    for b in c.vertexBuffers ?? [] { enc.setVertexBuffer(makeBuffer(b), offset: 0, index: b.index) }
    for b in c.fragmentBuffers ?? [] { enc.setFragmentBuffer(makeBuffer(b), offset: 0, index: b.index) }
    for t in c.fragmentTextures ?? [] { enc.setFragmentTexture(makeTexture(t, usage: .shaderRead), index: t.index) }
    for t in c.vertexTextures ?? [] { enc.setVertexTexture(makeTexture(t, usage: .shaderRead), index: t.index) }
    for s in c.fragmentSamplers ?? [] { enc.setFragmentSamplerState(makeSampler(s), index: s.index) }
    let prim: MTLPrimitiveType
    switch c.primitive ?? "triangle" {
    case "point": prim = .point
    case "line": prim = .line
    case "triangleStrip": prim = .triangleStrip
    default: prim = .triangle
    }
    enc.drawPrimitives(type: prim, vertexStart: 0, vertexCount: c.vertexCount ?? 3, instanceCount: c.instanceCount ?? 1)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    if let e = cb.error { fail("command buffer: \(e)") }
    return readTexture(target)
}

func runCompute(_ lib: MTLLibrary, _ c: Case) -> Data {
    let fn = function(lib, c.kernel!, c.constants)
    let ps: MTLComputePipelineState
    do { ps = try dev.makeComputePipelineState(function: fn) } catch { fail("compute pipeline: \(error)") }
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    var outs: [MTLBuffer] = []
    var outTex: [MTLTexture] = []
    for b in c.buffers ?? [] { let mb = makeBuffer(b); enc.setBuffer(mb, offset: 0, index: b.index); if b.output == true { outs.append(mb) } }
    for t in c.textures ?? [] {
        let tex = makeTexture(t, usage: t.output == true ? [.shaderWrite, .shaderRead] : .shaderRead)
        enc.setTexture(tex, index: t.index); if t.output == true { outTex.append(tex) }
    }
    for s in c.samplers ?? [] { enc.setSamplerState(makeSampler(s), index: s.index) }
    for (i, n) in (c.threadgroupMemory ?? []).enumerated() { enc.setThreadgroupMemoryLength(n, index: i) }
    let g = c.grid ?? [64, 1, 1], t = c.threadgroup ?? [64, 1, 1]
    enc.dispatchThreads(MTLSize(width: g[0], height: g[1], depth: g[2]), threadsPerThreadgroup: MTLSize(width: t[0], height: t[1], depth: t[2]))
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    if let e = cb.error { fail("command buffer: \(e)") }
    var out = Data()
    for b in outs { out.append(Data(bytes: b.contents(), count: b.length)) }
    for t in outTex { out.append(readTexture(t)) }
    return out
}

#if canImport(SwiftUI)
@available(macOS 14.0, *)
@MainActor
func runVisible(_ path: String, _ c: Case) -> Data {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let lib = ShaderLibrary(data: data)
    let w = c.width ?? 64, h = c.height ?? 64
    var sargs: [Shader.Argument] = c.noBounds == true ? [] : [.float4(0, 0, Float(w), Float(h))]
    for a in c.args ?? [] { sargs.append(.float(a)) }
    let shader = Shader(function: ShaderFunction(library: lib, name: c.function!), arguments: sargs)
    let base = LinearGradient(colors: [.red, .yellow, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(width: CGFloat(w), height: CGFloat(h))
    let view: AnyView
    switch c.effect ?? "color" {
    case "layer": view = AnyView(base.layerEffect(shader, maxSampleOffset: CGSize(width: 16, height: 16)))
    case "distortion": view = AnyView(base.distortionEffect(shader, maxSampleOffset: CGSize(width: 16, height: 16)))
    default: view = AnyView(Rectangle().fill(Color(red: 0.2, green: 0.4, blue: 0.6)).frame(width: CGFloat(w), height: CGFloat(h)).colorEffect(shader))
    }
    let r = ImageRenderer(content: view)
    r.scale = 1
    guard let cg = r.cgImage else { fail("ImageRenderer produced no image") }
    let bpr = w * 4
    var px = [UInt8](repeating: 0, count: bpr * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Data(px)
}
#endif

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: mtltest info <lib> | run <lib> <case.json> <out.bin>") }
switch args[1] {
case "info":
    let lib = loadLib(args[2])
    for name in lib.functionNames.sorted() {
        let f = lib.makeFunction(name: name)!
        var line = "\(name) type=\(f.functionType.rawValue)"
        if let va = f.vertexAttributes, !va.isEmpty { line += " vattrs=" + va.map { "\($0.name)@\($0.attributeIndex):\($0.attributeType.rawValue)" }.joined(separator: ",") }
        let fc = f.functionConstantsDictionary
        if !fc.isEmpty { line += " constants=" + fc.values.map { "\($0.name)@\($0.index):\($0.type.rawValue)\($0.required ? "!" : "")" }.sorted().joined(separator: ",") }
        print(line)
    }
case "run":
    let c = try! JSONDecoder().decode(Case.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
    let out: Data
    switch c.kind {
    case "render": out = runRender(loadLib(args[2]), c)
    case "compute": out = runCompute(loadLib(args[2]), c)
    #if canImport(SwiftUI)
    case "visible":
        if #available(macOS 14.0, *) { out = MainActor.assumeIsolated { runVisible(args[2], c) } } else { fail("needs macOS 14") }
    #endif
    default: fail("unknown kind \(c.kind)")
    }
    try! out.write(to: URL(fileURLWithPath: args[4]))
    print("wrote \(out.count) bytes")
default:
    fail("unknown command")
}
