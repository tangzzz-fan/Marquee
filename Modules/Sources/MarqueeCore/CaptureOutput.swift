import CoreGraphics
import Foundation

/// 采集流程的收尾工作：PNG 编码 → 写剪贴板 → 汇总度量。
///
/// 单独抽出来的理由：全屏 / 区域 / 窗口三条流程的收尾**必须完全一致** ——
/// 性能预算与"写的是原始 PNG 而不是 NSImage 往返"这两件事都落在这里，
/// 复制三份迟早会有一份被改坏，而且改坏之后只有某一条路径出问题，极难察觉。
@MainActor
public struct CaptureOutput {

    private let clipboard: ClipboardWriting
    private let clock: MonotonicClock

    public init(clipboard: ClipboardWriting, clock: MonotonicClock = SystemMonotonicClock()) {
        self.clipboard = clipboard
        self.clock = clock
    }

    /// 开始计时。放在流程最前面，这样"按下快捷键 → 剪贴板可用"是端到端耗时。
    public func begin() -> Double {
        clock.now()
    }

    /// 收尾。
    ///
    /// - Parameter inline: 覆盖层里**就地画**的标注。非空时先把它栅格化到图上，
    ///   再编码写剪贴板 —— 剪贴板里必须是一张**已经合并好**的图，
    ///   不能只有底图、把标注留在别处（用户粘贴出去的是他自己贴的图，不是对象）。
    public func finish(_ image: CGImage,
                       startedAt: Double,
                       save: CaptureSaveRequest? = nil,
                       inline: InlineAnnotations? = nil) -> CaptureOutcome {
        let flatten: CGImage
        if let inline, !inline.isEmpty {
            let scaled = inline.scaled(toPixelSize: CGSize(width: image.width, height: image.height))
            let document = AnnotationDocument(pixelSize: CGSize(width: image.width, height: image.height),
                                              annotations: scaled)
            guard let merged = AnnotationRasterizer.image(document: document, source: image) else {
                // ⚠️ 这里**必须失败**，不能"回退成原图"。
                // 标注里可能有打码/模糊 —— 静默交出一张没打码的原图，
                // 是把用户以为已经遮住的内容原样发出去。宁可这次截图作废。
                return .failed(CaptureFailure(message: "标注没能合成到截图上，这次截图已放弃（避免交出未处理的图）"))
            }
            flatten = merged
        } else {
            flatten = image
        }

        guard let png = ImageEncoding.pngData(from: flatten) else {
            return .failed(CaptureFailure(message: "截图编码为 PNG 失败"))
        }
        // 剪贴板先写。落盘失败不能把已经能粘贴的图弄没。
        clipboard.writePNG(png)

        var savedFilePath: String?
        var saveFailureMessage: String?
        var savedSequence: Int?
        if let save {
            switch ScreenshotArchiver.write(flatten, request: save) {
            case .success(let result):
                savedFilePath = result.url.path
                savedSequence = result.sequenceUsed
            case .failure(let failure):
                saveFailureMessage = failure.message
            }
        }

        return .copiedToClipboard(CaptureMetrics(
            pixelSize: CGSize(width: flatten.width, height: flatten.height),
            pngByteCount: png.count,
            elapsedMilliseconds: (clock.now() - startedAt) * 1000,
            savedFilePath: savedFilePath,
            saveFailureMessage: saveFailureMessage,
            savedSequence: savedSequence,
            image: flatten
        ))
    }

    /// 采集抛错时的统一处理。
    ///
    /// `grantedJustNow` 为真说明权限是这次刚给的 —— 那么失败几乎一定是
    /// "权限要重启进程才生效"（SPIKE A5），必须把话说到位，否则用户会以为应用坏了。
    public func failure(_ error: any Error, grantedJustNow: Bool) -> CaptureOutcome {
        if grantedJustNow {
            return .failed(CaptureFailure(message: "已获得屏幕录制权限。请退出并重新打开 Marquee，权限才会生效"))
        }
        return .failed(CaptureFailure(message: "截图失败：\(error.localizedDescription)"))
    }
}
