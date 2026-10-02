import AppKit
import ImageIO
import MarqueeCore
import MarqueeHistory

/// 菜单栏里的「最近截图」面板（ticket 16）。
///
/// ## 为什么是弹层而不是一个图库窗口
///
/// 要解决的是"**刚**截的图找不到了"。一个独立图库窗口会带来窗口管理、搜索、分组、
/// 拖拽导出…… 那是另一个产品。这里只做一层列表：看得见最近几张、点一下就能用、
/// 不要的能删掉。
///
/// ## 缩略图直接读原图，不走"先加载整图再缩"
///
/// 一张 5K 的全屏 PNG 解码出来是几十 MB，二十张就是几百 MB ——
/// 面板一打开就会卡住。`CGImageSourceCreateThumbnailAtIndex` 是为此设计的：
/// 它只解码到目标尺寸，代价与目标大小成正比，与源图大小无关。
/// （ticket 的验收项里有"面板打开速度实测"，这条是能不能达标的关键。）
@MainActor
final class RecentCapturesPanelController: NSViewController {

    struct Actions {
        /// 复制到剪贴板
        var onCopy: (CaptureHistoryEntry) -> Void
        /// 重新进编辑器（用历史里的**原图 + 标注**）
        var onEdit: (CaptureHistoryEntry) -> Void
        /// 删掉这一条（连文件）
        var onDelete: (CaptureHistoryEntry) -> Void
    }

    private static let thumbnailSize = CGSize(width: 84, height: 56)
    /// 一次最多列几条。再多性能与"看得过来"两方面都不划算。
    private static let maximumRows = 12

    private let store: CaptureHistoryStore
    private let actions: Actions
    private let list = NSStackView()

    init(store: CaptureHistoryStore, actions: Actions) {
        self.store = store
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecentCapturesPanelController 只支持代码创建")
    }

    override func loadView() {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 360),
            container.heightAnchor.constraint(equalToConstant: 380),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -2),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// 重新读一遍索引并重建列表。
    func reload() {
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let entries = Array(store.entries().prefix(Self.maximumRows))
        guard !entries.isEmpty else {
            list.addArrangedSubview(emptyLabel())
            return
        }
        for entry in entries {
            list.addArrangedSubview(row(for: entry))
        }
        // 免费版把配额说清楚（ticket 31）。
        //
        // ⚠️ **只在这里放一行小字，不弹卡片。** 截图是高频动作 ——
        // 每截一张都弹一次"要不要升级"等于自杀（见 `docs/MAS-AND-MONETIZATION.md`
        // §「被挡住时的界面行为」第 3 条：只有三个**入口**会弹卡片，配额类不弹）。
        if let limit = store.limit {
            list.addArrangedSubview(footerLabel(limit: limit))
        }
    }

    /// 免费版的历史配额说明。
    private func footerLabel(limit: Int) -> NSView {
        let label = NSTextField(labelWithString:
            L10n.t("免费版只保留最近 \(limit) 张 · 升级到 Pro 可保留全部"))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 320
        return label
    }

    // MARK: - 行

    private func emptyLabel() -> NSView {
        let label = NSTextField(labelWithString: L10n.t("还没有截图。按 ⌃Q 截一张，它会出现在这里。"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 320
        return label
    }

    private func row(for entry: CaptureHistoryEntry) -> NSView {
        // 缩略图本身就是"复制"按钮：点图就该拿到图，这是最自然的那一下。
        let thumbnail = NSButton(title: "", target: self, action: #selector(copyEntry(_:)))
        thumbnail.bezelStyle = .regularSquare
        thumbnail.isBordered = false
        thumbnail.imagePosition = .imageOnly
        thumbnail.image = Self.thumbnail(at: store.directoryURL.appendingPathComponent(entry.originalFileName))
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        thumbnail.toolTip = L10n.t("点击复制到剪贴板")
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailSize.width),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height),
        ])

        let title = NSTextField(labelWithString: Self.describe(entry))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let subtitle = NSTextField(labelWithString: Self.describeDetail(entry))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let edit = smallButton(L10n.t("编辑"), action: #selector(editEntry(_:)), tag: entry.id)
        edit.toolTip = L10n.t("在编辑器里打开（原有的标注仍可编辑）")
        let remove = smallButton(L10n.t("删除"), action: #selector(deleteEntry(_:)), tag: entry.id)
        remove.toolTip = L10n.t("从历史里删掉（连磁盘上的文件一起清）")

        let row = NSStackView(views: [thumbnail, texts, NSView(), edit, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 338).isActive = true
        return row
    }

    private func smallButton(_ title: String, action: Selector, tag: UUID) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        // `tag` 是 `Int`、装不下 UUID；`NSButton` 又只有 target-action（不能塞闭包）。
        // 所以用 `identifier` 捎带 —— 反正读回来时也要按 id 找条目（见 `entry(from:)`）。
        button.identifier = NSUserInterfaceItemIdentifier(tag.uuidString)
        return button
    }

    // MARK: - 动作

    /// 从按钮的标识里还原出条目。
    ///
    /// 为什么不按下标去找：列表会随删除/新增重建，**下标会在用户点下去之前变** ——
    /// 那会导致"点了删除，删掉的是另一条"。id 不会变。
    private func entry(from sender: NSButton) -> CaptureHistoryEntry? {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return nil }
        return store.entries().first { $0.id == id }
    }

    @objc private func copyEntry(_ sender: NSButton) {
        guard let entry = entry(from: sender) else { return }
        actions.onCopy(entry)
    }

    @objc private func editEntry(_ sender: NSButton) {
        guard let entry = entry(from: sender) else { return }
        actions.onEdit(entry)
    }

    @objc private func deleteEntry(_ sender: NSButton) {
        guard let entry = entry(from: sender) else { return }
        actions.onDelete(entry)
        reload()
    }

    // MARK: - 文案

    private static func describe(_ entry: CaptureHistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"   // L10N-EXEMPT: DateFormatter 的格式串，该走 dateFormatFromTemplate，不是文案
        return formatter.string(from: entry.capturedAt)
    }

    private static func describeDetail(_ entry: CaptureHistoryEntry) -> String {
        let size = "\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))"
        guard entry.annotationCount > 0 else { return "\(size) px" }
        return L10n.t("\(size) px · \(entry.annotationCount) 个标注")
    }

    /// 按目标尺寸解码，**不解码整图**（见类型文档）。
    private static func thumbnail(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(thumbnailSize.width, thumbnailSize.height) * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: thumbnailSize)
    }
}
