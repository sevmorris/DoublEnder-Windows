import CRaylib
import DoublEnderCore
import Foundation

/// Fonts, textures and drawing primitives. Main thread only.
///
/// All layout is in points (the Mac's design units); raylib's HIGHDPI mode
/// scales points to pixels. Fonts are rasterised at the pixel size they
/// will appear at, so text stays sharp at 150% and 200% display scaling.
final class Renderer {
    enum Face: String, CaseIterable {
        case lcd = "DSEG7Classic-Regular.ttf"
        case panel = "Saira-Regular.ttf"
        case sans = "NotoSans-Medium.ttf"
        case sansBold = "NotoSans-Bold.ttf"
        case mono = "NotoSansMono-Medium.ttf"
        case monoBold = "NotoSansMono-Bold.ttf"

        /// raylib sizes a font by its line box (ascent − descent); the Mac
        /// by its em. Line box ÷ em, from each font's hhea table.
        var lineBox: Float {
            switch self {
            case .lcd: return 1.0
            case .panel: return 1.574
            default: return 1.362
            }
        }

        /// Ascent and capital height, in ems.
        var ascent: Float {
            switch self {
            case .lcd: return 1.0
            case .panel: return 1.135
            default: return 1.069
            }
        }

        var capHeight: Float {
            switch self {
            case .lcd: return 1.0
            case .panel: return 0.688
            default: return 0.714
            }
        }
    }

    /// Line height the layout assumes, in ems: about the system font's.
    static let lineHeight: Float = 1.2
    /// Baseline below the top of that line, in ems.
    static let baseline: Float = 0.95

    let resources: URL
    private(set) var pixelScale: Float = 1
    private var fonts: [String: Font] = [:]
    private var textures: [String: Texture2D] = [:]
    private var vignette: Texture2D?

    /// ASCII, Latin-1, Latin Extended-A, and the punctuation the app's
    /// strings use (— … ’ “ ” • → ✓). Enough for the LCD and panel faces,
    /// which only draw the app's own labels.
    private static let labelCodepoints: [Int32] = {
        var points = Array(Int32(32)...Int32(126)) + Array(Int32(160)...Int32(383))
        points += [0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x2192, 0x2713]
        return points
    }()

    /// The text faces also draw what the system and the guest supply: device
    /// names, the Desktop's localised name, typed notes. The bundled Noto
    /// fonts cover Latin Extended-B, Greek and Cyrillic, so those load too.
    /// ASCII stays first: raylib finds a glyph by searching in this order.
    private static let textCodepoints: [Int32] = labelCodepoints
        + Array(Int32(0x0180)...Int32(0x024F)) + Array(Int32(0x0370)...Int32(0x03FF))
        + Array(Int32(0x0400)...Int32(0x04FF))

    init(resources: URL) {
        self.resources = resources
    }

    /// Re-reads the display scale; fonts and generated art follow it.
    func updatePixelScale() {
        let scale = max(1, Float(GetRenderWidth()) / max(1, Float(GetScreenWidth())))
        guard abs(scale - pixelScale) > 0.01 else { return }
        pixelScale = scale
        for font in fonts.values { UnloadFont(font) }
        fonts.removeAll()
        if let vignette { UnloadTexture(vignette) }
        vignette = nil
    }

    // MARK: - Fonts and text

    /// `size` is in raylib's units (line box, in points).
    private func rlFont(_ face: Face, lineBoxSize size: Float) -> Font {
        let pixels = Int32(max(6, (size * pixelScale).rounded()))
        let key = "\(face.rawValue)@\(pixels)"
        if let font = fonts[key] { return font }
        let path = resources.appendingPathComponent("Fonts/\(face.rawValue)").path
        var points = (face == .lcd || face == .panel) ? Self.labelCodepoints : Self.textCodepoints
        let font = points.withUnsafeMutableBufferPointer { buf in
            LoadFontEx(path, pixels, buf.baseAddress, Int32(buf.count))
        }
        SetTextureFilter(font.texture, Int32(TEXTURE_FILTER_BILINEAR.rawValue))
        fonts[key] = font
        return font
    }

