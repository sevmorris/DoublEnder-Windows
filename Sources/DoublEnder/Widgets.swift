import CRaylib
import Foundation

/// Per-frame mouse and keyboard state, and immediate-mode controls.
///
/// Controls belong to a layer; only the topmost open layer takes input, so
/// a dialog blocks the faceplate behind it as a modal window would.
final class Input {
    enum Layer: Int, Comparable {
        case base, popover, dialog
        static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }
    }

    struct ButtonState {
        var hovered = false
        var held = false
        var clicked = false
    }

    private(set) var topLayer: Layer = .base
    private(set) var mouse = Vector2(x: 0, y: 0)
    private(set) var pressed = false
    private(set) var released = false
    private(set) var down = false
    /// A control took this frame's press; otherwise it may start a drag.
    private(set) var pressClaimed = false
    /// The cursor this frame asks for; applied once, at the end.
    var cursor = MOUSE_CURSOR_DEFAULT
    private var appliedCursor = MOUSE_CURSOR_DEFAULT
    private var activeID: String?

    // Keyboard, gathered once per frame.
    private(set) var typed: [Character] = []
    private(set) var keysPressed: Set<Int32> = []
    private(set) var control = false
    private(set) var shift = false

    /// The text field taking typing, if any.
    var focusedField: String?

    func beginFrame(topLayer: Layer) {
        self.topLayer = topLayer
        mouse = GetMousePosition()
        pressed = IsMouseButtonPressed(Int32(MOUSE_BUTTON_LEFT.rawValue))
        released = IsMouseButtonReleased(Int32(MOUSE_BUTTON_LEFT.rawValue))
        down = IsMouseButtonDown(Int32(MOUSE_BUTTON_LEFT.rawValue))
        pressClaimed = false
        cursor = MOUSE_CURSOR_DEFAULT

        typed.removeAll()
        while case let codepoint = GetCharPressed(), codepoint > 0 {
            if let scalar = Unicode.Scalar(UInt32(codepoint)) { typed.append(Character(scalar)) }
        }
        keysPressed.removeAll()
        for key in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_BACKSPACE, KEY_TAB, KEY_Q, KEY_W, KEY_V, KEY_M] {
            let code = Int32(key.rawValue)
            if IsKeyPressed(code) || IsKeyPressedRepeat(code) { keysPressed.insert(code) }
        }
        control = IsKeyDown(Int32(KEY_LEFT_CONTROL.rawValue)) || IsKeyDown(Int32(KEY_RIGHT_CONTROL.rawValue))
        shift = IsKeyDown(Int32(KEY_LEFT_SHIFT.rawValue)) || IsKeyDown(Int32(KEY_RIGHT_SHIFT.rawValue))
    }

    func endFrame() {
        if released || !down { activeID = nil }
        // raylib makes a new system cursor on every SetMouseCursor call, so
        // only call it when the cursor changes.
        if cursor != appliedCursor {
            SetMouseCursor(Int32(cursor.rawValue))
            appliedCursor = cursor
        }
    }

    func keyPressed(_ key: KeyboardKey) -> Bool { keysPressed.contains(Int32(key.rawValue)) }

    /// Marks the press as handled without a control (e.g. closing a popover).
    func claimPress() { pressClaimed = true }

    func isInteractive(_ layer: Layer) -> Bool { layer == topLayer }

    func button(_ id: String, _ rect: Rectangle, layer: Layer, enabled: Bool = true) -> ButtonState {
        var state = ButtonState()
        guard enabled, isInteractive(layer) else { return state }
        state.hovered = rect.contains(mouse)
        if state.hovered {
            cursor = MOUSE_CURSOR_POINTING_HAND
            if pressed {
                activeID = id
                pressClaimed = true
            }
        }
        state.held = activeID == id && down && state.hovered
        state.clicked = activeID == id && released && state.hovered
        return state
    }

    /// True when a press landed inside `rect` on `layer` (taking it, so it
    /// starts no window drag).
    func pressInside(_ rect: Rectangle, layer: Layer) -> Bool {
        guard pressed, isInteractive(layer), rect.contains(mouse) else { return false }
        pressClaimed = true
        return true
    }
}

/// A plain text field: typing and Backspace at the end, Ctrl+V to paste.
/// Enough for a filename prefix and a note.
enum TextEditing {
    /// Applies this frame's typing to `text` if `id` has focus. Returns
    /// true when Enter ends a single-line field.
    @discardableResult
    static func edit(_ text: inout String, id: String, input: Input, multiline: Bool, limit: Int) -> Bool {
        guard input.focusedField == id else { return false }
        var submitted = false
        if input.control && input.keyPressed(KEY_V), let clip = GetClipboardText() {
            var pasted = String(cString: clip)
            if !multiline { pasted = pasted.replacingOccurrences(of: "\n", with: " ") }
            text += pasted.filter { !$0.isASCII || $0.asciiValue! >= 32 || $0 == "\n" }
        } else if !input.control {
            text += String(input.typed)
        }
        if input.keyPressed(KEY_BACKSPACE), !text.isEmpty {
            if input.control {
                // Ctrl+Backspace: the last word.
                let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                if let space = trimmed.lastIndex(where: { $0 == " " || $0 == "\n" }) {
                    text = String(trimmed[...space])
                } else {
                    text = ""
                }
            } else {
                text.removeLast()
            }
        }
        if input.keyPressed(KEY_ENTER) || input.keyPressed(KEY_KP_ENTER) {
            if multiline && !input.control {
                text += "\n"
            } else {
                submitted = true
                input.focusedField = nil
            }
        }
        if input.keyPressed(KEY_ESCAPE) || input.keyPressed(KEY_TAB) {
            input.focusedField = nil
        }
        if text.count > limit { text = String(text.prefix(limit)) }
        return submitted
    }
}
