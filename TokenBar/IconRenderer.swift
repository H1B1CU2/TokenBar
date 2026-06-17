import AppKit

// Renders the brain icon for the macOS menu bar.
enum IconRenderer {

    // MARK: - Layout (points)
    private static let canvasH: CGFloat = 18    // standard menu bar icon height

    // MARK: - Public

    static func placeholder() -> NSImage {
        render()
    }

    static func render(isReducing: Bool = false) -> NSImage {
        return brainIcon(isReducing: isReducing)
    }

    // MARK: - Helpers

    // Shown in the menu bar when neither provider's cell is visible.
    private static func brainIcon(isReducing: Bool = false) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let baseImg = NSImage(systemSymbolName: "brain", accessibilityDescription: "TokenBar")?
            .withSymbolConfiguration(config) else {
            let fallback = NSImage(size: NSSize(width: canvasH, height: canvasH))
            fallback.isTemplate = true
            return fallback
        }
        
        if !isReducing {
            baseImg.isTemplate = true
            return trimmedHorizontally(baseImg)
        }
        
        let baseSize = baseImg.size
        let dotRadius: CGFloat = 2.5
        let extraWidth: CGFloat = 3
        let newSize = NSSize(width: baseSize.width + extraWidth, height: baseSize.height)
        
        let newImg = NSImage(size: newSize, flipped: false) { rect in
            // Draw the base brain symbol in the left part
            baseImg.draw(in: NSRect(x: 0, y: 0, width: baseSize.width, height: baseSize.height))
            
            // Draw the dot in the top-right corner
            let cx = newSize.width - dotRadius - 0.5
            let cy = newSize.height - dotRadius - 0.5
            
            let dotPath = NSBezierPath(ovalIn: NSRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            NSColor.black.set()
            dotPath.fill()
            
            return true
        }
        newImg.isTemplate = true
        return trimmedHorizontally(newImg)
    }

    // Crops fully-transparent columns off the left and right edges so the status
    // item (whose width is pinned to the image) hugs the visible ink instead of
    // the image's transparent margins. The glyph keeps its full size — only empty
    // pixels are removed. Vertical extent is left untouched.
    private static func trimmedHorizontally(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return image }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return image }

        var minX = w, maxX = -1
        for x in 0..<w {
            for y in 0..<h {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.02 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    break
                }
            }
        }
        guard maxX >= minX else { return image }   // fully transparent → leave as-is

        let scaleX = CGFloat(w) / image.size.width     // pixels per point
        let originX = CGFloat(minX) / scaleX
        let cropW   = CGFloat(maxX - minX + 1) / scaleX
        let out = NSImage(size: NSSize(width: cropW, height: image.size.height), flipped: false) { _ in
            image.draw(at: .zero,
                       from: NSRect(x: originX, y: 0, width: cropW, height: image.size.height),
                       operation: .sourceOver, fraction: 1.0)
            return true
        }
        out.isTemplate = image.isTemplate
        return out
    }
}
