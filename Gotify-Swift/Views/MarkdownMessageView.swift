import SwiftUI
import ImageIO

struct MarkdownMessageView: View {
    let message: String
    let fontSize: Double
    var lineLimit: Int?
    var showsImages: Bool = true
    var imageMaxHeight: CGFloat = 220
    var preparedContent: MarkdownContent?

    private struct ParseRequest: Equatable {
        let message: String
        let lineLimit: Int?
    }

    @State private var parsedContent: MarkdownContent?
    @State private var parsedRequest: ParseRequest?

    var body: some View {
        let request = ParseRequest(message: message, lineLimit: lineLimit)
        let content = preparedContent ?? (parsedRequest == request ? parsedContent : nil)
        Group {
            if let content {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(content.blocks.indices, id: \.self) { index in
                        switch content.blocks[index] {
                        case .text(let attributed):
                            markdownText(attributed)
                        case .image(let url, let altText):
                            if showsImages {
                                Link(destination: url) {
                                    MarkdownImagePreview(url: url, altText: altText, fontSize: fontSize, height: imageMaxHeight)
                                        .id(url)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                // Live messages and expanded text are parsed off the UI executor too.
                // Keep the temporary text bounded while the result is being prepared.
                Text(verbatim: MarkdownContent.previewSource(message, maxLines: lineLimit ?? MarkdownContent.previewLineLimit).text)
                    .font(.system(size: fontSize))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: preparedContent == nil ? request : nil) {
            guard preparedContent == nil,
                  parsedRequest != request else { return }
            do {
                let content = try await MarkdownContent.prepare(message: request.message, lineLimit: request.lineLimit)
                try Task.checkCancellation()
                parsedContent = content
                parsedRequest = request
            } catch {
                // A disappearing row or a changed message cancels obsolete work.
            }
        }
    }

    @ViewBuilder
    private func markdownText(_ attributed: AttributedString) -> some View {
        Text(attributed)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct MarkdownImagePreview: View {
    let url: URL
    let altText: String
    let fontSize: Double
    let height: CGFloat

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        Group {
            switch phase {
            case .empty:
                placeholderImage(iconName: "photo")
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .failure:
                placeholderImage(iconName: "photo.slash", caption: altText)
            @unknown default:
                placeholderImage(iconName: "photo")
            }
        }
        // Loading or failing an image must not resize its row while scrolling.
        .frame(height: height)
        .task {
            guard case .empty = phase else { return }
            do {
                let preview = try await Self.downloadPreview(from: url)
                try Task.checkCancellation()
                switch preview {
                case .thumbnail(let bitmap):
                    phase = .success(Image(decorative: bitmap, scale: 1))
                case .original(let data):
                    guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                    phase = .success(Image(nsImage: image))
                }
            } catch {
                if !Task.isCancelled {
                    phase = .failure(error)
                }
            }
        }
    }

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

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1536
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return .thumbnail(thumbnail)
        }
        return .original(data)
    }

    @ViewBuilder
    private func placeholderImage(iconName: String, caption: String? = nil) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.gray.opacity(0.12))
            .frame(maxWidth: .infinity)
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
