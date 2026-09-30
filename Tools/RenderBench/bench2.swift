// RenderBench 2 — 补充对照
// 1) CG 朴素实现 vs CG 优化实现（路径预变换 + 颜色缓存）
// 2) 真实标注量级（50 图元）的决策相关数据
// 3) 马赛克 / 毛玻璃模糊的独立成本（标注功能 P1 项）

import Foundation
import AppKit
import SwiftUI
import Metal
import CoreImage
import CoreText
import QuartzCore

// MARK: - 场景

struct Prim {
    var shape: Int32      // 0 圆角矩形, 1 椭圆, 2 线段
    var cx: Double, cy: Double, w: Double, h: Double, rot: Double
    var r: Double, g: Double, b: Double, a: Double
    var cornerRadius: Double, strokeWidth: Double
}

struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
}

let canvasSize = CGSize(width: 1600, height: 1000)
let scaleFactor: CGFloat = 2
let pixelSize = (Int(canvasSize.width * scaleFactor), Int(canvasSize.height * scaleFactor))

func makeScene(perKind: Int) -> [Prim] {
    var rng = LCG(state: 0x5EED_1234)
    var out: [Prim] = []
    for kind in 0..<3 {
        for _ in 0..<perKind {
            var p = Prim(shape: Int32(kind % 3), cx: 0, cy: 0, w: 0, h: 0, rot: 0,
                         r: rng.range(0.2, 1.0), g: rng.range(0.2, 1.0), b: rng.range(0.2, 1.0),
                         a: rng.range(0.6, 1.0), cornerRadius: 0, strokeWidth: 0)
            p.w = rng.range(60, 320); p.h = rng.range(20, 160)
            if kind == 0 { p.strokeWidth = rng.range(0, 4); p.cornerRadius = rng.range(0, 12) }
            if kind == 1 { p.strokeWidth = rng.range(0, 4) }
            if kind == 2 { p.h = rng.range(3, 6); p.rot = rng.range(-Double.pi, Double.pi) }
            p.cx = rng.range(60, Double(canvasSize.width) - 60)
            p.cy = rng.range(60, Double(canvasSize.height) - 60)
            out.append(p)
        }
    }
    return out
}

// MARK: - CG 朴素实现

final class CGNaive {
    let ctx: CGContext
    init() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx = CGContext(data: nil, width: pixelSize.0, height: pixelSize.1,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: scaleFactor, y: scaleFactor)
    }
    func frame(_ prims: [Prim]) {
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvasSize))
        for p in prims {
            ctx.saveGState()
            ctx.translateBy(x: p.cx, y: p.cy)
            ctx.rotate(by: p.rot)
            let color = CGColor(red: p.r, green: p.g, blue: p.b, alpha: p.a)
            let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
            ctx.setLineWidth(p.strokeWidth)
            if p.shape == 0 {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: p.cornerRadius,
                                   cornerHeight: p.cornerRadius, transform: nil))
            } else {
                ctx.addEllipse(in: rect)
            }
            if p.strokeWidth > 0 { ctx.setStrokeColor(color); ctx.strokePath() }
            else { ctx.setFillColor(color); ctx.fillPath() }
            ctx.restoreGState()
        }
    }
}

// MARK: - CG 优化实现（路径预变换 + 颜色缓存 + 无状态churn）

final class CGOptimized {
    let ctx: CGContext
    private var paths: [CGPath] = []
    private var colors: [CGColor] = []
    private var strokes: [CGFloat] = []
    private var isStroke: [Bool] = []

    init() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx = CGContext(data: nil, width: pixelSize.0, height: pixelSize.1,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: scaleFactor, y: scaleFactor)
    }

    /// 与真实编辑器一致：几何与颜色只在对象变化时重算，每帧只提交绘制
    func prepare(_ prims: [Prim]) {
        paths = prims.map { p in
            let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
            var t = CGAffineTransform(translationX: p.cx, y: p.cy).rotated(by: p.rot)
            if p.shape == 0 {
                return CGPath(roundedRect: rect, cornerWidth: p.cornerRadius,
                              cornerHeight: p.cornerRadius, transform: &t)
            } else if p.shape == 1 {
                return CGPath(ellipseIn: rect, transform: &t)
            } else {
                return CGPath(rect: rect, transform: &t)
            }
        }
        colors = prims.map { CGColor(red: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) }
        strokes = prims.map { CGFloat($0.strokeWidth) }
        isStroke = prims.map { $0.strokeWidth > 0 }
    }

    func frame() {
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvasSize))
        for i in 0..<paths.count {
            ctx.beginPath()
            ctx.addPath(paths[i])
            if isStroke[i] {
                ctx.setStrokeColor(colors[i])
                ctx.setLineWidth(strokes[i])
                ctx.strokePath()
            } else {
                ctx.setFillColor(colors[i])
                ctx.fillPath()
            }
        }
    }
}

