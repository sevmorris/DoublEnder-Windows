import CRaylib
import DoublEnderCore
import Foundation

/// The recorder: brushed-metal plate, amber screen, LCD counter, the one
/// big button and the meter row. Port of the Mac build's ContentView,
/// RecorderMainPanel and FaceplateComponents.
final class FaceplateView {
    enum Popover { case devices, settings }

    let r: Renderer
    let input: Input
    let controller: RecorderController
    var popover: Popover?
    /// Where the meter row sits, for anchoring the device list.
    private(set) var meterRowTop: Float = 0

    init(renderer: Renderer, input: Input, controller: RecorderController) {
        r = renderer
        self.input = input
        self.controller = controller
    }

    private var isRecording: Bool { controller.isCurrentlyRecording }

    func draw(time: Double) {
        let vp = Theme.viewport
        // The screen, behind the plate's cutout.
        DrawRectangleRec(vp, Theme.vpSurface)
        r.draw(r.viewportShading(size: Vector2(x: vp.width, y: vp.height)), in: vp)

        if case .error(let message) = controller.state {
            drawErrorCard(message: message)
        } else {
            drawMainPanel()
        }

        r.draw(r.texture("faceplate"), in: Rectangle(x: 0, y: 0, width: Theme.windowWidth, height: Theme.windowHeight))
        // Warm light from the cutout (FaceplateScreenGlow).
        DrawRectangleRec(vp, Theme.screenGlow.opacity(0.04))

        let led = Theme.ledSize
        r.draw(r.texture(isRecording ? "led_red_on" : "led_red_off"),
               in: Rectangle(x: Theme.redLEDCenter.x - led / 2, y: Theme.redLEDCenter.y - led / 2,
                             width: led, height: led))

        drawWindowControls()
    }

    // MARK: - Main panel

    private func drawMainPanel() {
        let s = Theme.s
        let vp = Theme.viewport
        let width = Theme.vpContentWidth
        let left = vp.midX - width / 2
        let warning = controller.recordingWarning

        // VStack(spacing: 0) with four spacers sharing the leftover height.
        let counterH = s(70)
        let badgeH: Float = warning == nil ? 0 : s(14) + s(3)
        let buttonH = s(72)
        let meterH = s(34) + s(4) + s(12)
        let labelH = s(4) + s(8.5) * 1.25
        let minSpacers = [Theme.vpInnerPad, s(10), s(10), Theme.vpInnerPad]
        let fixed = counterH + badgeH + buttonH + meterH + labelH
        let extra = max(0, vp.height - fixed - minSpacers.reduce(0, +)) / Float(minSpacers.count)
        var y = vp.y + minSpacers[0] + extra

        drawCounter(Rectangle(x: left, y: y, width: width, height: counterH))
        y += counterH
        if let warning {
            drawWarningBadge(warning, centerX: vp.midX, top: y + s(3))
            y += badgeH
        }
        y += minSpacers[1] + extra
        drawRecordButton(Rectangle(x: left, y: y, width: width, height: buttonH))
        y += buttonH + minSpacers[2] + extra
        meterRowTop = y
        drawMeterRow(left: left, top: y, width: width)
        y += meterH
        drawDeviceLabelRow(left: left, top: y + s(4), width: width)
    }

    private func drawCounter(_ rect: Rectangle) {
        let s = Theme.s
        let radius = s(6)
        // Drop shadow under the window.
        r.fillRounded(Rectangle(x: rect.x, y: rect.y + s(1), width: rect.width, height: rect.height),
                      radius: radius, Theme.black.opacity(0.45))
        r.fillRounded(rect, radius: radius, Theme.vpSurface)

        let text = controller.recordingTime.hhmmss
        let size = s(41), tracking = s(3)
        r.glowText(text, .lcd, size, centeredAt: rect.center, color: Theme.counterGlowOuter,
                   radius: s(22), tracking: tracking, clip: rect)
        r.glowText(text, .lcd, size, centeredAt: rect.center, color: Theme.counterGlowInner,
                   radius: s(8), tracking: tracking, clip: rect)
        r.text(text, .lcd, size, centeredAt: rect.center, color: Theme.vpAmber, tracking: tracking)
        r.strokeRounded(rect, radius: radius, width: s(1.5), Theme.vpBorder)
    }

    private func drawWarningBadge(_ message: String, centerX: Float, top: Float) {
        let s = Theme.s
        let size = s(9), gap = s(4), tracking = s(0.4)
        let textWidth = r.measure(message, .sans, size, tracking: tracking).x
        let total = size + gap + textWidth
        let x = centerX - total / 2
        let midY = top + s(14) / 2
        r.warningIcon(center: Vector2(x: x + size / 2, y: midY), size: size,
                      color: Theme.warningYellow, cutout: Theme.vpSurface)
        r.text(message, .sans, size, x: x + size + gap, centerY: midY,
               color: Theme.warningYellow, tracking: tracking)
    }

