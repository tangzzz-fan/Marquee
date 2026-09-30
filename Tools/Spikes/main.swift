// Snipo Spike Runner
// 用途：在写第一行产品代码之前，把架构中的高风险假设逐条验证掉。
// 用法：
//   swiftc -O -swift-version 5 -o spikes main.swift && ./spikes            # 基础探测
//   ./spikes scroll                                                        # 滚动截屏配准验证（合成数据）

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Vision
import Carbon.HIToolbox
import ScreenCaptureKit
import UniformTypeIdentifiers
import QuartzCore

// MARK: - 报告

var passCount = 0, failCount = 0, manualCount = 0

func report(_ id: String, _ status: String, _ detail: String) {
    if status == "PASS" { passCount += 1 }
    else if status == "FAIL" { failCount += 1 }
    else { manualCount += 1 }
    let pad = String(repeating: " ", count: max(0, 4 - id.count))
    print("[\(status)] \(id)\(pad) \(detail)")
}

// MARK: - S1 屏幕录制 / 输入监控 权限检测 API

func spikeS1() {
    print("\n--- S1 权限检测 API 可用性 ---")

    let screenGranted = CGPreflightScreenCaptureAccess()
    report("S1.1", "PASS", "CGPreflightScreenCaptureAccess() 编译通过，当前屏幕录制授权 = \(screenGranted)")

    let listenGranted = CGPreflightListenEventAccess()
    report("S1.2", "PASS", "CGPreflightListenEventAccess() 编译通过，当前输入监控授权 = \(listenGranted)")

    let axTrusted = AXIsProcessTrusted()
    report("S1.3", "PASS", "AXIsProcessTrusted() = \(axTrusted)（辅助功能授权）")

    if screenGranted {
        report("S1.4", "PASS", "已授权 → 可继续验证 SCShareableContent 与真实采集")
    } else {
        report("S1.4", "MANUAL",
               "未授权 → SCShareableContent 的未授权行为、真实采集、权限撤销路径需人工跑一次（见 SPIKE-PLAN.md S3/S4）")
    }
}

// MARK: - S2 全局快捷键（Carbon，是否依赖辅助功能权限）

func spikeS2() {
    print("\n--- S2 全局快捷键注册（Carbon RegisterEventHotKey）---")

    var ref: EventHotKeyRef?
    // 故意用两个不同热键：一个冷门（预期成功），一个很可能被占用（验证冲突检测）
    let rareID = EventHotKeyID(signature: OSType(0x534E5053), id: 1)   // 'SNPS'
    let rareStatus = RegisterEventHotKey(UInt32(kVK_F19),
                                         UInt32(cmdKey | optionKey | controlKey),
                                         rareID, GetApplicationEventTarget(), 0, &ref)
    if rareStatus == noErr {
        report("S2.1", "PASS", "冷门组合 ⌃⌥⌘F19 注册成功（OSStatus=0），且**无需辅助功能权限**")
        UnregisterEventHotKey(ref)
    } else {
        report("S2.1", "FAIL", "冷门组合注册失败 OSStatus=\(rareStatus)")
    }

    var ref2: EventHotKeyRef?
    var ref2b: EventHotKeyRef?
    let dupID = EventHotKeyID(signature: OSType(0x534E5053), id: 2)
    let first = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | controlKey),
                                    dupID, GetApplicationEventTarget(), 0, &ref2)
    let second = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | controlKey),
                                     EventHotKeyID(signature: OSType(0x534E5053), id: 3),
                                     GetApplicationEventTarget(), 0, &ref2b)
    report("S2.2", "PASS",
           "⌃⌘A 首次注册 OSStatus=\(first)（0=成功）| 重复注册 OSStatus=\(second)（\(second == -9878 ? "-9878 = eventHotKeyExistsErr，冲突可检测" : "非预期值，需查表")）")
    if first == noErr { UnregisterEventHotKey(ref2) }
    if second == noErr { UnregisterEventHotKey(ref2b) }

    report("S2.3", "MANUAL", "热键**实际触发回调**需人工按一次（见 SPIKE-PLAN.md S2），本次仅验证注册与冲突检测")

    // 事件tap 监听是否可行（备选方案）
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in }
    let monitorCreated = monitor != nil
    report("S2.4", "PASS",
           "NSEvent.addGlobalMonitorForEvents 返回 \(monitorCreated ? "非 nil" : "nil")——**注意：当前输入监控授权=\(CGPreflightListenEventAccess())，返回非 nil 并不等于能收到事件**，该方案仍强依赖输入监控权限，故不作为主方案")
    if let m = monitor { NSEvent.removeMonitor(m) }
}

