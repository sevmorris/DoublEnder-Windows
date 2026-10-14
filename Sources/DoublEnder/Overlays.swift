import CRaylib
import DoublEnderCore
import Foundation

/// The microphone list, the settings panel and the themed dialogs. On the
/// Mac these float outside the window (NSPopover, separate windows); a
/// raylib window can't, so they are cards over the faceplate.
final class Overlays {
    let r: Renderer
    let input: Input
    let controller: RecorderController
    let faceplate: FaceplateView
    private var deviceScroll: Float = 0

    init(renderer: Renderer, input: Input, controller: RecorderController, faceplate: FaceplateView) {
        r = renderer
        self.input = input
        self.controller = controller
        self.faceplate = faceplate
    }

    /// Dims the plate and its screen, leaving the transparent corners alone.
    private func dimBackdrop(_ amount: Float) {
        r.draw(r.texture("faceplate"), in: Rectangle(x: 0, y: 0, width: Theme.windowWidth, height: Theme.windowHeight),
               tint: Theme.black.opacity(amount))
        DrawRectangleRec(Theme.viewport, Theme.black.opacity(amount))
    }

    private func panel(_ rect: Rectangle) {
        r.fillRounded(rect, radius: 6, Theme.secondarySurface)
        r.strokeRounded(rect, radius: 6, width: 1.5, Theme.vpBorder)
    }

    // MARK: - Popovers

    func drawPopover() {
        guard let popover = faceplate.popover else { return }
        // Escape leaves a text field first, and closes the panel only after.
        let wasEditing = input.focusedField != nil
        let rect: Rectangle
        switch popover {
        case .devices: rect = drawDevicePicker()
        case .settings: rect = drawSettings()
        }
        // Transient, as on the Mac: a click outside, or Escape, closes it.
        if input.pressed, input.isInteractive(.popover), !rect.contains(input.mouse) {
            input.claimPress()
            close()
        } else if input.keyPressed(KEY_ESCAPE), !wasEditing, input.isInteractive(.popover) {
            close()
        }
    }

    private func close() {
        faceplate.popover = nil
        input.focusedField = nil
    }

    private func drawDevicePicker() -> Rectangle {
        let devices = controller.inputDevices
        let width: Float = 300
        let headerH: Float = 12 + 14 + 5
        let rowH: Float = 35
        let maxRows = max(1, Int((faceplate.meterRowTop - 16 - headerH - 8) / rowH))
        let visible = min(max(devices.count, 1), maxRows)
        let height = headerH + Float(visible) * rowH + 8
        let left = Theme.viewport.midX - Theme.vpContentWidth / 2
        let rect = Rectangle(x: left, y: max(8, faceplate.meterRowTop - 8 - height), width: width, height: height)
        dimBackdrop(0.25)
        panel(rect)
        r.text("MICROPHONES", .sansBold, 11, at: Vector2(x: rect.x + 15, y: rect.y + 12),
               color: Theme.vpAmber, tracking: 1.5)

        if devices.isEmpty {
            r.text("No microphones found", .sans, 14, at: Vector2(x: rect.x + 15, y: rect.y + headerH + 8),
                   color: Theme.secondaryText.opacity(0.55))
            return rect
        }
        // Scroll with the wheel when the list is longer than the room.
        let overflow = Float(max(0, devices.count - visible)) * rowH
        if rect.contains(input.mouse) { deviceScroll -= GetMouseWheelMove() * rowH }
        deviceScroll = max(0, min(overflow, deviceScroll))

        let listArea = Rectangle(x: rect.x, y: rect.y + headerH, width: rect.width, height: Float(visible) * rowH)
        BeginScissorMode(Int32(listArea.x), Int32(listArea.y), Int32(listArea.width), Int32(listArea.height.rounded(.up)))
        for (i, device) in devices.enumerated() {
            let row = Rectangle(x: rect.x + 4, y: listArea.y + Float(i) * rowH - deviceScroll, width: rect.width - 8, height: rowH)
            guard row.maxY > listArea.y, row.minY < listArea.maxY else { continue }
            let visibleRow = Rectangle(x: row.x, y: max(row.y, listArea.y), width: row.width,
                                       height: min(row.maxY, listArea.maxY) - max(row.y, listArea.y))
            let state = input.button("device-\(device.uid)", visibleRow, layer: .popover)
            if state.hovered { r.fillRounded(row, radius: 4, Theme.vpAmber.opacity(0.08)) }
            let selected = device.uid == controller.selectedInputDeviceID
            let name = r.truncate(device.name, .sans, 14, width: row.width - 22 - 30, mode: .middle)
            r.text(name, .sans, 14, x: row.x + 11, centerY: row.midY, color: Theme.secondaryText)
            if selected {
                r.checkmark(center: Vector2(x: row.maxX - 18, y: row.midY), size: 11, color: Theme.vpAmber)
            }
            if state.clicked {
                controller.selectInput(device.uid)
                close()
            }
        }
        EndScissorMode()
        return rect
    }

