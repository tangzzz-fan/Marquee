import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore

@Suite("放大镜接缝")
struct MagnifierSeamTests {

    @Test("取一屏像素：走现成的采集器，输出尺寸等于该屏物理像素")
    func lensFrameUsesCapturer() async {
        let provider = CapturerLensProvider(capturer: RecordingCapturer())

        let frame = await provider.lensFrame(for: TestDisplays.retina)

        #expect(frame?.display == TestDisplays.retina)
        #expect(frame?.image.width == 2880, "1440 点 × 2x = 2880 像素")
        #expect(frame?.image.height == 1800)
    }

    @Test("采集失败返回 nil 而不是抛 —— 放大镜是锦上添花，不能拖垮截屏主流程")
    func lensFrameFailsSoftly() async {
        let provider = CapturerLensProvider(
            capturer: RecordingCapturer(failure: StubCaptureError(message: "权限被撤了"))
        )

        let frame = await provider.lensFrame(for: TestDisplays.retina)

        #expect(frame == nil)
    }
}