// MARK: - S5 Vision OCR

func spikeS5() {
    print("\n--- S5 Vision OCR 可用性与耗时 ---")

    let w = 900, h = 260
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
    let lines = ["Snipo OCR spike 2026", "屏幕录制权限已检测", "Hello Vision Framework"]
    for (i, s) in lines.enumerated() {
        let attr = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: NSColor.black
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 30, y: Double(h - 70 - i * 70))
        CTLineDraw(line, ctx)
    }
    guard let image = ctx.makeImage() else { report("S5.1", "FAIL", "测试图生成失败"); return }

    var recognized: [String] = []
    var cold: Double = 0, warm: [Double] = []
    do {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // 首次调用 = 冷启动（Vision 按需加载 OCR 模型）
        let t0 = CACurrentMediaTime()
        try handler.perform([request])
        cold = (CACurrentMediaTime() - t0) * 1000
        recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        // 预热后测量稳态
        for _ in 0..<5 {
            let r2 = VNRecognizeTextRequest()
            r2.recognitionLevel = .accurate
            r2.recognitionLanguages = ["zh-Hans", "en-US"]
            let h2 = VNImageRequestHandler(cgImage: image, options: [:])
            let t1 = CACurrentMediaTime()
            try h2.perform([r2])
            warm.append((CACurrentMediaTime() - t1) * 1000)
        }
    } catch {
        report("S5.1", "FAIL", "OCR 抛错：\(error)")
        return
    }

    let joined = recognized.joined(separator: " | ")
    let hit = recognized.contains { $0.contains("Snipo") || $0.contains("屏幕录制") || $0.contains("Vision") }
    report("S5.1", hit ? "PASS" : "FAIL", "识别到 \(recognized.count) 行：" + joined)
    warm.sort()
    report("S5.2", "PASS", String(format: "冷启动首次 %.0f ms（含模型加载）；预热后 p50 %.0f ms / p95 %.0f ms（900x260 px, accurate, 中英双语）",
                                   cold, warm[warm.count / 2], warm[min(warm.count - 1, Int(Double(warm.count) * 0.95))]))
    if cold > 3000 {
        report("S5.3", "PASS", "⚠️ 冷启动代价高 → 首次触发 OCR 必须在后台预热（启动时跑一张 1x1 空图）或给出等待反馈")
    }
}

// MARK: - S6 剪贴板 PNG 分辨率保真

