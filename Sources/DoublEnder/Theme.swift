import CRaylib

/// Design tokens, ported from the Mac build's `FaceplateDesign`. Every
/// geometry value is the 1.0 design scaled by `scale`, so the window and
/// everything in it resize together.
enum Theme {
    static let scale: Float = 1.2
    static func s(_ v: Float) -> Float { v * scale }

    /// 504 × 430 at 1.0.
    static let windowWidth: Float = s(504)
    static let windowHeight: Float = s(430)

    // Viewport insets into the faceplate art.
    static let vpTop: Float = s(79)
    static let vpLeading: Float = s(91)
    static let vpTrailing: Float = s(90)
    static let vpBottom: Float = s(81)
    static let vpInnerPad: Float = s(14)
    static let vpContentWidth: Float = s(295)

    static var viewport: Rectangle {
        Rectangle(x: vpLeading, y: vpTop,
                  width: windowWidth - vpLeading - vpTrailing,
                  height: windowHeight - vpTop - vpBottom)
    }

    // Status LED, right-aligned to the screen bezel's outer edge and
    // centred on the engraved RECORDING label.
    static let ledSize: Float = s(18)
    static let redLEDCenter = Vector2(x: s(431.5) - s(18) / 2, y: s(400.2))

    // Colours.
    static let vpAmber = rgb(0xFFD580)
    static let vpBorder = rgb(0xFFB347, 0.40)
    static let vpSurface = rgb(0x0D0800)
    static let panelStroke = rgb(0xFFB347, 0.28)
    static let secondarySurface = rgb(0x180E00)
    static let secondaryText = rgb(0xE8D8C0)
    static let secondaryFieldBg = rgb(0x0D0800)
    static let meterSafe = rgb(0xF5A623)
    static let meterWarning = rgb(0xFF8C00)
    static let meterDanger = rgb(0xE05C1A)
    static let meterInactive = rgb(0x2A1A00)
    static let secondaryAmber = rgb(0xA0600A)
    static let idleWritingAmber = rgb(0x5A340A)
    static let activeAmber = rgb(0xF5A623)
    static let recordAccent = rgb(0xE55F25)
    static let stopFill = rgb(0xBC3818)
    static let recordIdleFill = rgb(0x1A0A00)
    static let counterGlowInner = rgb(0xF5A623, 0.90)
    static let counterGlowOuter = rgb(0xC87800, 0.50)
    static let screenGlow = rgb(0xC96A00)
    static let warningYellow = Color(r: 255, g: 214, b: 10, a: 204)

    // Themed dialogs (crash recovery, confirmations).
    static let dialogBackground = rgb(0x0D0800)
    static let dialogBorder = rgb(0xFFB347, 0.45)
    static let dialogTitle = rgb(0xFFD580)
    static let dialogIcon = rgb(0xF5A623)
    static let dialogBody = rgb(0xF0E0C0)
    static let dialogFileName = rgb(0xA0600A)
    static let dialogFieldBg = rgb(0x1A0A00)

    static let white = Color(r: 255, g: 255, b: 255, a: 255)
    static let black = Color(r: 0, g: 0, b: 0, a: 255)
    static let clear = Color(r: 0, g: 0, b: 0, a: 0)

    static func rgb(_ hex: UInt32, _ alpha: Float = 1) -> Color {
        Color(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF),
              a: UInt8((max(0, min(1, alpha)) * 255).rounded()))
    }
}

extension Color {
    func withAlpha(_ alpha: Float) -> Color {
        Color(r: r, g: g, b: b, a: UInt8((max(0, min(1, alpha)) * 255).rounded()))
    }

    func opacity(_ factor: Float) -> Color {
        Color(r: r, g: g, b: b, a: UInt8((Float(a) * max(0, min(1, factor))).rounded()))
    }
}

extension Rectangle {
    var minX: Float { x }
    var minY: Float { y }
    var maxX: Float { x + width }
    var maxY: Float { y + height }
    var midX: Float { x + width / 2 }
    var midY: Float { y + height / 2 }
    var center: Vector2 { Vector2(x: midX, y: midY) }

    func insetBy(_ dx: Float, _ dy: Float) -> Rectangle {
        Rectangle(x: x + dx, y: y + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }

    func contains(_ p: Vector2) -> Bool {
        p.x >= x && p.x < x + width && p.y >= y && p.y < y + height
    }
}
