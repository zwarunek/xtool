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


// MARK: - Automatic differential test of compute kernels

struct AutoResult { var name: String; var status: String; var detail: String }

func autoInputs(seed: UInt32) -> (UInt32) -> Float {
    var state = seed
    return { _ in state = state &* 1664525 &+ 1013904223; return Float(state >> 8) / Float(1 << 24) }
}

// Byte kinds: 1 float, 2 half, 3 int32, 4 int16, 5 int8/bool, 6 zero (pointers, 64-bit ints).
func kindOf(_ t: MTLDataType) -> UInt8 {
    switch t.rawValue {
    case 3...15: return 1
    case 16...28: return 2
    case 29...36: return 3
    case 37...44: return 4
    case 45...56: return 5
    default: return t == .pointer || (81...88).contains(t.rawValue) ? 6 : 1
    }
}

func markKinds(_ kinds: inout [UInt8], _ base: Int, _ t: MTLDataType, _ st: MTLStructType?, _ at: MTLArrayType?) {
    if let st = st {
        for m in st.members { markKinds(&kinds, base + m.offset, m.dataType, m.structType(), m.arrayType()) }
    } else if let at = at {
        for i in 0..<at.arrayLength { markKinds(&kinds, base + i * at.stride, at.elementType, at.elementStructType(), at.element()) }
    } else if t != .struct && t != .array {
        let k = kindOf(t)
        let n = k == 6 ? 8 : 4
        for j in 0..<n where base + j < kinds.count { kinds[base + j] = k }
    }
}

// Functions with function constants must be specialized before building a pipeline; optional constants take their defaults.
// Required constants get generated values (true, 1, 0.5), the same for both libraries.
func autoFunction(_ lib: MTLLibrary, _ name: String) throws -> MTLFunction? {
    guard let f = lib.makeFunction(name: name) else { return nil }
    if f.functionConstantsDictionary.isEmpty { return f }
    let values = MTLFunctionConstantValues()
    for (cname, c) in f.functionConstantsDictionary where c.required {
        var bytes = [UInt8](repeating: 0, count: 64)
        let k = kindOf(c.type)
        let one16 = Float16(0.5).bitPattern
        for e in 0..<16 {
            switch k {
            case 1: withUnsafeBytes(of: Float(0.5)) { for j in 0..<4 { bytes[e * 4 + j] = $0[j] } }
            case 2: bytes[e * 2] = UInt8(one16 & 0xff); bytes[e * 2 + 1] = UInt8(one16 >> 8)
            case 3: bytes[e * 4] = 1
            case 4: bytes[e * 2] = 1
            case 5: bytes[e] = 1
            default: break
            }
        }
        bytes.withUnsafeBytes { values.setConstantValue($0.baseAddress!, type: c.type, withName: cname) }
    }
    return try lib.makeFunction(name: name, constantValues: values)
}

var pipelineCache: [String: (MTLComputePipelineState, MTLComputePipelineReflection?)] = [:]

func autoPipeline(_ lib: MTLLibrary, _ name: String) throws -> (MTLComputePipelineState, MTLComputePipelineReflection?) {
    let key = "\(ObjectIdentifier(lib).hashValue)/\(name)"
    if let c = pipelineCache[key] { return c }
    guard let f = try autoFunction(lib, name) else { throw NSError(domain: "auto", code: 1, userInfo: [NSLocalizedDescriptionKey: "no function"]) }
    var refl: MTLComputePipelineReflection?
    let ps = try dev.makeComputePipelineState(function: f, options: [.bindingInfo, .bufferTypeInfo], reflection: &refl)
    pipelineCache[key] = (ps, refl)
    return (ps, refl)
}

struct AutoBinder {
    var buffer: (MTLBuffer, Int) -> Void
    var texture: (MTLTexture, Int) -> Void
    var sampler: (MTLSamplerState, Int) -> Void
    var threadgroup: (Int, Int) -> Void = { _, _ in }
}