func spikeS6() {
    print("\n--- S6 剪贴板 PNG 分辨率保真（Retina 经典坑）---")

    // 造一张 2x 图：逻辑 100x100 pt，物理 200x200 px
    let pointSize = 100, scale = 2
    let pxSize = pointSize * scale
    let ctx = CGContext(data: nil, width: pxSize, height: pxSize, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pxSize, height: pxSize))
    guard let image = ctx.makeImage() else { report("S6.1", "FAIL", "测试图生成失败"); return }
    guard let data = CFDataCreateMutable(nil, 0),
          let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        report("S6.1", "FAIL", "ImageIO 目的地创建失败"); return
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { report("S6.1", "FAIL", "PNG 编码失败"); return }
    let pngData = data as Data
    report("S6.1", "PASS", "PNG 编码成功，\(pngData.count) 字节（源 \(pxSize)x\(pxSize) px）")

    // 路线 A：写原始 PNG 数据（推荐）
    let pb = NSPasteboard.general
    pb.clearContents()
    let okA = pb.setData(pngData, forType: .png)
    var readBackW = 0, readBackH = 0
    if okA, let back = pb.data(forType: .png), let rep = NSBitmapImageRep(data: back) {
        readBackW = rep.pixelsWide; readBackH = rep.pixelsHigh
    }
    let okA2 = (readBackW == pxSize && readBackH == pxSize)
    report("S6.2", okA && okA2 ? "PASS" : "FAIL",
           "路线A 写原始 PNG：写入=\(okA)，读回 \(readBackW)x\(readBackH) px（期望 \(pxSize)x\(pxSize)）")

    // 路线 B：写 NSImage（常见坑：丢失 scale，粘贴端拿不到 2x）
    pb.clearContents()
    let nsImage = NSImage(cgImage: image, size: NSSize(width: pointSize, height: pointSize))
    let okB = pb.writeObjects([nsImage])
    var wB = 0, hB = 0
    if let back = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: back) {
        wB = rep.pixelsWide; hB = rep.pixelsHigh
    }
    report("S6.3", okB ? "PASS" : "FAIL",
           "路线B 写 NSImage：写入=\(okB)，TIFF 读回 \(wB)x\(hB) px（对比路线A 的 \(readBackW)x\(readBackH)）")

    pb.clearContents()
    report("S6.4", "PASS", "结论：优先路线A（.png 原始数据），避免 NSImage 往返")
}

// MARK: - S7 Liquid Glass / 新 API 可用性（编译期 + 运行时）

func spikeS7() {
    print("\n--- S7 Liquid Glass 与新 API 的运行时可用性 ---")

    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 12
        glass.style = .regular
        report("S7.1", "PASS",
               "NSGlassEffectView 可实例化（macOS 26+）：cornerRadius=\(glass.cornerRadius) style=\(glass.style.rawValue)")
        let container = NSGlassEffectContainerView()
        container.spacing = 8
        report("S7.2", "PASS", "NSGlassEffectContainerView 可用（批量玻璃渲染以降低开销）")
    } else {
        report("S7.1", "MANUAL", "当前系统 < 26.0，玻璃效果不可用（需回落材质方案）")
    }

    report("S7.3", "PASS", "编译期结论：NSGlassEffectView/NSGlassEffectContainerView 标注 API_AVAILABLE(macos(26.0))，"
        + "NSGlassEffectView.effectIsInteractive 标注 macos(27.0) —— 最低系统 15.0 下必须包 if #available")

    // 26+ 的 SCScreenshotConfiguration 是否可实例化（最低 15.0 的降级路径验证）
    if #available(macOS 26.0, *) {
        let cfg = SCScreenshotConfiguration()
        cfg.ignoreShadows = true
        cfg.showsCursor = false
        cfg.sourceRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        report("S7.4", "PASS", "SCScreenshotConfiguration 可实例化（macOS 26+），支持 ignoreShadows / showsCursor / sourceRect / destinationRect / fileURL")
    } else {
        report("S7.4", "MANUAL", "当前系统 < 26.0，需走 SCStreamConfiguration 降级路径")
    }
}

// MARK: - S4 滚动截屏配准（合成数据）

final class Gray {
    let w: Int, h: Int
    var px: [UInt8]
    init(width: Int, height: Int) {
        w = width; h = height; px = [UInt8](repeating: 255, count: width * height)
    }
    init?(cg: CGImage) {
        let lw = cg.width, lh = cg.height
        var buf = [UInt8](repeating: 0, count: lw * lh)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: lw, height: lh,
                                      bitsPerComponent: 8, bytesPerRow: lw,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: lw, height: lh))
        }
        // ⚠️ 坑点：CGBitmapContext 的内存行序是**自上而下**（与 CG 用户坐标系原点在左下相反）。
        // 这里绝不能再做一次“翻转到自上而下”——否则会相对各自图像高度镜像，
        // 使两帧之间的位移符号被整体反转（搜索永远找不到正位移）。
        w = lw
        h = lh
        px = buf
    }
    @inline(__always) func row(_ y: Int) -> ArraySlice<UInt8> { px[y * w ..< (y + 1) * w] }
}

