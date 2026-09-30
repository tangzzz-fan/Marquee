// RenderBench — SwiftUI Canvas vs Core Graphics vs Metal
// 目标：在真实画布尺寸下测量标注型图元（矩形/椭圆/线段/箭头/画笔折线）的重绘开销。
// 三种实现绘制完全相同的确定性场景，排除算法差异。

import Foundation
import AppKit
import SwiftUI
import Metal
import MetalKit
import CoreText
import QuartzCore

// MARK: - 场景模型

struct Prim {
    var shape: Int32      // 0 = 圆角矩形, 1 = 椭圆, 2 = 线段(旋转瘦矩形)
    var cx: Double
    var cy: Double
    var w: Double
    var h: Double
    var rot: Double
    var r: Double
    var g: Double
    var b: Double
    var a: Double
    var cornerRadius: Double
    var strokeWidth: Double
}

struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
}

let canvasSize = CGSize(width: 1600, height: 1000)   // 点
let scaleFactor: CGFloat = 2                          // Retina backing scale
let pixelSize = (Int(canvasSize.width * scaleFactor), Int(canvasSize.height * scaleFactor))

func makeScene(perKind: Int) -> [Prim] {
    var rng = LCG(state: 0x5EED_1234)
    var out: [Prim] = []
    out.reserveCapacity(perKind * 5)

    for kind in 0..<5 {
        for _ in 0..<perKind {
            var p = Prim(shape: Int32(kind % 3), cx: 0, cy: 0, w: 0, h: 0, rot: 0,
                         r: rng.range(0.2, 1.0), g: rng.range(0.2, 1.0), b: rng.range(0.2, 1.0),
                         a: rng.range(0.6, 1.0), cornerRadius: 0, strokeWidth: 0)
            switch kind {
            case 0: // 填充 + 描边矩形
                p.shape = 0
                p.w = rng.range(40, 260); p.h = rng.range(30, 160)
                p.strokeWidth = rng.range(0, 4)
                p.cornerRadius = rng.range(0, 12)
            case 1: // 椭圆
                p.shape = 1
                p.w = rng.range(30, 180); p.h = rng.range(30, 180)
                p.strokeWidth = rng.range(0, 4)
            case 2: // 线段
                p.shape = 2
                p.w = rng.range(60, 400); p.h = rng.range(2, 6)
                p.rot = rng.range(-Double.pi, Double.pi)
            case 3: // 箭头 = 主干 + 两条头部线段
                p.shape = 2
                p.w = rng.range(80, 320); p.h = rng.range(4, 8)
                p.rot = rng.range(-Double.pi, Double.pi)
            default: // 画笔折线（由多段构成）
                p.shape = 2
                p.w = rng.range(100, 500); p.h = rng.range(3, 6)
                p.rot = rng.range(-Double.pi, Double.pi)
            }
            p.cx = rng.range(60, Double(canvasSize.width) - 60)
            p.cy = rng.range(60, Double(canvasSize.height) - 60)
            out.append(p)
            if kind == 3 { // 箭头头部
                for _ in 0..<2 {
                    var head = p
                    head.w = p.h * 3.5
                    head.rot = p.rot + 2.6
                    head.cx = p.cx + cos(p.rot) * p.w / 2
                    head.cy = p.cy + sin(p.rot) * p.w / 2
                    out.append(head)
                }
            }
            if kind == 4 { // 折线段
                for seg in 1..<6 {
                    var s = p
                    s.w = p.w / 5
                    let t = Double(seg) / 5.0
                    s.cx = p.cx + cos(p.rot) * p.w * (t - 0.5)
                    s.cy = p.cy + sin(p.rot) * p.w * (t - 0.5)
                    s.rot = p.rot + rng.range(-0.4, 0.4)
                    out.append(s)
                }
            }
        }
    }
    return out
}

let textRuns = (0..<200).map { i -> String in "Annotation \(i) · label" }

// MARK: - Core Graphics