// MARK: - SwiftUI Canvas

@MainActor
final class CanvasRenderer {
    func frame(_ prims: [Prim]) -> Void {
        let content = Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.1, green: 0.1, blue: 0.12)))
            for p in prims {
                let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
                var path: Path
                if p.shape == 0 { path = Path(roundedRect: rect, cornerRadius: p.cornerRadius) }
                else if p.shape == 1 { path = Path(ellipseIn: rect) }
                else { path = Path(rect) }
                let t = CGAffineTransform(translationX: p.cx, y: p.cy).rotated(by: p.rot)
                let color = Color(red: p.r, green: p.g, blue: p.b).opacity(p.a)
                if p.strokeWidth > 0 {
                    context.stroke(path.applying(t), with: .color(color), lineWidth: p.strokeWidth)
                } else {
                    context.fill(path.applying(t), with: .color(color))
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        let r = ImageRenderer(content: content)
        r.scale = scaleFactor
        r.isOpaque = true
        _ = r.cgImage
    }
}

// MARK: - Metal（复用 v1 管线，精简版）

struct GPUInstance {
    var center: SIMD2<Float>, halfSize: SIMD2<Float>, rot: Float
    var color: SIMD4<Float>, cornerRadius: Float, strokeWidth: Float, shape: Float, pad: Float
}

let msl = """
#include <metal_stdlib>
using namespace metal;
struct Instance { float2 center; float2 halfSize; float rot; float4 color;
                  float cornerRadius; float strokeWidth; float shape; float pad; };
struct VOut { float4 position [[position]]; float2 local; float2 halfSize; float4 color;
              float cornerRadius; float strokeWidth; float shape; };
vertex VOut vs_main(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device Instance* inst [[buffer(0)]], constant float2& vp [[buffer(1)]]) {
    float2 c6[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,-1), float2(1,1), float2(1,-1) };
    Instance it = inst[iid]; float2 c = c6[vid];
    float s = sin(it.rot), co = cos(it.rot);
    float2 p = float2(c.x*it.halfSize.x*co - c.y*it.halfSize.y*s,
                      c.x*it.halfSize.x*s + c.y*it.halfSize.y*co) + it.center;
    VOut o; o.position = float4(p.x/vp.x*2.0-1.0, 1.0-p.y/vp.y*2.0, 0, 1);
    o.local = c; o.halfSize = it.halfSize; o.color = it.color;
    o.cornerRadius = it.cornerRadius; o.strokeWidth = it.strokeWidth; o.shape = it.shape;
    return o;
}
static inline float rbox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r; return length(max(q,0.0)) + min(max(q.x,q.y),0.0) - r; }
fragment float4 fs_main(VOut in [[stage_in]]) {
    float2 p = in.local * in.halfSize; float d;
    if (in.shape < 0.5) { d = rbox(p, in.halfSize, in.cornerRadius); }
    else { d = (length(p/in.halfSize) - 1.0) * min(in.halfSize.x, in.halfSize.y); }
    float alpha;
    if (in.strokeWidth > 0.0) {
        alpha = clamp(1.0 - max(abs(d) - in.strokeWidth*0.5, 0.0), 0.0, 1.0);
    } else { alpha = clamp(-d + 0.5, 0.0, 1.0); }
    if (alpha <= 0.001) discard_fragment();
    return float4(in.color.rgb, in.color.a * alpha);
}
"""

final class MetalRenderer {
    let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState
    let tex: MTLTexture, buf: MTLBuffer
    init(count: Int) throws {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: msl, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs_main")
        d.fragmentFunction = lib.makeFunction(name: "fs_main")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm; a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .sourceAlpha; a.sourceAlphaBlendFactor = .sourceAlpha
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelSize.0, height: pixelSize.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        tex = device.makeTexture(descriptor: td)!
        buf = device.makeBuffer(length: max(count,1) * MemoryLayout<GPUInstance>.stride,
                                options: .storageModeShared)!
    }
    func upload(_ prims: [Prim]) {
        let ptr = buf.contents().bindMemory(to: GPUInstance.self, capacity: prims.count)
        for (i, p) in prims.enumerated() {
            ptr[i] = GPUInstance(
                center: SIMD2(Float(p.cx*scaleFactor), Float(p.cy*scaleFactor)),
                halfSize: SIMD2(Float(max(p.w/2,0.5)*scaleFactor), Float(max(p.h/2,0.5)*scaleFactor)),
                rot: Float(p.rot),
                color: SIMD4(Float(p.r), Float(p.g), Float(p.b), Float(p.a)),
                cornerRadius: Float(p.cornerRadius*scaleFactor),
                strokeWidth: Float(p.strokeWidth*scaleFactor),
                shape: Float(p.shape == 1 ? 1 : 0), pad: 0)
        }
    }
    func frame(count: Int) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let cb = queue.makeCommandBuffer()!
        let e = cb.makeRenderCommandEncoder(descriptor: rp)!
        e.setRenderPipelineState(pipeline)
        e.setVertexBuffer(buf, offset: 0, index: 0)
        var vp = SIMD2<Float>(Float(pixelSize.0), Float(pixelSize.1))
        e.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }
}