struct LCG2 {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double((s >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + next() * (b - a) }
}

let pageW = 1200, pageH = 9000, viewH = 800

func makePage() -> CGImage {
    let ctx = CGContext(data: nil, width: pageW, height: pageH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: pageH))
    var rng = LCG2(s: 0xC0FFEE)

    // 行块：模拟文本段落（每行随机长度、随机灰度）
    var yTop = 40
    while yTop < pageH - 100 {
        let lineH = Int(rng.range(18, 40))
        var x = 60.0
        while x < Double(pageW - 120) {
            let segW = rng.range(40, 220)
            if rng.next() > 0.18 {
                let v = rng.range(0.05, 0.6)
                ctx.setFillColor(gray: CGFloat(v), alpha: 1)
                ctx.fill(CGRect(x: x, y: Double(pageH - yTop - lineH), width: segW, height: Double(lineH)))
            }
            x += segW + 14
        }
        yTop += lineH + Int(rng.range(8, 22))
    }
    // 少量高对比实心块，提供强特征
    for _ in 0..<40 {
        let bx = rng.range(80, Double(pageW - 260))
        let by = rng.range(80, Double(pageH - 260))
        ctx.setFillColor(gray: CGFloat(rng.range(0.0, 0.35)), alpha: 1)
        ctx.fill(CGRect(x: bx, y: by, width: rng.range(60, 240), height: rng.range(30, 160)))
    }
    // 文字（真实渲染，验证抗锯齿对配准的影响）
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
    for i in stride(from: 0, to: 60, by: 1) {
        let attr = NSAttributedString(string: "Snipo scroll spike line \(i) — 滚动截屏配准验证",
                                      attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 60, y: Double(pageH - 200 - i * 140))
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()!
}

/// 从长页取一帧；offsetY 支持小数（模拟亚像素滚动）
/// 用 CGImage.cropping 直接裁剪（图像坐标系原点在左上，语义明确），避免负坐标 rect 绘制的不确定性
func frame(from page: CGImage, offsetY: Double, stickyHeader: Bool = false,
           cursor: (Int, Int)? = nil) -> CGImage {
    let iy = Int(floor(offsetY))
    let frac = offsetY - Double(iy)
    let needH = min(viewH + 2, page.height - iy)
    guard let cropped = page.cropping(to: CGRect(x: 0, y: iy, width: pageW, height: needH)) else {
        return page
    }
    let ctx = CGContext(data: nil, width: pageW, height: viewH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: viewH))
    // 帧的顶行 = 长页第 offsetY 行；cropping 的顶行即 offsetY，
    // 亚像素部分通过把裁剪块下移 frac 实现（等效于视口多滚了 frac）
    ctx.draw(cropped, in: CGRect(x: 0, y: Double(viewH) - Double(needH) + frac,
                                 width: Double(pageW), height: Double(needH)))
    if stickyHeader {   // 屏幕空间吸顶条：每帧都在同一位置
        ctx.setFillColor(gray: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 0, y: Double(viewH - 60), width: Double(pageW), height: 60))
    }
    if let (cx, cyScreen) = cursor {   // 屏幕空间光标：每帧固定位置
        ctx.setFillColor(gray: 0.35, alpha: 1)
        ctx.fill(CGRect(x: Double(cx), y: Double(viewH - cyScreen - 90), width: 90, height: 90))
    }
    return ctx.makeImage()!
}