final class CGRenderer {
    let ctx: CGContext
    init() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx = CGContext(data: nil, width: pixelSize.0, height: pixelSize.1,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: scaleFactor, y: scaleFactor)
        ctx.setShouldAntialias(true)
    }

    func frame(_ prims: [Prim], drawText: Bool) {
        ctx.setBlendMode(.normal)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvasSize))

        for p in prims {
            ctx.saveGState()
            ctx.translateBy(x: p.cx, y: p.cy)
            ctx.rotate(by: p.rot)
            let color = CGColor(red: p.r, green: p.g, blue: p.b, alpha: p.a)
            let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
            if p.strokeWidth > 0 {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(p.strokeWidth)
                if p.shape == 0 {
                    let path = CGPath(roundedRect: rect, cornerWidth: p.cornerRadius,
                                      cornerHeight: p.cornerRadius, transform: nil)
                    ctx.addPath(path)
                } else {
                    ctx.addEllipse(in: rect)
                }
                ctx.strokePath()
            } else {
                ctx.setFillColor(color)
                if p.shape == 0 {
                    let path = CGPath(roundedRect: rect, cornerWidth: p.cornerRadius,
                                      cornerHeight: p.cornerRadius, transform: nil)
                    ctx.addPath(path)
                } else {
                    ctx.addEllipse(in: rect)
                }
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        if drawText {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
            for (i, s) in textRuns.enumerated() {
                let attr = NSAttributedString(string: s, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white
                ])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 40 + Double(i % 8) * 190, y: 40 + Double(i / 8) * 38)
                CTLineDraw(line, ctx)
            }
        }
    }
}

// MARK: - SwiftUI Canvas

@MainActor
final class CanvasRenderer {
    func frame(_ prims: [Prim], drawText: Bool) -> Double {
        let content = Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.1, green: 0.1, blue: 0.12)))
            for p in prims {
                var path = Path()
                let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
                if p.shape == 0 {
                    path = Path(roundedRect: rect, cornerRadius: p.cornerRadius)
                } else if p.shape == 1 {
                    path = Path(ellipseIn: rect)
                } else {
                    path = Path(rect)
                }
                var transform = CGAffineTransform(translationX: p.cx, y: p.cy)
                    .rotated(by: p.rot)
                let color = Color(red: p.r, green: p.g, blue: p.b).opacity(p.a)
                if p.strokeWidth > 0 {
                    context.stroke(path.applying(transform), with: .color(color),
                                   lineWidth: p.strokeWidth)
                } else {
                    context.fill(path.applying(transform), with: .color(color))
                }
            }
            if drawText {
                let font = Font.custom("Helvetica-Bold", size: 24)
                for (i, s) in textRuns.enumerated() {
                    var t = context.resolve(Text(s).font(font).foregroundColor(.white))
                    t.shading = .color(.white)
                    context.draw(t, at: CGPoint(x: 40 + Double(i % 8) * 190,
                                                y: 40 + Double(i / 8) * 38),
                                 anchor: .topLeading)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scaleFactor
        renderer.isOpaque = true
        _ = renderer.cgImage
        return 0
    }
}

// MARK: - Metal

struct GPUInstance {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var rot: Float
    var color: SIMD4<Float>
    var cornerRadius: Float
    var strokeWidth: Float
    var shape: Float
    var pad: Float
}

let msl = """
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float2 center;
    float2 halfSize;
    float  rot;
    float4 color;
    float  cornerRadius;
    float  strokeWidth;
    float  shape;
    float  pad;
};

struct VOut {
    float4 position [[position]];
    float2 local;
    float2 halfSize;
    float4 color;
    float  cornerRadius;
    float  strokeWidth;
    float  shape;
};

vertex VOut vs_main(uint vid [[vertex_id]],
                    uint iid [[instance_id]],
                    const device Instance* inst [[buffer(0)]],
                    constant float2& viewport [[buffer(1)]]) {
    float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                          float2(-1,-1), float2(1,1),  float2(1,-1) };
    Instance it = inst[iid];
    float2 c = corners[vid];
    float s = sin(it.rot), co = cos(it.rot);
    float2 p = float2(c.x * it.halfSize.x * co - c.y * it.halfSize.y * s,
                      c.x * it.halfSize.x * s  + c.y * it.halfSize.y * co) + it.center;
    float2 ndc = float2(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0);
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local = c;
    o.halfSize = it.halfSize;
    o.color = it.color;
    o.cornerRadius = it.cornerRadius;
    o.strokeWidth = it.strokeWidth;
    o.shape = it.shape;
    return o;
}

static inline float roundedBoxSDF(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 fs_main(VOut in [[stage_in]]) {
    float2 p = in.local * in.halfSize;
    float d;
    if (in.shape < 0.5) {
        d = roundedBoxSDF(p, in.halfSize, in.cornerRadius);
    } else {
        d = (length(p / in.halfSize) - 1.0) * min(in.halfSize.x, in.halfSize.y);
    }
    float aa = 1.0;
    float alpha;
    if (in.strokeWidth > 0.0) {
        float band = in.strokeWidth * 0.5;
        alpha = clamp(1.0 - max(abs(d) - band, 0.0) / aa, 0.0, 1.0);
    } else {
        alpha = clamp(-d / aa + 0.5, 0.0, 1.0);
    }
    if (alpha <= 0.001) discard_fragment();
    return float4(in.color.rgb, in.color.a * alpha);
}
"""