// Creates generated inputs for every used binding; writable buffers and 2D textures are collected as outputs.
func autoBind(_ bindings: [MTLBinding], seed: UInt32, _ bd: AutoBinder, _ outputs: inout [MTLBuffer], _ outTextures: inout [MTLTexture]) -> Bool {
    // Each binding gets its own stream so inputs don't depend on reflection order.
    for b in bindings.sorted(by: { ($0.type.rawValue, $0.index) < ($1.type.rawValue, $1.index) }) where b.isUsed {
        let rnd = autoInputs(seed: seed &+ UInt32(b.type.rawValue) &* 1000 &+ UInt32(b.index))
        switch b.type {
        case .buffer:
            let bb = b as! MTLBufferBinding
            let elem = max(bb.bufferDataSize, 4)
            let size = max(elem * 4096, 65536)
            // Fill by reflected element layout: floats in [0,1), small integers in integer fields, zero pointers.
            var kinds = [UInt8](repeating: 1, count: elem)
            markKinds(&kinds, 0, bb.bufferDataType, bb.bufferStructType, bb.bufferPointerType?.elementArrayType())
            var bytes = [UInt8](repeating: 0, count: size)
            var o = 0
            while o + 4 <= size {
                let k = kinds[o % elem]
                let r = rnd(UInt32(o))
                switch k {
                case 2: withUnsafeBytes(of: Float16(r)) { bytes[o] = $0[0]; bytes[o + 1] = $0[1] }
                        withUnsafeBytes(of: Float16(rnd(UInt32(o)))) { bytes[o + 2] = $0[0]; bytes[o + 3] = $0[1] }
                case 3: withUnsafeBytes(of: UInt32(r * 8)) { for j in 0..<4 { bytes[o + j] = $0[j] } }
                case 4: withUnsafeBytes(of: UInt16(r * 8)) { bytes[o] = $0[0]; bytes[o + 1] = $0[1] }
                        withUnsafeBytes(of: UInt16(rnd(UInt32(o)) * 8)) { bytes[o + 2] = $0[0]; bytes[o + 3] = $0[1] }
                case 5: for j in 0..<4 { bytes[o + j] = UInt8(rnd(UInt32(o + j)) * 2) }
                case 6: break
                default: withUnsafeBytes(of: r) { for j in 0..<4 { bytes[o + j] = $0[j] } }
                }
                o += 4
            }
            let buf = bytes.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: size, options: .storageModeShared)! }
            bd.buffer(buf, bb.index)
            if bb.access != .readOnly { outputs.append(buf) }
            if ProcessInfo.processInfo.environment["AUTO_DEBUG"] != nil { FileHandle.standardError.write("buffer \(bb.index) \(bb.name) access=\(bb.access.rawValue) size=\(bb.bufferDataSize)\n".data(using: .utf8)!) }
        case .texture:
            let tb = b as! MTLTextureBinding
            let fmt: MTLPixelFormat
            switch tb.textureDataType {
            case .half: fmt = .rgba16Float
            case .int: fmt = .rgba32Sint
            case .uint: fmt = .rgba32Uint
            default: fmt = .rgba32Float
            }
            let d = MTLTextureDescriptor()
            d.textureType = tb.textureType
            d.pixelFormat = tb.isDepthTexture ? .depth32Float : fmt
            d.width = 64; d.height = (tb.textureType == .type1D || tb.textureType == .typeTextureBuffer) ? 1 : 64
            if tb.textureType == .type3D { d.depth = 8 }
            if tb.textureType == .type2DArray || tb.textureType == .typeCubeArray { d.arrayLength = 2 }
            if tb.textureType == .typeCube || tb.textureType == .typeCubeArray { d.height = 64 }
            if tb.textureType == .type2DMultisample { d.sampleCount = 4; d.storageMode = .private } else { d.storageMode = .shared }
            d.usage = [.shaderRead, .shaderWrite]
            guard let tex = dev.makeTexture(descriptor: d) else { return false }
            if d.storageMode == .shared && !tb.isDepthTexture {
                let bpp = fmt == .rgba16Float ? 8 : 16
                let slices = tb.textureType == .typeCube ? 6 : (tb.textureType == .typeCubeArray ? 12 : d.arrayLength)
                var bytes = [UInt8](repeating: 0, count: d.width * d.height * bpp)
                for z in 0..<max(d.depth, 1) {
                    for sl in 0..<slices {
                        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: Int(rnd(UInt32(i)) * 255)) }
                        if fmt == .rgba32Float || fmt == .rgba16Float {
                            // keep floats finite: small positive values
                            if fmt == .rgba32Float {
                                var fl = [Float](repeating: 0, count: d.width * d.height * 4)
                                for i in 0..<fl.count { fl[i] = rnd(UInt32(i)) }
                                fl.withUnsafeBytes { bytes = Array($0) }
                            } else {
                                var hl = [Float16](repeating: 0, count: d.width * d.height * 4)
                                for i in 0..<hl.count { hl[i] = Float16(rnd(UInt32(i))) }
                                hl.withUnsafeBytes { bytes = Array($0) }
                            }
                        }
                        tex.replace(region: MTLRegionMake3D(0, 0, z, d.width, d.height, 1), mipmapLevel: 0, slice: sl, withBytes: bytes,
                                    bytesPerRow: d.width * bpp, bytesPerImage: d.width * d.height * bpp)
                    }
                }
            }
            bd.texture(tex, tb.index)
            if tb.access != .readOnly && d.storageMode == .shared && !tb.isDepthTexture && tb.textureType == .type2D { outTextures.append(tex) }
        case .sampler:
            bd.sampler(makeSampler(SamplerSpec(index: b.index, filter: "linear", address: "clamp")), b.index)
        case .threadgroupMemory:
            let tg = b as! MTLThreadgroupBinding
            bd.threadgroup(max((tg.threadgroupMemoryDataSize + 15) / 16 * 16, 16), tg.index)
        default:
            return false
        }
    }
    return true
}