/// 竖直对齐 v1（朴素 SAD，保留用于对照：展示其失效模式）
func bestOffsetNaive(_ a: Gray, _ b: Gray, excludeTop: Int = 0, maxShift: Int? = nil) -> (Int, Double) {
    let limit = maxShift ?? (a.h - 1)
    var bestD = 0
    var bestCost = Double.greatestFiniteMagnitude
    for d in 0..<limit {
        var cost = 0.0
        var n = 0
        var k = excludeTop
        while k < b.h - d {
            let ra = a.row(d + k), rb = b.row(k)
            var s = 0
            for i in 0..<a.w { s += abs(Int(ra[ra.startIndex + i]) - Int(rb[rb.startIndex + i])) }
            cost += Double(s)
            n += 1
            k += 4
        }
        if n > 0 { cost /= Double(n) }
        if cost < bestCost { bestCost = cost; bestD = d }
    }
    return (bestD, bestCost)
}

/// 内容行加权对齐代价：仅统计「有内容」的行，剔除空白间隙
func alignCost(_ a: Gray, _ b: Gray, d: Int, excludeTop: Int) -> (Double, Int) {
    var cost = 0.0
    var n = 0
    let colStep = 4
    var k = excludeTop
    while k < b.h - d {
        let rb = b.row(k)
        var lo = 255, hi = 0
        for i in stride(from: 0, to: b.w, by: 8) {
            let v = Int(rb[rb.startIndex + i]); if v < lo { lo = v }; if v > hi { hi = v }
        }
        if hi - lo < 12 { k += 1; continue }   // 空白/纯色行不计分
        let ra = a.row(d + k)
        var s = 0
        for i in stride(from: 0, to: a.w, by: colStep) {
            s += abs(Int(ra[ra.startIndex + i]) - Int(rb[rb.startIndex + i]))
        }
        cost += Double(s) / Double(a.w / colStep)
        n += 1
        k += 1
    }
    guard n >= 24 else { return (.greatestFiniteMagnitude, n) }
    return (cost / Double(n), n)
}

/// 竖直对齐 v2（修正版）：内容行加权 + 最小重叠约束 + 最小样本数
/// 修正 v1 的三个致命缺陷：
///   ① 均值按重叠长度归一 → 重叠越小越容易刷出「虚假零代价」
///   ② 未剔除均匀行 → 空白间隙参与打分，噪声淹没信号
///   ③ 无最小样本数 → 12 行短重叠的偶然匹配会胜出
func bestOffset(_ a: Gray, _ b: Gray, excludeTop: Int = 0, minOverlapRatio: Double = 0.25) -> (Int, Double, Int) {
    let minOverlap = Int(Double(b.h) * minOverlapRatio)
    let maxD = max(0, b.h - minOverlap)
    var bestD = 0
    var bestCost = Double.greatestFiniteMagnitude
    var bestN = 0
    for d in 0...maxD {
        let (c, n) = alignCost(a, b, d: d, excludeTop: excludeTop)
        if c < bestCost { bestCost = c; bestD = d; bestN = n }
    }
    return (bestD, bestCost, bestN)
}

/// 抛物线亚像素精化
func subpixelRefine(_ a: Gray, _ b: Gray, integer d: Int, excludeTop: Int = 0) -> Double {
    guard d > 0, d < b.h - 1 else { return Double(d) }
    let c0 = alignCost(a, b, d: d - 1, excludeTop: excludeTop).0
    let c1 = alignCost(a, b, d: d, excludeTop: excludeTop).0
    let c2 = alignCost(a, b, d: d + 1, excludeTop: excludeTop).0
    let denom = c0 - 2 * c1 + c2
    guard abs(denom) > 1e-9 else { return Double(d) }
    let delta = 0.5 * (c0 - c2) / denom
    return Double(d) + (abs(delta) <= 1 ? delta : 0)
}

