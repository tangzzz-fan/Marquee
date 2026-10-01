import CoreGraphics

/// 尺寸档那一小格**画成什么样** —— 覆盖层与编辑器**共用同一套**。
///
/// ## 为什么要抽出来
///
/// 同一个功能在两个地方各画各的，迟早出现"两处看着不一样"，而那种差别
/// 只有把两个界面摆在一起才看得出来。真实的复现点是：覆盖层里三档是
/// 线宽 / 打码强度 / 字号，编辑器里也是这三种 —— 形状与大小的规则必须只有一份。
///
/// ## 为什么按「档位序号」而不是按「数值」
///
/// 原先是 `4 + value * 1.4` 再夹到格子上限。线宽 2/4/8 画出来还算分得开，
/// 但打码强度那三档是 **4/8/16**：算出来 9.6 / 15.2 / 16 ——
/// **后两档几乎一样大**。用户点了"最强"却看不出任何变化，
/// 只会以为那一档没生效（而它其实生效了，只是画得看不出区别）。
///
/// 按序号均分之后，三档彼此**总是等距**：换一组数值（2/4/8 或 4/8/16 或 24/36/56）
/// 画出来完全一样。这也让"档位"和"数值"这两件事彻底解耦 ——
/// 数值是给导出算的，画多大是给人看的。
public enum SizeSwatchGeometry {

    /// 三个字的形状。
    public enum Shape: Equatable, Sendable {
        case circle
        case square
        /// 一个字母「A」—— 只有它才说得清"这是在调字的大小"。
        case letter
    }

    /// 这一组尺寸代表什么 → 画成什么形状。
    public static func shape(for meaning: OverlaySizeMeaning) -> Shape {
        switch meaning {
        case .lineWidth: .circle
        case .redactionStrength: .square
        case .fontSize: .letter
        }
    }

    /// 第 `index` 档占格子的多大比例（0…1）。越靠后越大。
    ///
    /// 线性均分：三档是 0.36 / 0.61 / 0.86 —— 相邻两档差 0.25，
    /// 最大的约是最小的 2.4 倍，肉眼一眼分得出。
    public static func relativeSide(index: Int, of count: Int) -> CGFloat {
        // 只有一档就无所谓"比大小"，取一个偏大的固定值
        guard count > 1 else { return 0.86 }
        let clamped = min(max(index, 0), count - 1)
        return 0.36 + CGFloat(clamped) / CGFloat(count - 1) * 0.50
    }
}
