import Foundation

/// A modal the faceplate draws over itself. One model covers what the Mac
/// build splits across NSAlert, the themed confirmation windows and the
/// crash-recovery window: on a borderless raylib window every one of them
/// is an in-window card.
public struct Dialog: Identifiable {
    public enum Icon {
        case warning
        case success
        case question
    }

    public struct Button {
        public let title: String
        /// Return triggers the default button, Escape the cancel button.
        public let isDefault: Bool
        public let isCancel: Bool
        public let action: () -> Void

        public init(_ title: String, isDefault: Bool = false, isCancel: Bool = false,
                    action: @escaping () -> Void = {}) {
            self.title = title
            self.isDefault = isDefault
            self.isCancel = isCancel
            self.action = action
        }
    }

    public let id = UUID()
    public let icon: Icon
    public let title: String
    public let message: String
    /// A file name, shown in the dim amber monospace line.
    public let fileName: String?
    /// A second paragraph after the file name.
    public let note: String?
    public let buttons: [Button]
    /// Work in progress: a spinner instead of buttons.
    public let showsSpinner: Bool

    public init(icon: Icon, title: String, message: String, fileName: String? = nil,
                note: String? = nil, buttons: [Button], showsSpinner: Bool = false) {
        self.icon = icon
        self.title = title
        self.message = message
        self.fileName = fileName
        self.note = note
        self.buttons = buttons
        self.showsSpinner = showsSpinner
    }
}

/// The dialogs waiting to be seen; the first is on screen.
public final class DialogQueue {
    public private(set) var items: [Dialog] = []

    public var current: Dialog? { items.first }
    public var isShowing: Bool { !items.isEmpty }

    public func present(_ dialog: Dialog, first: Bool = false) {
        if first { items.insert(dialog, at: 0) } else { items.append(dialog) }
    }

    /// Removes `dialog` and runs the button's action, which may present a
    /// follow-up (first: true keeps a multi-step flow in front).
    public func press(_ button: Dialog.Button, in dialog: Dialog) {
        items.removeAll { $0.id == dialog.id }
        button.action()
    }

    public func replace(_ id: UUID, with dialog: Dialog) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = dialog
        } else {
            items.insert(dialog, at: 0)
        }
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}