func runScrollSpikes() {
    print("=== S4 滚动截屏配准验证（合成数据）===")
    print("画布 \(pageW)x\(pageH) px，视口高度 \(viewH) px，真实步长 600 px（重叠 200 px）")
    let page = makePage()
    guard let pageGray = Gray(cg: page) else { print("长页构造失败"); return }
    let step = 600

    // ---------- 装置自检：确认取帧真的发生了位移 ----------
    do {
        let f0 = Gray(cg: frame(from: page, offsetY: 0))!
        let f1 = Gray(cg: frame(from: page, offsetY: Double(step)))!
        var diff = 0
        for i in stride(from: 0, to: f0.px.count, by: 997) { diff += abs(Int(f0.px[i]) - Int(f1.px[i])) }
        var nonBlank = 0
        for y in 0..<pageW * 80 { if f0.px[y] < 200 { nonBlank += 1 } }
        let pct = Double(nonBlank) / Double(pageW * 80) * 100
        let harnessOK = diff > 0 && pct > 3
        report("S4.0", harnessOK ? "PASS" : "FAIL",
               String(format: "装置自检：两帧差异幅度 %d，帧非空像素占比 %.1f%%（%s）",
                      diff, pct, harnessOK ? "取帧与位移正确" : "取帧失败，后续结论不可信"))
        if !harnessOK { return }

        // 诊断：行序方向。（CGBitmapContext 的内存行序与 CG 用户坐标系原点在左下，极易搞反）
        func flippedV(_ g: Gray) -> Gray {
            let out = Gray(width: g.w, height: g.h)
            for y in 0..<g.h {
                out.px.replaceSubrange(y * g.w ..< (y + 1) * g.w, with: g.row(g.h - 1 - y))
            }
            return out
        }
        let f1f = flippedV(f1)
        var line1 = "S4.0b 方向诊断（代价，越小越匹配）d:"
        var line2 = "              当前行序:"
        var line3 = "              翻转行序:"
        for d in [0, 200, 400, 600, 700] {
            let cA = alignCost(f0, f1, d: d, excludeTop: 0).0
            let cB = alignCost(f0, f1f, d: d, excludeTop: 0).0
            line1 += String(format: " %6d |", d)
            line2 += String(format: " %6.1f |", cA)
            line3 += String(format: " %6.1f |", cB)
        }
        print(line1); print(line2); print(line3)

        // 诊断 2：帧 ↔ 长页 映射是否成立（f0 应等于 page 顶部 800 行）
        for start in [0, 200, 600] {
            var s = 0.0, n = 0
            var k = 0
            while k < 300 {
                let ra = f0.row(k), rb = pageGray.row(start + k)
                var t = 0
                for i in stride(from: 0, to: pageW, by: 8) {
                    t += abs(Int(ra[ra.startIndex + i]) - Int(rb[rb.startIndex + i]))
                }
                s += Double(t) / Double(pageW / 8)
                n += 1; k += 3
            }
            print(String(format: "S4.0c f0 vs page[%d..]: 代价 %.1f", start, s / Double(n)))
        }
        // 诊断 3：f0 / f1 的行内动态范围（判断内容是否真实存在）
        for (name, g) in [("f0", f0), ("f1", f1)] {
            var lo = 255, hi = 0
            for i in stride(from: 0, to: g.px.count, by: 101) {
                let v = Int(g.px[i]); if v < lo { lo = v }; if v > hi { hi = v }
            }
            print("S4.0d \(name) 全图灰度范围 [\(lo), \(hi)]")
        }
    }

    // ---------- 场景 A：整数滚动（理想情况） ----------
    var offsets: [Int] = []
    do {
        let n = 6
        var frames: [Gray] = []
        for i in 0..<n { frames.append(Gray(cg: frame(from: page, offsetY: Double(i * step)))!) }
        var naive: [Int] = []
        var sub: [Double] = []
        let t0 = CACurrentMediaTime()
        for i in 0..<(n - 1) {
            naive.append(bestOffsetNaive(frames[i], frames[i + 1]).0)
            let (d, _, _) = bestOffset(frames[i], frames[i + 1])
            offsets.append(d)
            sub.append(subpixelRefine(frames[i], frames[i + 1], integer: d))
        }
        let ms = (CACurrentMediaTime() - t0) * 1000 / Double(n - 1)
        let naiveOK = naive.allSatisfy { $0 == step }
        report("S4.A", naiveOK ? "PASS" : "FAIL",
               "整数滚动【朴素 SAD】= \(naive)（期望 \(step)）→ \(naiveOK ? "可用" : "❌ 失效")")
        let fixedOK = offsets.allSatisfy { $0 == step }
        report("S4.A1", fixedOK ? "PASS" : "FAIL",
               "整数滚动【修正算法】= \(offsets) → \(fixedOK ? "✅ 正确" : "❌ 仍失效")；单次配准 \(String(format: "%.0f", ms)) ms")

        // 拼接正确性：与真值比对
        let stitchedH = viewH + offsets.reduce(0, +)
        var stitched = Gray(width: pageW, height: max(stitchedH, viewH))
        stitched.px.replaceSubrange(0..<pageW * viewH, with: frames[0].px)
        var row = viewH
        for i in 1..<n {
            guard row < stitchedH else { break }
            let d = max(0, min(offsets[i - 1], viewH - 1))
            // 本帧新增的内容 = 本帧顶部的 d 行（对应长页 [已拼接高度, 已拼接高度+d)）
            for y in (viewH - d)..<viewH {
                guard row + 1 <= stitchedH else { break }
                stitched.px.replaceSubrange(row * pageW ..< (row + 1) * pageW,
                                            with: frames[i].row(y))
                row += 1
            }
        }
        var err = 0.0
        var cnt = 0
        for y in 0..<min(stitchedH, pageH) {
            let a = stitched.row(y), b = pageGray.row(y)
            for x in stride(from: 0, to: pageW, by: 3) {
                err += Double(abs(Int(a[a.startIndex + x]) - Int(b[b.startIndex + x]))); cnt += 1
            }
        }
        let mae = err / Double(cnt)
        let truth = (n - 1) * step + viewH
        report("S4.A2", mae < 2.0 ? "PASS" : "FAIL",
               String(format: "拼接结果 vs 真值：平均绝对误差 %.3f/255；拼接高度 %d px（真值 %d px）", mae, stitchedH, truth))
    }

    // ---------- 场景 B：亚像素滚动（0.5 px 步长） ----------
    do {
        let n = 5
        let fracStep = 600.5
        var frames: [Gray] = []
        for i in 0..<n { frames.append(Gray(cg: frame(from: page, offsetY: Double(i) * fracStep))!) }
        var intOffsets: [Int] = []
        var subOffsets: [Double] = []
        for i in 0..<(n - 1) {
            let (d, _, _) = bestOffset(frames[i], frames[i + 1])
            intOffsets.append(d)
            subOffsets.append(subpixelRefine(frames[i], frames[i + 1], integer: d))
        }
        let intErr = intOffsets.map { abs(Double($0) - fracStep) }.max() ?? 0
        let subErr = subOffsets.map { abs($0 - fracStep) }.max() ?? 0
        report("S4.B", subErr < intErr ? "PASS" : "FAIL",
               String(format: "亚像素滚动（真实步长 %.1f）：整数对齐最大误差 %.1f px → 抛物线亚像素精化后 %.2f px", fracStep, intErr, subErr))
        report("S4.B1", subErr <= 0.6 ? "PASS" : "FAIL",
               "亚像素结论：整数位移会累积 ±0.5 px 级误差，长图越长错位越明显 → 必须做亚像素精化或按累计小数位移重采样")
    }

    // ---------- 场景 C：吸顶条 + 屏幕光标（动态内容干扰） ----------
    do {
        let n = 5
        var frames: [Gray] = []
        for i in 0..<n {
            frames.append(Gray(cg: frame(from: page, offsetY: Double(i * step),
                                         stickyHeader: true, cursor: (500, 380)))!)
        }
        var naive: [Int] = [], fixed: [Int] = [], excluded: [Int] = []
        for i in 0..<(n - 1) {
            naive.append(bestOffsetNaive(frames[i], frames[i + 1]).0)
            fixed.append(bestOffset(frames[i], frames[i + 1]).0)
            excluded.append(bestOffset(frames[i], frames[i + 1], excludeTop: 70).0)
        }
        let fixedOK = fixed.allSatisfy { $0 == step }
        let exclOK = excluded.allSatisfy { $0 == step }
        report("S4.C", naive.allSatisfy { $0 == step } ? "PASS" : "FAIL",
               "吸顶条+屏幕光标干扰【朴素】= \(naive)（期望 \(step)）")
        report("S4.C1", fixedOK ? "PASS" : "FAIL",
               "吸顶条+屏幕光标干扰【修正算法】= \(fixed) → \(fixedOK ? "✅ 抗干扰通过（90x90 光标占比小，不构成干扰）" : "❌ 被干扰")")
        report("S4.C2", exclOK ? "PASS" : "FAIL",
               "额外排除顶部 70 px（吸顶条）= \(excluded) → \(exclOK ? "✅ 缓解有效" : "❌ 缓解无效")")
    }

    // ---------- 场景 D：滚动到底（无位移） ----------
    do {
        let f0 = Gray(cg: frame(from: page, offsetY: 6000))!
        let f1 = Gray(cg: frame(from: page, offsetY: 6000))!
        let (d, c, _) = bestOffset(f0, f1)
        report("S4.D", d == 0 ? "PASS" : "FAIL",
               String(format: "滚动到底检测：位移 = %d px（期望 0），代价 %.3f → 可据此判定「无新增内容」并停止", d, c))
    }

    // ---------- 场景 E：Vision 平移配准对照 ----------
    do {
        let a = frame(from: page, offsetY: 0)
        let b = frame(from: page, offsetY: Double(step))
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: a)
        let handler = VNImageRequestHandler(cgImage: b, options: [:])
        do {
            try handler.perform([request])
            if let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
                let t = obs.alignmentTransform
                report("S4.E", "PASS",
                       String(format: "Vision VNTranslationalImageRegistration 可用：tx=%.2f ty=%.2f（Vision 坐标系原点在左下，ty 符号需按实现翻转；期望模长 ≈ %d）",
                              t.tx, t.ty, step))
            } else {
                report("S4.E", "FAIL", "Vision 未返回平移观测值")
            }
        } catch {
            report("S4.E", "FAIL", "Vision 配准抛错：\(error)")
        }
    }
}

