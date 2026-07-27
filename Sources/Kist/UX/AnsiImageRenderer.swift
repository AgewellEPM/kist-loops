import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// Renders a raster image as ANSI colored half-block characters that display in ANY terminal —
/// Terminal.app included — with NO iTerm2/Kitty pixel protocol and NO external tools (chafa/viu).
///
/// Each character cell stacks two vertical pixels: the UPPER HALF BLOCK `▀` is painted with the
/// TOP pixel as the foreground colour and the BOTTOM pixel as the background colour, which doubles
/// the effective vertical resolution. Truecolor (`38;2;r;g;b`) when the terminal advertises it,
/// otherwise the xterm-256 colour cube — so a real, recognizable picture appears even in Terminal.app.
enum AnsiImageRenderer {
    /// Decode `data` and render it ≤ `maxCols` wide and ≤ `maxRows` character rows tall. Returns nil
    /// only if the bytes aren't a decodable image (caller falls back to an honest message).
    static func render(data: Data, maxCols: Int, maxRows: Int = 40, truecolor: Bool = true) -> String? {
        #if canImport(CoreGraphics)
        guard maxCols > 0, maxRows > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let iw = img.width, ih = img.height
        guard iw > 0, ih > 0 else { return nil }

        // Fit within maxCols (1 px per column) and maxRows*2 (2 px per row). Square source pixels:
        // the half-block split already supplies 2 vertical samples per cell, so no aspect squashing.
        let pxW = max(1, min(maxCols, iw))
        var pxH = Int((Double(pxW) * Double(ih) / Double(iw)).rounded())
        pxH = max(2, min(pxH, maxRows * 2))
        if pxH % 2 == 1 { pxH += 1 }                              // even → clean top/bottom pairs

        let bytesPerRow = pxW * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * pxH)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: pxW, height: pxH, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
            return true
        }
        guard ok else { return nil }

        // CoreGraphics origin is bottom-left; flip so character row 0 is the top of the picture.
        func px(_ x: Int, _ yTopDown: Int) -> (Int, Int, Int) {
            let y = pxH - 1 - yTopDown
            let o = y * bytesPerRow + x * 4
            return (Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]))
        }

        var out = ""
        out.reserveCapacity(pxW * (pxH / 2) * 24)
        var rowY = 0
        while rowY < pxH {
            for x in 0..<pxW {
                let (tr, tg, tb) = px(x, rowY)
                let (br, bg, bb) = px(x, rowY + 1)
                out += fg(tr, tg, tb, truecolor) + bgc(br, bg, bb, truecolor) + "▀"
            }
            out += "\u{001B}[0m\n"                                 // reset at line end → no colour bleed
            rowY += 2
        }
        return out
        #else
        return nil
        #endif
    }

    private static func fg(_ r: Int, _ g: Int, _ b: Int, _ tc: Bool) -> String {
        tc ? "\u{001B}[38;2;\(r);\(g);\(b)m" : "\u{001B}[38;5;\(xterm256(r, g, b))m"
    }
    private static func bgc(_ r: Int, _ g: Int, _ b: Int, _ tc: Bool) -> String {
        tc ? "\u{001B}[48;2;\(r);\(g);\(b)m" : "\u{001B}[48;5;\(xterm256(r, g, b))m"
    }

    /// Map 8-bit RGB to the xterm-256 6×6×6 colour cube — the fallback when the terminal can't do truecolor.
    static func xterm256(_ r: Int, _ g: Int, _ b: Int) -> Int {
        func c(_ v: Int) -> Int { v < 48 ? 0 : (v < 115 ? 1 : (v - 35) / 40) }
        return 16 + 36 * c(r) + 6 * c(g) + c(b)
    }
}