final class MetalRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let tex: MTLTexture
    let instanceBuffer: MTLBuffer

    init(instanceCount: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "no device", code: 1) }
        self.device = device
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: msl, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vs_main")
        desc.fragmentFunction = lib.makeFunction(name: "fs_main")
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.sourceAlphaBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelSize.0, height: pixelSize.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        tex = device.makeTexture(descriptor: td)!

        instanceBuffer = device.makeBuffer(length: max(instanceCount, 1) * MemoryLayout<GPUInstance>.stride,
                                           options: .storageModeShared)!
    }

    func upload(_ prims: [Prim]) {
        let ptr = instanceBuffer.contents().bindMemory(to: GPUInstance.self, capacity: prims.count)
        for (i, p) in prims.enumerated() {
            ptr[i] = GPUInstance(
                center: SIMD2(Float(p.cx * scaleFactor), Float(p.cy * scaleFactor)),
                halfSize: SIMD2(Float(max(p.w / 2, 0.5) * scaleFactor), Float(max(p.h / 2, 0.5) * scaleFactor)),
                rot: Float(p.rot),
                color: SIMD4(Float(p.r), Float(p.g), Float(p.b), Float(p.a)),
                cornerRadius: Float(p.cornerRadius * scaleFactor),
                strokeWidth: Float(p.strokeWidth * scaleFactor),
                shape: Float(p.shape == 1 ? 1 : 0),
                pad: 0)
        }
    }

    func frame(count: Int) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(Float(pixelSize.0), Float(pixelSize.1))
        enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}

// MARK: - 计时框架

struct Stats {
    let p50: Double
    let p95: Double
    let mean: Double
    var text: String { String(format: "p50 %7.2f ms | p95 %7.2f ms | mean %7.2f ms", p50, p95, mean) }
}

func measure(warmup: Int = 8, iterations: Int = 60, _ body: () -> Void) -> Stats {
    for _ in 0..<warmup { body() }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let t0 = CACurrentMediaTime()
        body()
        samples.append((CACurrentMediaTime() - t0) * 1000)
    }
    samples.sort()
    let p50 = samples[samples.count / 2]
    let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    let mean = samples.reduce(0, +) / Double(samples.count)
    return Stats(p50: p50, p95: p95, mean: mean)
}

// MARK: - main

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
setvbuf(stdout, nil, _IONBF, 0)

print("=== RenderBench ===")
print("canvas \(Int(canvasSize.width))x\(Int(canvasSize.height)) pt @\(Int(scaleFactor))x -> \(pixelSize.0)x\(pixelSize.1) px")
print("device: \(MTLCreateSystemDefaultDevice()?.name ?? "n/a")")
print("")

let scenarios: [(String, Int)] = [("典型负载", 200), ("压力负载", 2000)]

@MainActor
func run() throws {
    for (label, perKind) in scenarios {
        let prims = makeScene(perKind: perKind)
        print("--- \(label)：\(prims.count) 个图元 + \(textRuns.count) 段文字 ---")

        // Core Graphics
        let cg = CGRenderer()
        var s = measure { cg.frame(prims, drawText: false) }
        print("CG     几何      \(s.text)")
        s = measure { cg.frame(prims, drawText: true) }
        print("CG     几何+文字  \(s.text)")

        // Metal
        let metal = try MetalRenderer(instanceCount: prims.count)
        metal.upload(prims)
        s = measure { metal.frame(count: prims.count) }
        print("Metal  几何      \(s.text)")
        print("Metal  几何+文字  文字需走 CoreText 图集（见下方独立测量）")

        // SwiftUI Canvas
        let canvas = CanvasRenderer()
        s = measure { _ = canvas.frame(prims, drawText: false) }
        print("Canvas 几何      \(s.text)")
        s = measure { _ = canvas.frame(prims, drawText: true) }
        print("Canvas 几何+文字  \(s.text)")
        print("")
    }

    // 文字栅格化的独立成本（Metal 路径需要）
    let cg = CGRenderer()
    let s = measure(iterations: 40) {
        let ctx = cg.ctx
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
        for (i, str) in textRuns.enumerated() {
            let attr = NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 40 + Double(i % 8) * 190, y: 40 + Double(i / 8) * 38)
            CTLineDraw(line, ctx)
        }
    }
    print("CoreText 冷栅格化 \(textRuns.count) 段文字: \(s.text)")
}

try MainActor.assumeIsolated { try run() }
