// Projects catalog commands into AppKit menu items without owning menu layout.
import Cocoa
import DanTermProtocol

/// Supplies the one selector used by every configurable menu equivalent.
@MainActor
@objc protocol ConfigurableMenuCommandTarget {
    func performConfiguredCommand(_ sender: NSMenuItem)
}

/// Finds one catalog entry by its stable identity.
func commandDescriptor(id: KeybindingActionID) -> CommandDescriptor {
    guard let descriptor = commandCatalog.first(where: { $0.id == id }) else {
        preconditionFailure("unknown configurable command \(id.rawValue)")
    }
    return descriptor
}

/// Builds the visible primary item and hidden alternate items for one command.
enum CommandMenuItemFactory {
    @MainActor
    static func items(for descriptor: CommandDescriptor) -> [NSMenuItem] {
        let chords: [KeyChord?] = descriptor.defaultChords.isEmpty ? [nil] : descriptor.defaultChords.map(Optional.some)
        return chords.enumerated().map { index, chord in
            let item = NSMenuItem(
                title: descriptor.title,
                action: #selector(ConfigurableMenuCommandTarget.performConfiguredCommand(_:)),
                keyEquivalent: chord.map(keyEquivalent) ?? ""
            )
            item.representedObject = descriptor.id.rawValue
            if let chord {
                item.keyEquivalentModifierMask = modifierMask(for: chord)
            }
            if index > 0 {
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            return item
        }
    }

    /// Applies one canonical chord to an existing item, or clears its binding.
    static func configure(_ item: NSMenuItem, chord: KeyChord?) {
        item.keyEquivalent = chord.map(keyEquivalent) ?? ""
        item.keyEquivalentModifierMask = chord.map(modifierMask) ?? []
    }

    static func keyEquivalent(_ chord: KeyChord) -> String {
        let token = chord.compact.split(separator: "+").last.map(String.init) ?? ""
        switch token {
        case "plus": return "+"
        case "space": return " "
        case "tab": return "\t"
        case "enter": return "\r"
        case "escape": return "\u{1b}"
        case "backspace": return "\u{8}"
        case "delete": return "\u{7f}"
        case "left": return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case "right": return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case "up": return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "down": return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "home": return String(Character(UnicodeScalar(NSHomeFunctionKey)!))
        case "end": return String(Character(UnicodeScalar(NSEndFunctionKey)!))
        case "pageup": return String(Character(UnicodeScalar(NSPageUpFunctionKey)!))
        case "pagedown": return String(Character(UnicodeScalar(NSPageDownFunctionKey)!))
        default:
            return chord.modifiers.contains(.shift) ? token.uppercased() : token
        }
    }

    private static func modifierMask(for chord: KeyChord) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { mask.insert(.command) }
        if chord.modifiers.contains(.control) { mask.insert(.control) }
        if chord.modifiers.contains(.option) { mask.insert(.option) }
        // AppKit's "+" equivalent already represents the Shift-produced glyph.
        if chord.modifiers.contains(.shift), chord.key != .named(.plus) { mask.insert(.shift) }
        return mask
    }
}

/// Owns the mutable hidden twins that project the effective binding map into AppKit.
@MainActor
final class ConfigurableMenuBindingSurface {
    private weak var menu: NSMenu?
    private let notificationCenter: NotificationCenter
    private var lastBindings: [KeybindingActionID: [KeyChord]] = [:]

    init(menu: NSMenu, notificationCenter: NotificationCenter = .default) {
        self.menu = menu
        self.notificationCenter = notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(inputSourceDidChange(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    func apply(_ bindings: [KeybindingActionID: [KeyChord]]) {
        lastBindings = bindings
        reapplyForCurrentInputSource()
    }

    private func reapplyForCurrentInputSource() {
        guard let menu else { return }
        for descriptor in commandCatalog {
            let rawID = descriptor.id.rawValue
            let existing = menu.items.recursiveItems.filter { $0.representedObject as? String == rawID }
            guard let primary = existing.first, let parent = primary.menu else { continue }
            let chords = lastBindings[descriptor.id] ?? descriptor.defaultChords
            CommandMenuItemFactory.configure(primary, chord: chords.first)

            for extra in existing.dropFirst() { parent.removeItem(extra) }
            guard chords.count > 1, let primaryIndex = parent.items.firstIndex(of: primary) else { continue }
            for (offset, chord) in chords.dropFirst().enumerated() {
                let twin = CommandMenuItemFactory.items(for: CommandDescriptor(
                    action: descriptor.action,
                    title: descriptor.title,
                    category: descriptor.category,
                    defaultChords: [chord],
                    scope: descriptor.scope,
                    isAvailableDuringTextEditing: descriptor.isAvailableDuringTextEditing,
                    gesture: descriptor.gesture
                ))[0]
                twin.isHidden = true
                twin.allowsKeyEquivalentWhenHidden = true
                parent.insertItem(twin, at: primaryIndex + offset + 1)
            }
        }
    }

    @objc private func inputSourceDidChange(_ notification: Notification) {
        reapplyForCurrentInputSource()
    }
}

private extension Array where Element == NSMenuItem {
    var recursiveItems: [NSMenuItem] {
        flatMap { item in [item] + (item.submenu?.items.recursiveItems ?? []) }
    }
}

@MainActor
extension NSMenu {
    /// Adds every default menu item for one configurable catalog command.
    @discardableResult
    func addCommand(_ id: KeybindingActionID) -> [NSMenuItem] {
        let items = CommandMenuItemFactory.items(for: commandDescriptor(id: id))
        items.forEach(addItem)
        return items
    }
}
