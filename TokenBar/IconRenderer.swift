import AppKit

// Renders the dual-cell menu bar icon.
// Claude:   "CLD" stacked vertically + donut arc (usage fraction)
// DeepSeek: balance over "DPSK" (two stacked rows)
// Cell order is controlled by `providerOrder`.
// Uses NSImage(size:flipped:drawingHandler:) which provides a clean Y-up context
// (origin bottom-left) with automatic retina scaling — no bitmap coordinate confusion.
enum IconRenderer {

    // MARK: - Layout (points)

    private static let canvasH:    CGFloat = 18    // standard menu bar icon height
    private static let sidePad:    CGFloat = 0
    private static let letterColW: CGFloat = 7
    private static let innerGap:   CGFloat = 2
    private static let donutD:     CGFloat = 16    // larger donut
    private static let cellSep:    CGFloat = 4
    private static let fontSize:   CGFloat = 6.5   // Claude "CLD" letter size (pt)
    private static let moneyFontSize: CGFloat = 9  // DeepSeek balance (top row)
    private static let dpskFontSize:  CGFloat = 8  // DeepSeek "DPSK" label (bottom row)
    private static let lineGap:    CGFloat = 0.5   // vertical gap between stacked letters
    private static let stackLineGap: CGFloat = 2   // gap between the two DeepSeek rows
    private static let textDrop:   CGFloat = 1.5   // shift text down (1.5pt = 3px on retina)