    private func drawSettings() -> Rectangle {
        let width: Float = 325, pad: Float = 20, spacing: Float = 18
        let inner = width - 2 * pad
        let format = controller.outputFormat
        let description = format.settingsDescription
        let aacNote = controller.aacAvailable ? nil : (Platform.isWindows
            ? "AAC needs ffmpeg.exe next to DoublEnder.exe."
            : "AAC needs ffmpeg — install it with your package manager.")
        let descriptionH = r.paragraphHeight(description, .sans, 11, width: inner, lineSpacing: 1.25)
        let aacNoteH = aacNote.map { r.paragraphHeight($0, .sans, 11, width: inner, lineSpacing: 1.25) + 4 } ?? 0
        let notesWarningH: Float = format == .wav ? 5 + 14 : 0
        let height = pad + 18 + spacing + (14 + 5 + 31) + spacing + (14 + 5 + 70 + notesWarningH)
            + spacing + (14 + 5 + 2 * 26 + aacNoteH + 6 + descriptionH) + pad
        let rect = Rectangle(x: Theme.windowWidth / 2 - width / 2,
                             y: max(8, (Theme.windowHeight - height) / 2), width: width, height: height)
        dimBackdrop(0.35)
        panel(rect)
        if input.pressed, input.isInteractive(.popover), rect.contains(input.mouse) {
            input.focusedField = nil  // a field below takes it back if it was the target
        }

        var y = rect.y + pad
        let x = rect.x + pad
        r.text("SETTINGS", .sansBold, 13, at: Vector2(x: x, y: y), color: Theme.vpAmber, tracking: 1.8)
        y += 18 + spacing

        // FILENAME
        fieldLabel("FILENAME", x: x, y: y)
        y += 14 + 5
        let suffix = "_<date>.\(format.fileExtension)"
        let suffixW = r.measure(suffix, .mono, 11).x
        let field = Rectangle(x: x, y: y, width: inner - suffixW - 8, height: 31)
        var prefix = controller.filenameBase
        textField(id: "filename", rect: field, text: &prefix, placeholder: AppInfo.defaultRecordingPrefix,
                  multiline: false, limit: 64)
        if prefix != controller.filenameBase { controller.filenameBase = prefix }
        r.text(suffix, .mono, 11, x: field.maxX + 8, centerY: field.midY,
               color: Theme.secondaryText.opacity(0.55))
        y += 31 + spacing

        // NOTES
        fieldLabel("NOTES", x: x, y: y)
        y += 14 + 5
        var notes = controller.notes
        textField(id: "notes", rect: Rectangle(x: x, y: y, width: inner, height: 70), text: &notes,
                  placeholder: "Saved as metadata in the recording", multiline: true, limit: 1000)
        if notes != controller.notes { controller.notes = notes }
        y += 70
        if format == .wav {
            r.text("Notes are not stored in WAV files.", .sans, 11, at: Vector2(x: x, y: y + 5),
                   color: Theme.secondaryText.opacity(0.55))
            y += notesWarningH
        }
        y += spacing

        // FORMAT
        fieldLabel("FORMAT", x: x, y: y)
        y += 14 + 5
        for option in OutputFormat.allCases {
            let enabled = option == .wav || controller.aacAvailable
            let row = Rectangle(x: x - 4, y: y, width: inner + 8, height: 26)
            let state = input.button("format-\(option.rawValue)", row, layer: .popover, enabled: enabled)
            if state.hovered { r.fillRounded(row, radius: 4, Theme.vpAmber.opacity(0.08)) }
            let dot = Vector2(x: x + 7, y: row.midY)
            DrawRing(dot, 5.5, 7, 0, 360, 32, Theme.vpAmber.opacity(enabled ? 0.9 : 0.3))
            if option == format { DrawCircleV(dot, 3.5, Theme.vpAmber) }
            r.text(option.displayName, .sans, 13, x: x + 22, centerY: row.midY,
                   color: Theme.secondaryText.opacity(enabled ? 1 : 0.4))
            if state.clicked { controller.outputFormat = option }
            y += 26
        }
        if let aacNote {
            r.paragraph(aacNote, .sans, 11, centerX: x + inner / 2, top: y + 4, width: inner,
                        color: Theme.recordAccent.opacity(0.85), lineSpacing: 1.25)
            y += aacNoteH
        }
        y += 6
        drawLeftParagraph(description, x: x, top: y, width: inner)
        return rect
    }