// MARK: - 计时

struct Stats {
    let p50: Double, p95: Double
    var text: String { String(format: "p50 %8.2f ms | p95 %8.2f ms", p50, p95) }
}

func measure(warmup: Int = 5, iterations: Int = 30, _ body: () -> Void) -> Stats {
    for _ in 0..<warmup { body() }
    var s: [Double] = []
    for _ in 0..<iterations {
        let t0 = CACurrentMediaTime(); body(); s.append((CACurrentMediaTime() - t0) * 1000)
    }
    s.sort()
    return Stats(p50: s[s.count/2], p95: s[min(s.count-1, Int(Double(s.count)*0.95))])
}

// MARK: - main

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
setvbuf(stdout, nil, _IONBF, 0)

print("=== RenderBench 2 ===")
print("canvas \(Int(canvasSize.width))x\(Int(canvasSize.height)) pt @\(Int(scaleFactor))x -> \(pixelSize.0)x\(pixelSize.1) px")
print("device: \(MTLCreateSystemDefaultDevice()?.name ?? "n/a")   cores: \(ProcessInfo.processInfo.processorCount)")
print("")

@MainActor
func run() throws {
    let scenarios: [(String, Int)] = [("轻量（≈50 图元）", 17), ("中等（≈500 图元）", 167), ("大量（≈2400 图元）", 800)]

    for (label, perKind) in scenarios {
        let prims = makeScene(perKind: perKind)
        print("--- \(label)：\(prims.count) 个图元 ---")

        let naive = CGNaive()
        print("CG 朴素        \(measure { naive.frame(prims) }.text)")

        let opt = CGOptimized()
        opt.prepare(prims)
        print("CG 优化        \(measure { opt.frame() }.text)")

        let canvas = CanvasRenderer()
        print("SwiftUI Canvas \(measure { canvas.frame(prims) }.text)")

        let metal = try MetalRenderer(count: prims.count)
        metal.upload(prims)
        print("Metal(离屏)    \(measure { metal.frame(count: prims.count) }.text)")
        print("")
    }

    // MARK: 马赛克 / 模糊成本
    print("--- 马赛克 / 模糊（标注 P1 功能）---")
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let baseCtx = CGContext(data: nil, width: pixelSize.0, height: pixelSize.1,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    baseCtx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    baseCtx.fill(CGRect(x: 0, y: 0, width: pixelSize.0, height: pixelSize.1))
    let baseImage = baseCtx.makeImage()!

    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let fullRect = CGRect(x: 0, y: 0, width: pixelSize.0, height: pixelSize.1)

    var ci = CIImage(cgImage: baseImage)
    let blurStats = measure {
        let filtered = ci.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 24])
        _ = ciContext.createCGImage(filtered.cropped(to: fullRect), from: fullRect)
    }
    print("CI 高斯模糊 r=24 全画布   \(blurStats.text)")

    ci = CIImage(cgImage: baseImage)
    let pixStats = measure {
        let filtered = ci.applyingFilter("CIPixellate", parameters: ["inputScale": 16])
        _ = ciContext.createCGImage(filtered.cropped(to: fullRect), from: fullRect)
    }
    print("CI 像素化 scale=16 全画布 \(pixStats.text)")

    // CG 手工像素化（降采样 + 最近邻放大），常用于避免 CI 往返开销
    let cgPixStats = measure {
        let w = pixelSize.0 / 16, h = pixelSize.1 / 16
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        small.interpolationQuality = .medium
        small.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let down = small.makeImage() else { return }
        baseCtx.interpolationQuality = .none
        baseCtx.draw(down, in: fullRect)
    }
    print("CG 手工像素化 16 全画布   \(cgPixStats.text)")
}

try MainActor.assumeIsolated { try run() }