    /// Width, and the layout's line height, of `text` at `size` points (em).
    func measure(_ text: String, _ face: Face, _ size: Float, tracking: Float = 0) -> Vector2 {
        let rlSize = size * face.lineBox
        let m = MeasureTextEx(rlFont(face, lineBoxSize: rlSize), text, rlSize, tracking)
        return Vector2(x: m.x, y: size * Self.lineHeight)
    }

    /// Draws with its baseline at `baseline`.
    func text(_ text: String, _ face: Face, _ size: Float, x: Float, baseline: Float,
              color: Color, tracking: Float = 0) {
        let rlSize = size * face.lineBox
        let top = baseline - face.ascent * size
        DrawTextEx(rlFont(face, lineBoxSize: rlSize), text, snap(Vector2(x: x, y: top)), rlSize, tracking, color)
    }

    /// Draws in a line whose top is at `position.y`, as a SwiftUI Text frame.
    func text(_ text: String, _ face: Face, _ size: Float, at position: Vector2,
              color: Color, tracking: Float = 0) {
        self.text(text, face, size, x: position.x, baseline: position.y + Self.baseline * size,
                  color: color, tracking: tracking)
    }

    /// Left-aligned, capitals centred vertically on `y`.
    func text(_ text: String, _ face: Face, _ size: Float, x: Float, centerY: Float,
              color: Color, tracking: Float = 0) {
        self.text(text, face, size, x: x, baseline: centerY + face.capHeight * size / 2,
                  color: color, tracking: tracking)
    }

    /// Centred on a point, capitals centred vertically.
    func text(_ text: String, _ face: Face, _ size: Float, centeredAt center: Vector2,
              color: Color, tracking: Float = 0) {
        let width = measure(text, face, size, tracking: tracking).x
        self.text(text, face, size, x: center.x - width / 2, centerY: center.y,
                  color: color, tracking: tracking)
    }

    /// Rounds to the pixel grid so glyphs aren't resampled between pixels.
    private func snap(_ p: Vector2) -> Vector2 {
        Vector2(x: (p.x * pixelScale).rounded() / pixelScale, y: (p.y * pixelScale).rounded() / pixelScale)
    }

