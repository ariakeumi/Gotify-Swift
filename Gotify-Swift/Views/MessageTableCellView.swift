import AppKit
import ImageIO

/// One layout is shared by the table's height delegate and its reusable native cell.
@MainActor
final class MessageRowLayout {
    enum Block {
        case text(NSAttributedString, NSRect)
        case image(URL, String, NSRect)
    }

    let messageID: Int
    let appName: String
    let title: NSAttributedString
    let titleFrame: NSRect
    let metadata: NSAttributedString
    let metadataFrame: NSRect
    let blocks: [Block]
    let toggleTitle: String?
    let toggleFrame: NSRect
    let height: CGFloat

    init(message: GotifyMessage, content: MarkdownContent?, expanded: Bool, appName: String, fontSize: CGFloat, width: CGFloat) {
        messageID = message.id
        self.appName = appName
        let textX: CGFloat = 68
        let textWidth = max(1, width - textX - 24)
        title = NSAttributedString(
            string: message.title.isEmpty ? L10n.text("message.no_title") : message.title,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize + 2, weight: .semibold), .foregroundColor: NSColor.labelColor]
        )
        titleFrame = NSRect(x: textX, y: 8, width: textWidth, height: Self.textHeight(title, width: textWidth))
        var y = titleFrame.maxY + 6
        var blocks: [Block] = []
        let sourceBlocks = content?.blocks ?? [.text(AttributedString(MarkdownContent.previewSource(message.message, maxLines: MarkdownContent.previewLineLimit).text))]
        for block in sourceBlocks {
            if !blocks.isEmpty { y += 8 }
            switch block {
            case .text(let attributed):
                let text = Self.nativeText(attributed, fontSize: fontSize)
                let frame = NSRect(x: textX, y: y, width: textWidth, height: Self.textHeight(text, width: textWidth))
                blocks.append(.text(text, frame))
                y = frame.maxY
            case .image(let url, let altText):
                let frame = NSRect(x: textX, y: y, width: textWidth, height: expanded ? 280 : 180)
                blocks.append(.image(url, altText, frame))
                y = frame.maxY
            }
        }
        self.blocks = blocks
        let captionFont = NSFont.systemFont(ofSize: max(11, fontSize - 2))
        var captions = [appName]
        if let priority = message.priority { captions.append("P\(priority)") }
        if let date = message.date { captions.append(date.formatted(date: .abbreviated, time: .shortened)) }
        metadata = NSAttributedString(string: captions.joined(separator: "   "), attributes: [
            .font: captionFont, .foregroundColor: NSColor.secondaryLabelColor
        ])
        metadataFrame = NSRect(x: textX, y: y + 6, width: textWidth, height: Self.textHeight(metadata, width: textWidth))
        y = metadataFrame.maxY
        let canExpand = message.markdownPreview?.isTruncated
            ?? MarkdownContent.previewSource(message.message, maxLines: MarkdownContent.previewLineLimit).isTruncated
        toggleTitle = canExpand ? L10n.text(expanded ? "message.collapse" : "message.expand") : nil
        toggleFrame = NSRect(x: textX, y: y + 6, width: textWidth, height: ceil(captionFont.boundingRectForFont.height) + 4)
        if canExpand { y = toggleFrame.maxY }
        height = max(50, y + 8)
    }

    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return max(1, ceil(manager.usedRect(for: container).height))
    }

    private static func nativeText(_ attributed: AttributedString, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : NSFont.systemFont(ofSize: fontSize)
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: run.link == nil ? NSColor.labelColor : NSColor.linkColor
            ]
            if let link = run.link { attributes[.link] = link }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: String(attributed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

final class MessageTableCellView: NSTableCellView {
    private var rowLayout: MessageRowLayout?
    private let iconButton = MessageIconButton()
    private let divider = NSBox()
    private var contentViews: [NSView] = []
    private var onToggle: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        addSubview(iconButton)
        divider.boxType = .separator
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(layout: MessageRowLayout, icon: NSImage?, highlighted: Bool, isLast: Bool, onDelete: @escaping () -> Void, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        iconButton.appIcon = icon
        iconButton.onDelete = onDelete
        layer?.backgroundColor = (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.14) : .clear).cgColor
        divider.isHidden = isLast
        guard rowLayout !== layout else { return }
        rowLayout = layout
        contentViews.forEach { $0.removeFromSuperview() }
        contentViews.removeAll()
        addText(layout.title, frame: layout.titleFrame, selectable: false)
        for block in layout.blocks {
            switch block {
            case .text(let text, let frame):
                addText(text, frame: frame, selectable: true)
            case .image(let url, let altText, let frame):
                let image = MessageImageButton(url: url, altText: altText)
                image.frame = frame
                addContent(image)
            }
        }
        addText(layout.metadata, frame: layout.metadataFrame, selectable: false)
        if let title = layout.toggleTitle {
            let button = NSButton(title: title, target: self, action: #selector(toggleMessage))
            button.isBordered = false
            button.contentTintColor = .linkColor
            button.alignment = .left
            button.font = layout.metadata.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            button.frame = layout.toggleFrame
            button.sizeToFit()
            button.frame.origin = layout.toggleFrame.origin
            addContent(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        iconButton.frame = NSRect(x: 24, y: 8, width: 34, height: 34)
        divider.frame = NSRect(x: 24, y: bounds.height - 1, width: max(0, bounds.width - 48), height: 1)
    }

    private func addText(_ text: NSAttributedString, frame: NSRect, selectable: Bool) {
        if selectable {
            let view = NSTextView(frame: frame)
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
            view.isVerticallyResizable = false
            view.textStorage?.setAttributedString(text)
            view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
            addContent(view)
        } else {
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = text
            label.frame = frame
            addContent(label)
        }
    }

    private func addContent(_ view: NSView) {
        contentViews.append(view)
        addSubview(view)
    }

    @objc private func toggleMessage() { onToggle?() }
}

private final class MessageIconButton: NSButton {
    var appIcon: NSImage? { didSet { updateImage() } }
    var onDelete: (() -> Void)?
    private var isHovering = false
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        target = self
        action = #selector(deleteMessage)
        setAccessibilityLabel(L10n.text("message.delete"))
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        isHovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateImage()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; updateImage() }
    override func mouseExited(with event: NSEvent) { isHovering = false; updateImage() }

    private func updateImage() {
        let symbol = NSImage(systemSymbolName: isHovering ? "trash" : "bell.badge", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: isHovering ? 14 : 13, weight: .semibold))
        image = isHovering ? symbol : appIcon ?? symbol
        contentTintColor = isHovering || appIcon == nil ? .secondaryLabelColor : nil
        layer?.backgroundColor = (isHovering ? NSColor.controlBackgroundColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.2)).cgColor
    }

    @objc private func deleteMessage() { onDelete?() }
}