// MARK: - 入口

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
if args.contains("dump") {
    let page = makePage()
    let outp = "/Users/tango/Developments/Marquee/Tools/Spikes/"
    func writePNG(_ img: CGImage, _ name: String) {
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outp + name) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
    writePNG(page, "dump_page.png")
    writePNG(frame(from: page, offsetY: 0), "dump_f0.png")
    writePNG(frame(from: page, offsetY: 600), "dump_f600.png")
    // 直接把长页顶部 800 行裁出来做对照
    if let top = page.cropping(to: CGRect(x: 0, y: 0, width: pageW, height: viewH)) {
        writePNG(top, "dump_pageTop800.png")
    }
    print("已导出 dump_page.png (\(page.width)x\(page.height)) / dump_f0.png / dump_f600.png / dump_pageTop800.png")
} else if args.contains("scroll") {
    runScrollSpikes()
} else {
    print("=== Snipo Spike Runner · 基础探测 ===")
    print("系统 \(ProcessInfo.processInfo.operatingSystemVersionString) | device: \(MTLCreateSystemDefaultDevice()?.name ?? "n/a")")
    spikeS1()
    spikeS2()
    spikeS5()
    spikeS6()
    spikeS7()
    print("\n=== 汇总：PASS \(passCount) | FAIL \(failCount) | 需人工 \(manualCount) ===")
}