    /// Greedy word wrap; explicit newlines are kept.
    func wrap(_ text: String, _ face: Face, _ size: Float, width: Float, tracking: Float = 0) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if line.isEmpty || measure(candidate, face, size, tracking: tracking).x <= width {
                    line = candidate
                } else {
                    lines.append(line)
                    line = String(word)
                }
                // A single word wider than the line: break it by characters.
                while measure(line, face, size, tracking: tracking).x > width, line.count > 1 {
                    var head = line
                    while measure(head, face, size, tracking: tracking).x > width, head.count > 1 {
                        head.removeLast()
                    }
                    lines.append(head)
                    line = String(line.dropFirst(head.count))
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// Wrapped, centred lines; returns the height used.
    @discardableResult
    func paragraph(_ text: String, _ face: Face, _ size: Float, centerX: Float, top: Float,
                   width: Float, color: Color, tracking: Float = 0, lineSpacing: Float = 1.3) -> Float {
        let lineHeight = size * lineSpacing
        let lines = wrap(text, face, size, width: width, tracking: tracking)
        for (i, line) in lines.enumerated() {
            let m = measure(line, face, size, tracking: tracking)
            self.text(line, face, size, at: Vector2(x: centerX - m.x / 2, y: top + Float(i) * lineHeight),
                      color: color, tracking: tracking)
        }
        return Float(lines.count) * lineHeight
    }

    func paragraphHeight(_ text: String, _ face: Face, _ size: Float, width: Float,
                         tracking: Float = 0, lineSpacing: Float = 1.3) -> Float {
        Float(wrap(text, face, size, width: width, tracking: tracking).count) * size * lineSpacing
    }

    enum Truncation { case tail, middle }

    func truncate(_ text: String, _ face: Face, _ size: Float, width: Float,
                  tracking: Float = 0, mode: Truncation = .tail) -> String {
        guard measure(text, face, size, tracking: tracking).x > width else { return text }
        var chars = Array(text)
        while chars.count > 1 {
            switch mode {
            case .tail:
                chars.removeLast()
                let candidate = String(chars) + "…"
                if measure(candidate, face, size, tracking: tracking).x <= width { return candidate }
            case .middle:
                chars.remove(at: chars.count / 2)
                let half = chars.count / 2
                let candidate = String(chars[..<half]) + "…" + String(chars[half...])
                if measure(candidate, face, size, tracking: tracking).x <= width { return candidate }
            }
        }
        return "…"
    }

    // MARK: - Textures

    func texture(_ name: String) -> Texture2D {
        if let texture = textures[name] { return texture }
        var texture = LoadTexture(resources.appendingPathComponent("Images/\(name).png").path)
        GenTextureMipmaps(&texture)
        SetTextureFilter(texture, Int32(TEXTURE_FILTER_TRILINEAR.rawValue))
        textures[name] = texture
        return texture
    }

    func draw(_ texture: Texture2D, in rect: Rectangle, tint: Color = Theme.white) {
        DrawTexturePro(texture,
                       Rectangle(x: 0, y: 0, width: Float(texture.width), height: Float(texture.height)),
                       rect, Vector2(x: 0, y: 0), 0, tint)
    }

    // MARK: - Shapes

    func fillRounded(_ rect: Rectangle, radius: Float, _ color: Color) {
        guard rect.width > 0, rect.height > 0 else { return }
        DrawRectangleRounded(rect, roundness(rect, radius), 12, color)
    }

    /// A stroke centred on the edge, as SwiftUI's `.stroke`; `inside` keeps
    /// it within the rect, as `.strokeBorder`.
    func strokeRounded(_ rect: Rectangle, radius: Float, width: Float, _ color: Color, inside: Bool = false) {
        // raylib draws the line outward from the rect it is given.
        let inset = inside ? width : width / 2
        let inner = rect.insetBy(inset, inset)
        guard inner.width > 0, inner.height > 0 else { return }
        DrawRectangleRoundedLinesEx(inner, roundness(inner, max(0, radius - inset)), 12, width, color)
    }

    private func roundness(_ rect: Rectangle, _ radius: Float) -> Float {
        min(1, 2 * radius / max(1, min(rect.width, rect.height)))
    }

    // MARK: - Glow

    /// A soft halo of `text`, standing in for SwiftUI's `.shadow(radius:)`
    /// on the counter and dialog titles: the text drawn faintly many times
    /// on rings around itself, weighted like a Gaussian blur. No offscreen
    /// targets or shaders, so it renders the same on every GL driver.
    /// `clip` limits where the halo lands, as the Mac's clipShape does.
    func glowText(_ text: String, _ face: Face, _ size: Float, centeredAt center: Vector2,
                  color: Color, radius: Float, tracking: Float = 0, clip: Rectangle? = nil) {
        if let clip { BeginScissorMode(Int32(clip.x), Int32(clip.y), Int32(clip.width), Int32(clip.height)) }
        defer { if clip != nil { EndScissorMode() } }
        // SwiftUI's radius is about two standard deviations.
        let sigma = radius / 2
        let rings: [(distance: Float, samples: Int)] = [(0.5, 6), (1.2, 10), (2.0, 14), (2.9, 18)]
        let base = Float(color.a) / 255
        for (ring, (distance, samples)) in rings.enumerated() {
            let d = distance * sigma
            let weight = exp(-distance * distance / 2)
            let alpha = base * weight * 0.22 / Float(samples) * Float(rings.count)
            let tint = color.opacity(0).withAlpha(alpha)
            for i in 0..<samples {
                let angle = (Float(i) + (ring % 2 == 0 ? 0 : 0.5)) / Float(samples) * 2 * .pi
                let offset = Vector2(x: center.x + cos(angle) * d, y: center.y + sin(angle) * d)
                self.text(text, face, size, centeredAt: offset, color: tint, tracking: tracking)
            }
        }
    }

    // MARK: - The screen's surface

    /// Scanlines and a radial vignette over the viewport, baked once per
    /// display scale (`FaceplateViewportBackground` on the Mac).
    func viewportShading(size: Vector2) -> Texture2D {
        if let vignette { return vignette }
        let w = Int(size.x * pixelScale), h = Int(size.y * pixelScale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cx = Float(w) / 2, cy = Float(h) / 2
        let start = 80 * pixelScale, end = 215 * pixelScale
        let line = max(1, Int(pixelScale.rounded()))
        let spacing = Int((3 * pixelScale).rounded())
        for y in 0..<h {
            let scan: Float = (y % spacing) < line ? 0.07 : 0
            for x in 0..<w {
                let d = ((Float(x) - cx) * (Float(x) - cx) + (Float(y) - cy) * (Float(y) - cy)).squareRoot()
                let t = max(0, min(1, (d - start) / (end - start)))
                let vignetteAlpha = 0.52 * t
                // Two black layers composited: scanline under the vignette.
                let alpha = 1 - (1 - scan) * (1 - vignetteAlpha)
                pixels[(y * w + x) * 4 + 3] = UInt8((alpha * 255).rounded())
            }
        }
        let texture = pixels.withUnsafeMutableBytes { buf -> Texture2D in
            let image = Image(data: buf.baseAddress, width: Int32(w), height: Int32(h), mipmaps: 1,
                              format: Int32(PIXELFORMAT_UNCOMPRESSED_R8G8B8A8.rawValue))
            return LoadTextureFromImage(image)
        }
        SetTextureFilter(texture, Int32(TEXTURE_FILTER_BILINEAR.rawValue))
        vignette = texture
        return texture
    }

    // MARK: - Glyphs drawn as shapes

    /// exclamationmark.triangle.fill
    func warningIcon(center c: Vector2, size: Float, color: Color, cutout: Color) {
        let h = size * 0.88
        let top = Vector2(x: c.x, y: c.y - h / 2)
        let left = Vector2(x: c.x - size / 2, y: c.y + h / 2)
        let right = Vector2(x: c.x + size / 2, y: c.y + h / 2)
        DrawTriangle(top, left, right, color)
        let bar = size * 0.09
        fillRounded(Rectangle(x: c.x - bar / 2, y: c.y - h * 0.12, width: bar, height: h * 0.36),
                    radius: bar / 2, cutout)
        DrawCircleV(Vector2(x: c.x, y: c.y + h * 0.34), bar * 0.62, cutout)
    }

    /// checkmark.circle.fill
    func successIcon(center c: Vector2, size: Float, color: Color, cutout: Color) {
        DrawCircleV(c, size / 2, color)
        let t = size * 0.09
        let a = Vector2(x: c.x - size * 0.22, y: c.y + size * 0.01)
        let b = Vector2(x: c.x - size * 0.06, y: c.y + size * 0.17)
        let d = Vector2(x: c.x + size * 0.23, y: c.y - size * 0.16)
        DrawLineEx(a, b, t, cutout)
        DrawLineEx(b, d, t, cutout)
        DrawCircleV(b, t / 2, cutout)
    }

    /// A plain check, for the selected row in the device list.
    func checkmark(center c: Vector2, size: Float, color: Color) {
        let t = max(1.5, size * 0.16)
        let a = Vector2(x: c.x - size * 0.42, y: c.y + size * 0.02)
        let b = Vector2(x: c.x - size * 0.12, y: c.y + size * 0.32)
        let d = Vector2(x: c.x + size * 0.45, y: c.y - size * 0.34)
        DrawLineEx(a, b, t, color)
        DrawLineEx(b, d, t, color)
        DrawCircleV(b, t / 2, color)
    }

    /// An indeterminate spinner.
    func spinner(center c: Vector2, size: Float, color: Color, time: Double) {
        let start = Float(time.truncatingRemainder(dividingBy: 1)) * 360
        DrawRing(c, size / 2 - size * 0.12, size / 2, start, start + 270, 36, color)
    }
}