    private func drawRecordButton(_ rect: Rectangle) {
        let s = Theme.s
        let enabled = isRecording ? !controller.isStopping : controller.canStartRecording
        let state = input.button("record", rect, layer: .base, enabled: enabled)
        if state.clicked { controller.toggleRecording() }

        let radius = s(6)
        let recording = isRecording
        r.fillRounded(rect, radius: radius, Theme.vpSurface)
        r.fillRounded(rect, radius: radius, recording ? Theme.stopFill : Theme.recordIdleFill)
        if state.held { r.fillRounded(rect, radius: radius, Theme.black.opacity(0.18)) }

        let label = controller.isStopping ? "SAVING…" : (recording ? "PRESS TO STOP" : "PRESS TO RECORD")
        var size = s(27)
        let tracking = s(3)
        // Both labels share one size; shrink (to 85% at most) only if the
        // longer one wouldn't fit, as minimumScaleFactor does.
        let widest = r.measure("PRESS TO RECORD", .panel, size, tracking: tracking).x
        let available = rect.width - s(8)
        if widest > available { size *= max(0.85, available / widest) }
        var color = recording ? Theme.white : Theme.recordAccent
        if !enabled && !controller.isStopping { color = color.opacity(0.4) }
        // Saira's line box puts its capitals a little below centre.
        let center = Vector2(x: rect.midX, y: rect.midY - size * 0.04)
        r.text(label, .panel, size, centeredAt: center, color: color, tracking: tracking)

        r.strokeRounded(rect, radius: radius, width: recording ? s(1.5) : s(2),
                        recording ? Theme.vpBorder : Theme.recordAccent.opacity(enabled ? 1 : 0.5))
    }

    private func drawMeterRow(left: Float, top: Float, width: Float) {
        let s = Theme.s
        let containerH = s(34), iconBoxW = s(34), gap = s(6)
        let meterW = width - iconBoxW * 2 - gap * 2
        let locked = isRecording || controller.isStopping

        let inputRect = Rectangle(x: left, y: top, width: iconBoxW, height: containerH)
        if iconButton("input", "icon_input", inputRect, active: popover == .devices, disabled: locked) {
            popover = popover == .devices ? nil : .devices
            input.focusedField = nil
        }
        let settingsRect = Rectangle(x: left + width - iconBoxW, y: top, width: iconBoxW, height: containerH)
        if iconButton("settings", "icon_settings", settingsRect, active: popover == .settings, disabled: locked) {
            popover = popover == .settings ? nil : .settings
            input.focusedField = nil
        }

        // The segmented meter.
        let meter = Rectangle(x: left + iconBoxW + gap, y: top, width: meterW, height: containerH)
        r.fillRounded(meter, radius: s(4), Theme.vpSurface)
        let n = LevelMeter.segmentCount
        let dbMin = LevelMeter.dbFloor, dbMax = LevelMeter.dbCeiling
        let segGap = s(1.5), inset = s(3)
        let availW = meter.width - inset * 2, availH = meter.height - inset * 2
        let segW = (availW - Float(n - 1) * segGap) / Float(n)
        let level = controller.meterLevel
        // 1 dB deadzone above the floor, so room noise doesn't hold the
        // first segment lit.
        let aboveDeadzone = level > dbMin + 1
        for i in 0..<n {
            let db = dbMin + Float(i) / Float(n) * (dbMax - dbMin)
            let lit = aboveDeadzone && level >= db
            let base = db < -18 ? Theme.meterSafe : (db < -6 ? Theme.meterWarning : Theme.meterDanger)
            let seg = Rectangle(x: meter.x + inset + Float(i) * (segW + segGap), y: meter.y + inset,
                                width: max(segW, 1), height: availH)
            r.fillRounded(seg, radius: 1, lit ? base : Theme.meterInactive)
        }
        r.strokeRounded(meter, radius: s(4), width: s(1.2), Theme.vpBorder)

        // Scale labels under the meter.
        let labelTop = top + containerH + s(4)
        for (db, text) in LevelMeter.scaleLabels {
            let frac = (db - dbMin) / (dbMax - dbMin)
            r.text(text, .mono, s(7), centeredAt: Vector2(x: meter.x + frac * meterW, y: labelTop + s(5)),
                   color: Theme.vpAmber.opacity(0.55))
        }
    }

    private func iconButton(_ id: String, _ icon: String, _ rect: Rectangle, active: Bool, disabled: Bool) -> Bool {
        let s = Theme.s
        let state = input.button(id, rect, layer: .base, enabled: !disabled)
        r.fillRounded(rect, radius: s(4), Theme.vpSurface)
        let opacity: Float = disabled ? 0.35 : (active || state.hovered ? 1.0 : 0.65)
        let iconSize = s(20)
        r.draw(r.texture(icon), in: Rectangle(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2,
                                              width: iconSize, height: iconSize),
               tint: Theme.vpAmber.opacity(opacity))
        r.strokeRounded(rect, radius: s(4), width: s(1.2), Theme.vpBorder)
        return state.clicked
    }

