import Foundation

nonisolated struct MarkdownContent: Sendable {
    enum Block: Sendable {
        case text(AttributedString)
        case image(URL, altText: String)
    }

    static let previewLineLimit = 6
    static let previewCharacterLimit = 2_000
    let blocks: [Block]
    let isTruncated: Bool

    init(message: String, lineLimit: Int?) {
        if let lineLimit {
            let preview = Self.previewSource(message, maxLines: lineLimit)
            blocks = Self.parse(preview.text)
            isTruncated = preview.isTruncated
        } else {
            blocks = Self.parse(message.trimmingCharacters(in: .whitespacesAndNewlines))
            isTruncated = false
        }
    }

    @concurrent
    static func prepare(message: String, lineLimit: Int?) async throws -> Self {
        try Task.checkCancellation()
        let content = Self(message: message, lineLimit: lineLimit)
        try Task.checkCancellation()
        return content
    }

    @concurrent
    static func preparePreviews(for messages: [String]) async throws -> [Self] {
        try messages.map { message in
            try Task.checkCancellation()
            return Self(message: message, lineLimit: previewLineLimit)
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let imageRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
    }()

    private static func parse(_ message: String) -> [Block] {
        let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
        let matches = imageRegex.matches(in: message, options: [], range: fullRange)
        var blocks: [Block] = []
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

        if !blocks.isEmpty { return blocks }
        return attributedMarkdown(from: message).map { [.text($0)] } ?? []
    }

    private static func appendTextBlock(_ text: String, to blocks: inout [Block]) {
        guard let attributed = attributedMarkdown(from: text) else { return }
        blocks.append(.text(attributed))
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

    private static func attributedMarkdown(from source: String) -> AttributedString? {
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

    // Bound both parsing and text layout: a notification may be one enormous line.
    static func previewSource(_ message: String, maxLines: Int) -> (text: String, isTruncated: Bool) {
        let source = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxLines > 0 else { return ("", !source.isEmpty) }
        var end = source.startIndex
        var lines = 1
        var characters = 0
        while end < source.endIndex && characters < previewCharacterLimit {
            if source[end].isNewline {
                guard lines < maxLines else { break }
                lines += 1
            }
            source.formIndex(after: &end)
            characters += 1
        }
        let isTruncated = end < source.endIndex
        let text = String(source[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text + (isTruncated ? "…" : ""), isTruncated)
    }

    private static func applyingDetectedLinks(to attributed: AttributedString, source: String) -> AttributedString {
        var attributed = attributed
        guard let linkDetector else { return attributed }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in linkDetector.matches(in: source, options: [], range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: source),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}
