import SwiftUI

struct MarkdownMessageView: View {
    let message: String
    let fontSize: Double
    var lineLimit: Int?
    var showsImages: Bool = true
    var imageMaxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let source):
                    if let attributed = attributedMarkdown(from: source) {
                        markdownText(attributed)
                    }
                case .image(let url, let altText):
                    if showsImages {
                        Link(destination: url) {
                            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                                switch phase {
                                case .empty:
                                    placeholderImage(iconName: "photo")
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: imageMaxHeight, alignment: .leading)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                case .failure:
                                    placeholderImage(iconName: "photo.slash", caption: altText)
                                @unknown default:
                                    placeholderImage(iconName: "photo")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var parsedBlocks: [MarkdownBlock] {
        MarkdownParser.blocks(from: displayMessage)
    }

    private var displayMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lineLimit else { return trimmed }
        return Self.prefix(trimmed, maxLines: lineLimit)
    }

    @ViewBuilder
    private func markdownText(_ attributed: AttributedString) -> some View {
        Text(attributed)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func attributedMarkdown(from source: String) -> AttributedString? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let parsed = (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)

        return applyingDetectedLinks(to: parsed, source: source)
    }

    private static func prefix(_ source: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > maxLines else { return source }
        lines = Array(lines.prefix(maxLines))
        return lines.map(String.init).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyingDetectedLinks(to attributed: AttributedString, source: String) -> AttributedString {
        var attributed = attributed
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in detector.matches(in: source, options: [], range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: source),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }

    @ViewBuilder
    private func placeholderImage(iconName: String, caption: String? = nil) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.gray.opacity(0.12))
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: imageMaxHeight, alignment: .leading)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: max(11, fontSize - 1)))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(10)
            }
    }
}

private enum MarkdownBlock {
    case text(String)
    case image(URL, altText: String)
}

private enum MarkdownParser {
    private static let imageRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
    }()

    static func blocks(from message: String) -> [MarkdownBlock] {
        let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
        let matches = imageRegex.matches(in: message, options: [], range: fullRange)
        guard !matches.isEmpty else { return [.text(message)] }

        var blocks: [MarkdownBlock] = []
        var currentIndex = message.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: message) else { continue }
            if currentIndex < matchRange.lowerBound {
                appendTextBlock(String(message[currentIndex..<matchRange.lowerBound]), to: &blocks)
            }

            let altText = Range(match.range(at: 1), in: message).map { String(message[$0]) } ?? ""
            let rawTarget = Range(match.range(at: 2), in: message).map { String(message[$0]) } ?? ""

            if let url = makeImageURL(from: rawTarget) {
                blocks.append(.image(url, altText: altText))
            } else {
                appendTextBlock(String(message[matchRange]), to: &blocks)
            }

            currentIndex = matchRange.upperBound
        }

        if currentIndex < message.endIndex {
            appendTextBlock(String(message[currentIndex...]), to: &blocks)
        }

        return blocks.isEmpty ? [.text(message)] : blocks
    }

    private static func appendTextBlock(_ text: String, to blocks: inout [MarkdownBlock]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blocks.append(.text(text))
    }

    private static func makeImageURL(from rawTarget: String) -> URL? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