    private func drawDeviceLabelRow(left: Float, top: Float, width: Float) {
        let s = Theme.s
        let size = s(8.5)
        let (numeric, suffix) = VersionFormatting.splitSuffix(AppInfo.version)
        let version = "v\(numeric)\(suffix.uppercased())"
        let versionW = r.measure(version, .mono, size).x
        let writing = "WRITING"
        let writingW = r.measure(writing, .mono, size).x

        r.text(version, .mono, size, at: Vector2(x: left, y: top), color: Theme.secondaryAmber)
        r.text(writing, .mono, size, at: Vector2(x: left + width - writingW, y: top),
               color: controller.isWritingData ? Theme.activeAmber : Theme.idleWritingAmber)
        // Centred, and kept clear of the labels either side.
        let room = width - 2 * max(versionW, writingW) - s(12)
        let name = r.truncate(controller.boundInputDeviceName ?? "—", .mono, size, width: room)
        let nameW = r.measure(name, .mono, size).x
        r.text(name, .mono, size, at: Vector2(x: left + (width - nameW) / 2, y: top), color: Theme.secondaryAmber)
    }

    // MARK: - Error card

    private func drawErrorCard(message: String) {
        let s = Theme.s
        let card = Theme.viewport
        r.fillRounded(card, radius: s(8), Theme.secondarySurface)
        r.strokeRounded(card, radius: s(8), width: 1.5, Theme.vpBorder, inside: true)

        let iconSize = s(30), bodySize = s(11), spacing = s(12)
        let textWidth = card.width - 2 * s(16) - 2 * s(8)
        let bodyH = r.paragraphHeight(message, .sans, bodySize, width: textWidth)
        let buttonLabel = "TRY AGAIN"
        let buttonSize = s(10)
        let buttonText = r.measure(buttonLabel, .sansBold, buttonSize, tracking: 1.5)
        let buttonRect0 = Vector2(x: buttonText.x + 2 * s(18), y: buttonSize * 1.3 + 2 * s(7))
        let total = iconSize + spacing + bodyH + spacing + buttonRect0.y
        var y = card.midY - total / 2

        r.warningIcon(center: Vector2(x: card.midX, y: y + iconSize / 2), size: iconSize,
                      color: Theme.vpAmber, cutout: Theme.secondarySurface)
        y += iconSize + spacing
        r.paragraph(message, .sans, bodySize, centerX: card.midX, top: y, width: textWidth, color: Theme.secondaryText)
        y += bodyH + spacing
        let button = Rectangle(x: card.midX - buttonRect0.x / 2, y: y, width: buttonRect0.x, height: buttonRect0.y)
        let state = input.button("tryAgain", button, layer: .base)
        r.fillRounded(button, radius: s(4), state.hovered ? Theme.vpAmber.opacity(0.12) : Theme.secondaryFieldBg)
        r.strokeRounded(button, radius: s(4), width: s(1), Theme.vpAmber)
        r.text(buttonLabel, .sansBold, buttonSize, centeredAt: button.center, color: Theme.secondaryText, tracking: 1.5)
        if state.clicked { controller.reset() }
    }

    // MARK: - Window controls

    /// A borderless window has no title bar, so the plate carries small
    /// minimise and close buttons in its top-right corner. Close goes
    /// through the same recording check as Ctrl+Q.
    private func drawWindowControls() {
        let radius: Float = 7
        let y: Float = 26
        let close = Vector2(x: Theme.windowWidth - 40, y: y)
        let minimize = Vector2(x: Theme.windowWidth - 62, y: y)
        for (id, center) in [("close", close), ("minimize", minimize)] {
            let hit = Rectangle(x: center.x - radius - 3, y: center.y - radius - 3,
                                width: 2 * radius + 6, height: 2 * radius + 6)
            let state = input.button(id, hit, layer: .base)
            let ink = Theme.black.opacity(state.hovered ? 0.75 : 0.32)
            DrawCircleV(center, radius, Theme.black.opacity(state.hovered ? 0.18 : 0.08))
            DrawRing(center, radius - 1, radius, 0, 360, 32, Theme.black.opacity(0.25))
            let a: Float = 3.2
            if id == "close" {
                DrawLineEx(Vector2(x: center.x - a, y: center.y - a), Vector2(x: center.x + a, y: center.y + a), 1.4, ink)
                DrawLineEx(Vector2(x: center.x - a, y: center.y + a), Vector2(x: center.x + a, y: center.y - a), 1.4, ink)
                if state.clicked { controller.requestQuit() }
            } else {
                DrawLineEx(Vector2(x: center.x - a, y: center.y), Vector2(x: center.x + a, y: center.y), 1.4, ink)
                if state.clicked { MinimizeWindow() }
            }
        }
    }
}