func runKernelAuto(_ lib: MTLLibrary, _ name: String, seed: UInt32) throws -> Data? {
    let (ps, refl) = try autoPipeline(lib, name)
    guard let bindings = refl?.bindings else { return nil }
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    var outputs: [MTLBuffer] = []
    var outTextures: [MTLTexture] = []
    let bd = AutoBinder(buffer: { enc.setBuffer($0, offset: 0, index: $1) }, texture: { enc.setTexture($0, index: $1) },
                        sampler: { enc.setSamplerState($0, index: $1) }, threadgroup: { enc.setThreadgroupMemoryLength($0, index: $1) })
    guard autoBind(bindings, seed: seed, bd, &outputs, &outTextures) else { enc.endEncoding(); return nil }
    let w = min(ps.threadExecutionWidth, 32)
    let h = max(min(ps.maxTotalThreadsPerThreadgroup / w, 8), 1)
    enc.dispatchThreads(MTLSize(width: 64, height: 64, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    if let e = cb.error { throw e }
    var out = Data()
    for b in outputs { out.append(Data(bytes: b.contents(), count: b.length)) }
    for t in outTextures { out.append(readTexture(t)) }
    return out
}

func bindingSignature(_ lib: MTLLibrary, _ name: String) throws -> [String] {
    guard lib.functionNames.contains(name) else { return ["missing"] }
    let (_, refl) = try autoPipeline(lib, name)
    return (refl?.bindings ?? []).map { b -> String in
        var d = "\(b.name):\(b.type.rawValue):\(b.index):\(b.access.rawValue):\(b.isUsed)"
        if let bb = b as? MTLBufferBinding { d += ":\(bb.bufferDataSize):\(bb.bufferAlignment):\(bb.bufferDataType.rawValue)" }
        if let tb = b as? MTLTextureBinding { d += ":\(tb.textureType.rawValue):\(tb.textureDataType.rawValue)" }
        if let tg = b as? MTLThreadgroupBinding { d += ":\(tg.threadgroupMemoryDataSize)" }
        return d
    }.sorted()
}

// MARK: - Automatic differential test of vertex + fragment pairs

func vertexFormat(_ t: MTLDataType) -> (MTLVertexFormat, Int)? {
    switch t {
    case .float: return (.float, 4)
    case .float2: return (.float2, 8)
    case .float3: return (.float3, 12)
    case .float4: return (.float4, 16)
    case .half: return (.half, 2)
    case .half2: return (.half2, 4)
    case .half3: return (.half3, 6)
    case .half4: return (.half4, 8)
    case .int: return (.int, 4)
    case .int2: return (.int2, 8)
    case .int3: return (.int3, 12)
    case .int4: return (.int4, 16)
    case .uint: return (.uint, 4)
    case .uint2: return (.uint2, 8)
    case .uint3: return (.uint3, 12)
    case .uint4: return (.uint4, 16)
    case .uchar4: return (.uchar4, 4)
    case .ushort2: return (.ushort2, 4)
    case .short2: return (.short2, 4)
    default: return nil
    }
}

let autoVertexBufferIndex = 30
let autoTargetFormats: [MTLPixelFormat] = [.rgba32Float, .rgba32Uint, .rgba32Sint]

// Pipeline for a vertex/fragment pair: generated vertex descriptor for [[stage_in]], color 0 in the first format that works.
var renderCache: [String: Result<(MTLRenderPipelineState, MTLRenderPipelineReflection?, MTLPixelFormat, Int), Error>] = [:]

func autoRenderPipeline(_ lib: MTLLibrary, _ v: String, _ f: String) throws -> (MTLRenderPipelineState, MTLRenderPipelineReflection?, MTLPixelFormat, Int) {
    let key = "\(ObjectIdentifier(lib).hashValue)/\(v)/\(f)"
    if let c = renderCache[key] { return try c.get() }
    let r = Result { try makeAutoRenderPipeline(lib, v, f) }
    renderCache[key] = r
    return try r.get()
}

func makeAutoRenderPipeline(_ lib: MTLLibrary, _ v: String, _ f: String) throws -> (MTLRenderPipelineState, MTLRenderPipelineReflection?, MTLPixelFormat, Int) {
    guard let vf = try autoFunction(lib, v), let ff = try autoFunction(lib, f) else { throw NSError(domain: "auto", code: 1, userInfo: [NSLocalizedDescriptionKey: "no function"]) }
    var stride = 0
    var vd: MTLVertexDescriptor?
    if let attrs = vf.vertexAttributes, !attrs.isEmpty {
        let d = MTLVertexDescriptor()
        for a in attrs where a.isActive {
            guard let (fmt, size) = vertexFormat(a.attributeType) else { throw NSError(domain: "auto", code: 2, userInfo: [NSLocalizedDescriptionKey: "vertex attribute type \(a.attributeType.rawValue)"]) }
            d.attributes[a.attributeIndex].format = fmt
            d.attributes[a.attributeIndex].offset = stride
            d.attributes[a.attributeIndex].bufferIndex = autoVertexBufferIndex
            stride += (size + 3) / 4 * 4
        }
        d.layouts[autoVertexBufferIndex].stride = max(stride, 4)
        vd = d
    }
    var lastError: Error?
    for fmt in autoTargetFormats {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = fmt
        var refl: MTLRenderPipelineReflection?
        do {
            let ps = try dev.makeRenderPipelineState(descriptor: pd, options: [.bindingInfo, .bufferTypeInfo], reflection: &refl)
            return (ps, refl, fmt, stride)
        } catch { lastError = error }
    }
    throw lastError!
}

func runRenderAuto(_ lib: MTLLibrary, _ v: String, _ f: String, seed: UInt32) throws -> Data? {
    let (ps, refl, fmt, stride) = try autoRenderPipeline(lib, v, f)
    guard let refl = refl else { return nil }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: 64, height: 64, mipmapped: false)
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
    var outputs: [MTLBuffer] = []
    var outTextures: [MTLTexture] = []
    let vb = AutoBinder(buffer: { enc.setVertexBuffer($0, offset: 0, index: $1) }, texture: { enc.setVertexTexture($0, index: $1) },
                        sampler: { enc.setVertexSamplerState($0, index: $1) })
    let fb = AutoBinder(buffer: { enc.setFragmentBuffer($0, offset: 0, index: $1) }, texture: { enc.setFragmentTexture($0, index: $1) },
                        sampler: { enc.setFragmentSamplerState($0, index: $1) })
    guard autoBind(refl.vertexBindings, seed: seed, vb, &outputs, &outTextures),
          autoBind(refl.fragmentBindings, seed: seed &+ 50000, fb, &outputs, &outTextures) else { enc.endEncoding(); return nil }
    let vertexCount = 12
    if stride > 0 {
        let rnd = autoInputs(seed: seed &+ 99)
        var fl = [Float](repeating: 0, count: stride / 4 * vertexCount)
        // Positions spread over clip space so the triangles cover part of the target.
        for i in 0..<fl.count { fl[i] = rnd(UInt32(i)) * 2 - 1 }
        enc.setVertexBytes(fl, length: fl.count * 4, index: autoVertexBufferIndex)
    }
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    if let e = cb.error { throw e }
    var out = readTexture(target)
    for b in outputs { out.append(Data(bytes: b.contents(), count: b.length)) }
    for t in outTextures { out.append(readTexture(t)) }
    return out
}

func renderSignature(_ lib: MTLLibrary, _ v: String, _ f: String) throws -> [String] {
    let (_, refl, fmt, stride) = try autoRenderPipeline(lib, v, f)
    func sig(_ bs: [MTLBinding], _ stage: String) -> [String] {
        bs.map { b -> String in
            var d = "\(stage):\(b.name):\(b.type.rawValue):\(b.index):\(b.access.rawValue):\(b.isUsed)"
            if let bb = b as? MTLBufferBinding { d += ":\(bb.bufferDataSize):\(bb.bufferAlignment):\(bb.bufferDataType.rawValue)" }
            if let tb = b as? MTLTextureBinding { d += ":\(tb.textureType.rawValue):\(tb.textureDataType.rawValue)" }
            return d
        }
    }
    return (["target:\(fmt.rawValue):\(stride)"] + sig(refl?.vertexBindings ?? [], "v") + sig(refl?.fragmentBindings ?? [], "f")).sorted()
}

func compareOutputs(_ name: String, _ ref: () throws -> Data?, _ ours: () throws -> Data?, _ sig: () throws -> ([String], [String])) -> AutoResult {
    do {
        let sa: [String], sb: [String]
        do { (sa, sb) = try sig() } catch {
            // Distinguish Apple's own pipeline failure (skip) from ours.
            if (try? ref()) == nil { return AutoResult(name: name, status: "skip", detail: "Apple's build fails: \(error)".replacingOccurrences(of: "\n", with: " ")) }
            throw error
        }
        if sa != sb {
            let diff = zip(sa, sb).first(where: { $0 != $1 }).map { "\($0) vs \($1)" } ?? "\(sa.count) vs \(sb.count) bindings"
            return AutoResult(name: name, status: "bindings-differ", detail: diff)
        }
        var refOut: (Data, Data)?
        do {
            if let a = try ref(), let a2 = try ref() { refOut = (a, a2) }
        } catch {
            return AutoResult(name: name, status: "skip", detail: "Apple's build fails with these inputs: \(error)".replacingOccurrences(of: "\n", with: " "))
        }
        guard let (a, a2) = refOut else { return AutoResult(name: name, status: "skip", detail: "unsupported bindings") }
        if a != a2 { return AutoResult(name: name, status: "nondeterministic", detail: "Apple's own runs differ") }
        if a.isEmpty { return AutoResult(name: name, status: "skip", detail: "no writable outputs") }
        guard let b = try ours() else { return AutoResult(name: name, status: "error", detail: "ours: unsupported") }
        if let dir = ProcessInfo.processInfo.environment["AUTO_DUMP"] {
            try? a.write(to: URL(fileURLWithPath: "\(dir)/ref.bin")); try? b.write(to: URL(fileURLWithPath: "\(dir)/ours.bin"))
        }
        if a == b { return AutoResult(name: name, status: "identical", detail: "\(a.count) bytes") }
        var nd = 0
        let ab = [UInt8](a), bb = [UInt8](b)
        for i in 0..<min(ab.count, bb.count) where ab[i] != bb[i] { nd += 1 }
        return AutoResult(name: name, status: "differs", detail: "\(nd) of \(a.count) bytes")
    } catch {
        return AutoResult(name: name, status: "error", detail: "\(error)".replacingOccurrences(of: "\n", with: " "))
    }
}

func autoCompare(_ refPath: String, _ oursPath: String) -> [AutoResult] {
    let ref = loadLib(refPath), ours = loadLib(oursPath)
    var results: [AutoResult] = [] {
        didSet { if let r = results.last { print("\(r.status)\t\(r.name)\t\(r.detail)") } }
    }
    var vertexFns: [String] = []
    var fragmentFns: [String] = []
    for name in ref.functionNames.sorted() {
        guard let f = ref.makeFunction(name: name) else { continue }
        switch f.functionType {
        case .vertex: vertexFns.append(name)
        case .fragment: fragmentFns.append(name)
        case .kernel:
            results.append(compareOutputs(name, { try runKernelAuto(ref, name, seed: 7) }, { try runKernelAuto(ours, name, seed: 7) },
                                          { (try bindingSignature(ref, name), try bindingSignature(ours, name)) }))
        default: break
        }
    }
    for fname in fragmentFns {
        // Pair with the first vertex function in the library that Apple's build links with this fragment function.
        guard let v = vertexFns.first(where: { (try? autoRenderPipeline(ref, $0, fname)) != nil }) else {
            results.append(AutoResult(name: fname, status: "skip", detail: "no vertex function in the library links with it")); continue
        }
        let name = "\(v)+\(fname)"
        results.append(compareOutputs(name, { try runRenderAuto(ref, v, fname, seed: 7) }, { try runRenderAuto(ours, v, fname, seed: 7) },
                                      { (try renderSignature(ref, v, fname), try renderSignature(ours, v, fname)) }))
    }
    return results
}

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
case "auto":
    setvbuf(stdout, nil, _IOLBF, 0)
    _ = autoCompare(args[2], args[3])
case "check":
    // Load the library and build a pipeline for every kernel (GPU back-end compile), reporting failures.
    let lib = loadLib(args[2])
    var bad = 0
    for name in lib.functionNames.sorted() {
        guard let f = lib.makeFunction(name: name) else { print("NOFUNC \(name)"); bad += 1; continue }
        if f.functionType == .kernel && f.functionConstantsDictionary.values.allSatisfy({ !$0.required }) {
            do { _ = try dev.makeComputePipelineState(function: f) } catch { print("PIPELINE \(name): \(error)"); bad += 1 }
        }
    }
    print("checked \(lib.functionNames.count) functions, \(bad) failures")
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
