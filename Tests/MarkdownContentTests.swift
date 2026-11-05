import Foundation

@main
private struct MarkdownContentTests {
    static func text(in content: MarkdownContent) -> String {
        content.blocks.compactMap { block in
            if case .text(let value) = block { return String(value.characters) }
            return nil
        }.joined()
    }

    static func main() async throws {
        let short = "First line\n**Second** line"
        let preview = MarkdownContent(message: short, lineLimit: 6)
        precondition(!preview.isTruncated && text(in: preview) == "First line\nSecond line")
        let sixLines = (1...6).map(String.init).joined(separator: "\n")
        precondition(!MarkdownContent(message: sixLines, lineLimit: 6).isTruncated)
        let sevenLines = MarkdownContent(message: sixLines + "\n7", lineLimit: 6)
        precondition(sevenLines.isTruncated && text(in: sevenLines) == sixLines + "…")
        precondition(MarkdownContent(message: " \n ", lineLimit: 6).blocks.isEmpty)
        print("PASS: short Markdown, exact line boundary, truncation, empty content")

        let limit = MarkdownContent.previewCharacterLimit
        let exact = String(repeating: "a", count: limit)
        precondition(!MarkdownContent(message: exact, lineLimit: 6).isTruncated)
        let long = String(repeating: "a", count: 100_000)
        let bounded = MarkdownContent(message: long, lineLimit: 6)
        precondition(bounded.isTruncated && text(in: bounded) == exact + "…")
        let full = try await MarkdownContent.prepare(message: long, lineLimit: nil)
        precondition(!full.isTruncated && text(in: full) == long)
        let unicode = String(repeating: "👨‍👩‍👧‍👦", count: limit + 1)
        let unicodePreview = MarkdownContent(message: unicode, lineLimit: 6)
        precondition(unicodePreview.isTruncated && text(in: unicodePreview) == String(unicode.prefix(limit)) + "…")
        print("PASS: long single line is bounded, full text remains available, Unicode stays intact")

        let image = MarkdownContent(message: "Hello\n![sample](https://example.com/image.png)\nEnd", lineLimit: 6)
        precondition(image.blocks.count == 3 && !image.isTruncated)
        guard case .image(let url, let alt) = image.blocks[1] else { fatalError("Missing image") }
        precondition(url.absoluteString == "https://example.com/image.png" && alt == "sample")
        let batch = try await MarkdownContent.preparePreviews(for: [short, long])
        precondition(batch.count == 2 && !batch[0].isTruncated && batch[1].isTruncated)
        print("PASS: inline images and batch history preparation")
    }
}