final class MessageFooterView: NSTableCellView {
    private let spinner = NSProgressIndicator()
    private let button = NSButton()
    private var onLoad: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        addSubview(spinner)
        button.isBordered = false
        button.target = self
        button.action = #selector(loadMore)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(loading: Bool, error: Bool, onLoad: @escaping () -> Void) {
        self.onLoad = onLoad
        button.title = L10n.text(error ? "content.retry_loading" : "content.load_more")
        button.isHidden = loading
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        button.frame = bounds.insetBy(dx: 16, dy: 4)
    }

    @objc private func loadMore() { onLoad?() }
}

private final class MessageImageButton: NSButton {
    private let url: URL
    private let preview = NSImageView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var downloadTask: Task<Void, Never>?

    init(url: URL, altText: String) {
        self.url = url
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(openImage)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignLeft
        addSubview(preview)
        placeholder.stringValue = "◻︎"
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        addSubview(placeholder)
        setAccessibilityLabel(altText.isEmpty ? url.absoluteString : altText)
        downloadTask = Task { [weak self] in
            do {
                let downloaded = try await Self.downloadPreview(from: url)
                try Task.checkCancellation()
                guard let self else { return }
                switch downloaded {
                case .thumbnail(let image):
                    self.preview.image = NSImage(cgImage: image, size: .zero)
                case .original(let data):
                    guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                    self.preview.image = image
                }
                self.placeholder.isHidden = true
            } catch {
                guard !Task.isCancelled else { return }
                self?.placeholder.stringValue = altText.isEmpty ? "◻︎" : altText
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { downloadTask?.cancel() }

    override func layout() {
        super.layout()
        preview.frame = bounds
        placeholder.frame = NSRect(x: 8, y: bounds.midY - 20, width: max(0, bounds.width - 16), height: 40)
    }

    @objc private func openImage() { NSWorkspace.shared.open(url) }

    private enum DownloadedPreview: Sendable {
        case thumbnail(CGImage)
        case original(Data)
    }

    @concurrent
    private static func downloadPreview(from url: URL) async throws -> DownloadedPreview {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1536
              ] as CFDictionary) {
            return .thumbnail(image)
        }
        return .original(data)
    }
}