    private static var labelFont: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .heavy) }
    private static var moneyFont: NSFont { .monospacedSystemFont(ofSize: moneyFontSize, weight: .heavy) }
    private static var dpskFont:  NSFont { .monospacedSystemFont(ofSize: dpskFontSize, weight: .heavy) }

    // MARK: - Public

    static func placeholder() -> NSImage {
        render(claudeFraction: 0, claudeEnabled: true,
               deepseekBalance: nil, currency: "USD", deepseekEnabled: true,
               antigravityGeminiFraction: 0, antigravityGeminiEnabled: true,
               antigravityClaudeGptFraction: 0, antigravityClaudeGptEnabled: true,
               providerOrder: ["claude", "deepseek", "antigravity"])
    }

    static func render(
        claudeFraction: Double,
        claudeEnabled: Bool,
        deepseekBalance: Double?,
        currency: String,
        deepseekEnabled: Bool,
        antigravityGeminiFraction: Double,
        antigravityGeminiEnabled: Bool,
        antigravityClaudeGptFraction: Double,
        antigravityClaudeGptEnabled: Bool,
        providerOrder: [String],
        isReducing: Bool = false
    ) -> NSImage {
        // Nothing to show in the bar → fall back to a brain glyph.
        if !claudeEnabled && !deepseekEnabled && !antigravityGeminiEnabled && !antigravityClaudeGptEnabled {
            return brainIcon(isReducing: isReducing)
        }

        let balStr = balanceString(deepseekBalance, currency: currency)
        let balW   = textWidth(balStr, font: moneyFont)
        let dpskW  = textWidth("DPSK", font: dpskFont)

        let claudeW      = letterColW + innerGap + donutD
        let deepseekW    = max(balW, dpskW)        // stacked cell: balance over "DPSK"
        let geminiW      = letterColW + innerGap + donutD
        let claudeGptW   = letterColW + innerGap + donutD

        // Width covers only the enabled cells, with a separator between them.
        var enabledCount = 0
        var contentW: CGFloat = 0
        
        if claudeEnabled {
            enabledCount += 1
            contentW += claudeW
        }
        if deepseekEnabled {
            enabledCount += 1
            contentW += deepseekW
        }
        if antigravityGeminiEnabled {
            enabledCount += 1
            contentW += geminiW
        }
        if antigravityClaudeGptEnabled {
            enabledCount += 1
            contentW += claudeGptW
        }
        
        var totalW = sidePad * 2 + contentW
        if enabledCount > 1 {
            totalW += CGFloat(enabledCount - 1) * cellSep
        }

        let size = NSSize(width: totalW, height: canvasH)
        let image = NSImage(size: size, flipped: false) { _ in
            var x = sidePad
            func drawClaudeCell() {
                drawLetters(["C", "L", "D"], x: x)
                drawDonut(cx: x + letterColW + innerGap + donutD / 2,
                          cy: canvasH / 2, fraction: claudeFraction)
                x += claudeW + cellSep
            }
            func drawDeepseekCell() {
                drawStack(top: balStr, bottom: "DPSK", x: x, width: deepseekW)
                x += deepseekW + cellSep
            }
            func drawAntigravityGeminiCell() {
                drawLetters(["A", "G", "Y"], x: x)
                drawDonut(cx: x + letterColW + innerGap + donutD / 2,
                          cy: canvasH / 2, fraction: antigravityGeminiFraction)
                x += geminiW + cellSep
            }
            func drawAntigravityClaudeGptCell() {
                drawLetters(["C", "G"], x: x)
                drawDonut(cx: x + letterColW + innerGap + donutD / 2,
                          cy: canvasH / 2, fraction: antigravityClaudeGptFraction)
                x += claudeGptW + cellSep
            }
            for provider in providerOrder {
                if provider == "claude" && claudeEnabled {
                    drawClaudeCell()
                } else if provider == "deepseek" && deepseekEnabled {
                    drawDeepseekCell()
                } else if provider == "antigravity" {
                    if antigravityGeminiEnabled {
                        drawAntigravityGeminiCell()
                    }
                    if antigravityClaudeGptEnabled {
                        drawAntigravityClaudeGptCell()
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        return trimmedHorizontally(image)
    }

    // MARK: - Primitives (called inside Y-up drawing handler)

    // Stacks `chars` top-to-bottom as a block, vertically centered in the canvas.
    private static func drawLetters(_ chars: [String], x: CGFloat) {
        let font  = labelFont
        let capH  = font.capHeight
        let lineH = capH + lineGap                     // per-letter advance
        let n     = CGFloat(chars.count)
        let stackH = capH * n + lineGap * (n - 1)      // total block height
        let stackBottom = (canvasH - stackH) / 2       // center the block
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        for (i, ch) in chars.enumerated() {
            // i=0 is the top letter → highest baseline
            let baseline = stackBottom + CGFloat(chars.count - 1 - i) * lineH - textDrop
            let str      = ch as NSString
            let charW    = str.size(withAttributes: attrs).width
            str.draw(at: NSPoint(x: x + (letterColW - charW) / 2, y: baseline),
                     withAttributes: attrs)
        }
    }

    // Draws a ring donut; fraction fills clockwise from 12 o'clock.
    private static func drawDonut(cx: CGFloat, cy: CGFloat, fraction: Double) {
        let outerR = donutD / 2
        let innerR = outerR * 0.60   // clear visible hole
        let midR   = (outerR + innerR) / 2
        let lineW  = outerR - innerR

        // Background ring (full circle, faint track)
        let bg = NSBezierPath()
        bg.appendArc(withCenter: NSPoint(x: cx, y: cy),
                     radius: midR, startAngle: 0, endAngle: 360)
        bg.lineWidth = lineW
        NSColor.black.withAlphaComponent(0.25).setStroke()
        bg.stroke()

        guard fraction > 0.002 else { return }

        // Cap at 97% so there's always a visible gap at the top even when over-limit.
        let displayFrac = min(fraction, 0.97)
        let endDeg = CGFloat(90.0 - displayFrac * 360.0)
        let fill   = NSBezierPath()
        fill.appendArc(withCenter: NSPoint(x: cx, y: cy),
                       radius: midR,
                       startAngle: 90,
                       endAngle: endDeg,
                       clockwise: true)
        fill.lineWidth = lineW
        fill.lineCapStyle = .round   // rounded ends on the progress arc
        NSColor.black.setStroke()
        fill.stroke()
    }

    // Draws a two-row cell — `top` over `bottom` — as a vertically-centered block,
    // each row horizontally centered within `width`. DeepSeek: balance over "DPSK".
    private static func drawStack(top: String, bottom: String, x: CGFloat, width: CGFloat) {
        let topFont    = moneyFont      // larger balance
        let bottomFont = dpskFont       // "DPSK" label
        // Center the two rows' cap-ink as one block.
        let blockH      = topFont.capHeight + stackLineGap + bottomFont.capHeight
        let capBaseline = (canvasH - blockH) / 2     // bottom row's cap baseline

        func draw(_ s: String, _ font: NSFont, _ baseline: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            let str = s as NSString
            let w   = str.size(withAttributes: attrs).width
            // draw(at:) places the bbox bottom here, not the baseline — the baseline
            // sits |descender| above it, so shift down by descender (negative) to land
            // the cap baseline exactly at `baseline`.
            str.draw(at: NSPoint(x: x + (width - w) / 2, y: baseline + font.descender),
                     withAttributes: attrs)
        }
        draw(bottom, bottomFont, capBaseline)
        draw(top,    topFont,    capBaseline + bottomFont.capHeight + stackLineGap)
    }

    // MARK: - Helpers

    private static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (s as NSString).size(withAttributes: attrs).width + 2
    }

    private static func balanceString(_ b: Double?, currency: String) -> String {
        guard let b else { return "—" }
        return String(format: "%@%.2f", CurrencyFormat.symbol(currency), b)
    }

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
