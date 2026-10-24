import PDFKit
import UIKit
import UniformTypeIdentifiers

/// An image ready for diagram import: upright, and no larger than tracing needs.
struct DiagramSource: Identifiable {
    let id = UUID()
    let image: UIImage
    let suggestedName: String

    static let maxDimension: CGFloat = 3000

    enum Kind { case layoutFile, image, pdf }

    /// What a picked file is, by its type, falling back to its extension.
    static func kind(of url: URL) -> Kind {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .pdf) { return .pdf }
        if let type, type.conforms(to: .image) { return .image }
        return .layoutFile
    }

    static func load(from url: URL) -> DiagramSource? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        switch kind(of: url) {
        case .pdf:
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = maxDimension / max(bounds.width, bounds.height)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            return DiagramSource(image: image, suggestedName: name)
        case .image:
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
            return DiagramSource(image: upright(image), suggestedName: name)
        case .layoutFile:
            return nil
        }
    }

    static func load(imageData data: Data) -> DiagramSource? {
        guard let image = UIImage(data: data) else { return nil }
        return DiagramSource(image: upright(image), suggestedName: "")
    }

    /// Photos carry their rotation as metadata; tracing needs the pixels themselves upright.
    static func upright(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