    private func fieldLabel(_ text: String, x: Float, y: Float) {
        r.text(text, .sansBold, 11, at: Vector2(x: x, y: y), color: Theme.vpAmber, tracking: 1.2)
    }

    private func drawLeftParagraph(_ text: String, x: Float, top: Float, width: Float) {
        for (i, line) in r.wrap(text, .sans, 11, width: width).enumerated() {
            r.text(line, .sans, 11, at: Vector2(x: x, y: top + Float(i) * 11 * 1.25),
                   color: Theme.secondaryText.opacity(0.55))
        }
    }

    private func textField(id: String, rect: Rectangle, text: inout String, placeholder: String,
                           multiline: Bool, limit: Int) {
        if input.pressInside(rect, layer: .popover) { input.focusedField = id }
        let focused = input.focusedField == id
        // A dialog over the panel takes the keyboard.
        if input.isInteractive(.popover) {
            TextEditing.edit(&text, id: id, input: input, multiline: multiline, limit: limit)
        }

        r.fillRounded(rect, radius: 3, Theme.secondaryFieldBg)
        r.strokeRounded(rect, radius: 3, width: 1, focused ? Theme.vpAmber.opacity(0.7) : Theme.panelStroke)
        if rect.contains(input.mouse) && input.isInteractive(.popover) {
            input.cursor = MOUSE_CURSOR_IBEAM
        }

        let size: Float = 14
        let lineH: Float = 18
        let textArea = rect.insetBy(10, multiline ? 6 : 6)
        BeginScissorMode(Int32(rect.x + 2), Int32(rect.y + 2), Int32(rect.width - 4), Int32(rect.height - 4))
        defer { EndScissorMode() }
        if text.isEmpty {
            r.text(placeholder, .sans, multiline ? 12 : size, at: Vector2(x: textArea.x, y: textArea.y + (multiline ? 3 : 0)),
                   color: Theme.secondaryText.opacity(0.45))
            if focused { caret(at: Vector2(x: textArea.x, y: textArea.y), height: lineH) }
            return
        }
        if multiline {
            let lines = r.wrap(text, .sans, size, width: textArea.width)
            // Keep the end, where typing happens, in view.
            let maxLines = Int(textArea.height / lineH)
            let shown = lines.suffix(maxLines)
            for (i, line) in shown.enumerated() {
                r.text(line, .sans, size, at: Vector2(x: textArea.x, y: textArea.y + Float(i) * lineH),
                       color: Theme.secondaryText)
            }
            if focused, let last = shown.last {
                let w = r.measure(last, .sans, size).x
                caret(at: Vector2(x: textArea.x + w + 1, y: textArea.y + Float(shown.count - 1) * lineH), height: lineH)
            }
        } else {
            // Scroll a long single line so its end stays visible.
            let w = r.measure(text, .sans, size).x
            let offset = max(0, w - textArea.width + 4)
            r.text(text, .sans, size, at: Vector2(x: textArea.x - offset, y: textArea.y + 0.5), color: Theme.secondaryText)
            if focused { caret(at: Vector2(x: textArea.x - offset + w + 1, y: textArea.y), height: lineH) }
        }
    }

