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
