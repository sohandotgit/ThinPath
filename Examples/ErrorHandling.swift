import UIKit
import ThinPath

/// Parse with comprehensive error handling.
func parseWithDiagnostics(url: URL) -> SVGDocument? {
    do {
        let data = try Data(contentsOf: url)
        let (document, errors) = parse(data: data)

        // Log warnings but don't fail
        if !errors.isEmpty {
            print("SVG parse warnings:")
            for (index, error) in errors.enumerated() {
                print("  [\(index + 1)] \(error.message)")
            }
            print("Document may be incomplete. Proceeding with best-effort render.")
        }

        return document
    } catch {
        print("Failed to load SVG: \(error)")
        return nil
    }
}

/// Render with fallback if document is invalid.
func renderWithFallback(document: SVGDocument?, into imageView: UIImageView, fallback: UIImage) {
    guard let document = document, !document.root.isNone else {
        imageView.image = fallback
        return
    }

    let renderer = ThinPath()
    if let cgImage = renderer.render(document, size: CGSize(width: 200, height: 200), scale: 2) {
        imageView.image = UIImage(cgImage: cgImage)
    } else {
        imageView.image = fallback
    }
}

/// Check document validity before rendering.
func isDocumentValid(_ document: SVGDocument) -> Bool {
    return !document.root.isNone && !document.nodes.isEmpty
}