    private func caret(at p: Vector2, height: Float) {
        guard Int(GetTime() * 2) % 2 == 0 else { return }
        DrawRectangleRec(Rectangle(x: p.x, y: p.y + 1, width: 1.5, height: height), Theme.vpAmber)
    }

    // MARK: - Dialogs

    func drawDialog(_ dialog: Dialog, time: Double) {
        dimBackdrop(0.55)
        let pad: Float = 26, vpad: Float = 22, spacing: Float = 14
        let iconSize: Float = 30
        let buttonHeight: Float = 10 * 1.3 + 14
        let buttonWidths = dialog.buttons.map { r.measure($0.title, .sansBold, 10, tracking: 1.5).x + 36 }
        let buttonsRowW = buttonWidths.reduce(0, +) + Float(max(0, buttonWidths.count - 1)) * 10

        // 380 wide like the Mac's, wider when the buttons need it, and the
        // buttons stack when even the window is too narrow.
        let maxWidth = Theme.windowWidth - 32
        let width = min(maxWidth, max(380, buttonsRowW + 2 * pad))
        let stacked = buttonsRowW > width - 2 * pad
        let textWidth = width - 2 * pad

        let titleH: Float = 16
        let bodyH = r.paragraphHeight(dialog.message, .sans, 11, width: textWidth, tracking: 0.3)
        let noteH = dialog.note.map { r.paragraphHeight($0, .sans, 11, width: textWidth, tracking: 0.3) } ?? 0
        let fileH: Float = dialog.fileName == nil ? 0 : 14
        let buttonsH: Float = dialog.showsSpinner ? 0
            : (stacked ? Float(dialog.buttons.count) * (buttonHeight + 8) - 8 : buttonHeight)
        var parts: [Float] = [dialog.showsSpinner ? 32 : iconSize, titleH, bodyH]
        if fileH > 0 { parts.append(fileH) }
        if noteH > 0 { parts.append(noteH) }
        if buttonsH > 0 { parts.append(buttonsH + 2) }
        let contentH = parts.reduce(0, +) + Float(parts.count - 1) * spacing
        let height = max(240, contentH + 2 * vpad)
        let card = Rectangle(x: Theme.windowWidth / 2 - width / 2, y: Theme.windowHeight / 2 - height / 2,
                             width: width, height: height)

        r.fillRounded(card.insetBy(-6, -6), radius: 20, Theme.screenGlow.opacity(0.10))
        r.fillRounded(card.insetBy(-3, -3), radius: 17, Theme.screenGlow.opacity(0.12))
        r.fillRounded(card, radius: 14, Theme.dialogBackground)
        r.strokeRounded(card, radius: 14, width: 1.5, Theme.dialogBorder, inside: true)

        var y = card.y + (height - contentH) / 2
        let cx = card.midX
        if dialog.showsSpinner {
            r.spinner(center: Vector2(x: cx, y: y + 16), size: 32, color: Theme.dialogIcon, time: time)
            y += 32 + spacing
        } else {
            let c = Vector2(x: cx, y: y + iconSize / 2)
            switch dialog.icon {
            case .warning: r.warningIcon(center: c, size: iconSize, color: Theme.dialogIcon, cutout: Theme.dialogBackground)
            case .success: r.successIcon(center: c, size: iconSize, color: Theme.dialogIcon, cutout: Theme.dialogBackground)
            case .question:
                r.draw(r.texture("icon_input"), in: Rectangle(x: c.x - iconSize / 2, y: c.y - iconSize / 2,
                                                             width: iconSize, height: iconSize), tint: Theme.dialogIcon)
            }
            y += iconSize + spacing
        }

        let titleCenter = Vector2(x: cx, y: y + titleH / 2)
        r.glowText(dialog.title, .sansBold, 12, centeredAt: titleCenter, color: rgbGlowOuter, radius: 16, tracking: 1.8)
        r.glowText(dialog.title, .sansBold, 12, centeredAt: titleCenter, color: rgbGlowInner, radius: 6, tracking: 1.8)
        r.text(dialog.title, .sansBold, 12, centeredAt: titleCenter, color: Theme.dialogTitle, tracking: 1.8)
        y += titleH + spacing
        r.paragraph(dialog.message, .sans, 11, centerX: cx, top: y, width: textWidth, color: Theme.dialogBody, tracking: 0.3)
        y += bodyH + spacing
        if let fileName = dialog.fileName {
            let shown = r.truncate(fileName, .monoBold, 10, width: textWidth, mode: .middle)
            r.text(shown, .monoBold, 10, centeredAt: Vector2(x: cx, y: y + fileH / 2), color: Theme.dialogFileName)
            y += fileH + spacing
        }
        if let note = dialog.note {
            r.paragraph(note, .sans, 11, centerX: cx, top: y, width: textWidth, color: Theme.dialogBody, tracking: 0.3)
            y += noteH + spacing
        }
        guard !dialog.showsSpinner else { return }

        y += 2
        var pressedButton: Dialog.Button?
        var x = cx - buttonsRowW / 2
        for (i, button) in dialog.buttons.enumerated() {
            let rect: Rectangle
            if stacked {
                let w = max(buttonWidths.max() ?? 0, 200)
                rect = Rectangle(x: cx - w / 2, y: y + Float(i) * (buttonHeight + 8), width: w, height: buttonHeight)
            } else {
                rect = Rectangle(x: x, y: y, width: buttonWidths[i], height: buttonHeight)
                x += buttonWidths[i] + 10
            }
            let state = input.button("dialog-\(dialog.id)-\(i)", rect, layer: .dialog)
            let fill = button.isDefault ? Theme.dialogIcon.opacity(state.hovered ? 0.28 : 0.16)
                : (state.hovered ? Theme.dialogIcon.opacity(0.12) : Theme.dialogFieldBg)
            r.fillRounded(rect, radius: 4, Theme.dialogFieldBg)
            r.fillRounded(rect, radius: 4, fill)
            r.strokeRounded(rect, radius: 4, width: 1.5, Theme.dialogIcon)
            r.text(button.title, .sansBold, 10, centeredAt: rect.center, color: Theme.dialogIcon, tracking: 1.5)
            if state.clicked { pressedButton = button }
        }
        // Return takes the default button, Escape the cancel one.
        if pressedButton == nil, input.keyPressed(KEY_ENTER) || input.keyPressed(KEY_KP_ENTER) {
            pressedButton = dialog.buttons.first(where: \.isDefault) ?? (dialog.buttons.count == 1 ? dialog.buttons.first : nil)
        }
        if pressedButton == nil, input.keyPressed(KEY_ESCAPE) {
            pressedButton = dialog.buttons.first(where: \.isCancel) ?? (dialog.buttons.count == 1 ? dialog.buttons.first : nil)
        }
        if let pressedButton {
            controller.dialogs.press(pressedButton, in: dialog)
        }
    }

    private var rgbGlowInner: Color { Theme.rgb(0xF5A623, 0.85) }
    private var rgbGlowOuter: Color { Theme.rgb(0xC87800, 0.40) }
}
