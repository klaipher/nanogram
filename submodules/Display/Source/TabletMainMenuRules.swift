import Foundation
import UIKit

// A-6 (iPadOS 27 audit, 2026-11-03): the iPadOS 26 menu bar. Since iPadOS 26 the hold-⌘ shortcut overlay is gone and
// an app's shortcuts are found in the menu bar, which Nanogram did not populate. The owner chose File / View / Chat /
// Format. The menus are filled from the shortcuts the visible screens offer at the moment a menu opens
// (`KeyShortcutsController`, through focus-based deferred elements), so an item is listed only while it works and
// does what the same key does. These are the pure decisions; `KeyShortcutsController+MainMenu.swift` applies them.

/// The menu bar menus Nanogram fills.
public enum MainMenuSection: String, CaseIterable {
    case file
    case view
    case chat
    case format

    /// The identifier of the focus-based deferred element that lists this menu's shortcuts.
    public var deferredElementIdentifier: String {
        return "org.nanogram.menu." + self.rawValue
    }

    public init?(deferredElementIdentifier: String) {
        guard let section = MainMenuSection.allCases.first(where: { $0.deferredElementIdentifier == deferredElementIdentifier }) else {
            return nil
        }
        self = section
    }
}

/// One shortcut as the menu bar lists it.
public struct MainMenuItem: Equatable {
    public let title: String
    public let input: String
    public let modifiers: UIKeyModifierFlags
    /// False when the system's own menus already bind this key (⌘W is the window's Close): the item is listed with
    /// its title only and runs the same shortcut, so the menu never holds the key twice.
    public let showsKeyEquivalent: Bool
    /// Destructive or modal items (Close Chat, Lock) do not repeat while the key is held.
    public let isRepeatable: Bool

    public init(title: String, input: String, modifiers: UIKeyModifierFlags, showsKeyEquivalent: Bool, isRepeatable: Bool) {
        self.title = title
        self.input = input
        self.modifiers = modifiers
        self.showsKeyEquivalent = showsKeyEquivalent
        self.isRepeatable = isRepeatable
    }
}

/// Whether Nanogram installs its menu bar: on a tablet only (iPadOS 26 is where the system shows it; `available` is
/// the `#available(iOS 26.0, *)` check). Phones keep upstream's responder-chain shortcuts alone.
public func mainMenuIsInstalled(deviceType: DeviceType, available: Bool) -> Bool {
    return deviceType == .tablet && available
}

/// Every shortcut the menu bar lists, in menu order: (menu, key, modifiers). Anything else stays keyboard-only.
private let mainMenuTable: [(section: MainMenuSection, input: String, modifiers: UIKeyModifierFlags)] = {
    var table: [(section: MainMenuSection, input: String, modifiers: UIKeyModifierFlags)] = [
        (.file, "N", [.command]),
        (.file, "L", [.command]),
        (.file, "W", [.command])
    ]
    for digit in 1 ... 9 {
        table.append((.view, "\(digit)", [.command]))
    }
    let rest: [(section: MainMenuSection, input: String, modifiers: UIKeyModifierFlags)] = [
        (.chat, "F", [.command]),
        (.chat, "I", [.command, .control]),
        (.chat, UIKeyCommand.inputUpArrow, [.alternate]),
        (.chat, UIKeyCommand.inputDownArrow, [.alternate]),
        (.chat, UIKeyCommand.inputUpArrow, [.alternate, .shift]),
        (.chat, UIKeyCommand.inputDownArrow, [.alternate, .shift]),
        // ⌘B, ⌘I and ⌘U are the system Format menu's own (Font), which stays: text views outside the composer use it.
        (.format, "X", [.command, .shift]),
        (.format, "M", [.command, .shift]),
        (.format, "P", [.command, .shift]),
        (.format, "K", [.command]),
        (.format, "N", [.command, .shift])
    ]
    table.append(contentsOf: rest)
    return table
}()

/// Keys the system's own menus bind while Nanogram's are installed: ⌘W is the window's Close (File), ⌘F the Edit
/// menu's Find (web views use it). Such items are listed by title only (`MainMenuItem.showsKeyEquivalent`); the key
/// itself keeps reaching the screen's shortcut as before (audit A-5 is the on-device check of which one wins).
private func mainMenuKeyIsSystemBound(input: String, modifiers: UIKeyModifierFlags) -> Bool {
    return modifiers == [.command] && (input == "W" || input == "F")
}

/// Items that must not repeat while the key is held: closing a chat and locking the app.
private func mainMenuItemIsRepeatable(input: String, modifiers: UIKeyModifierFlags) -> Bool {
    if modifiers == [.command] && (input == "W" || input == "L") {
        return false
    }
    return true
}

private func mainMenuTableIndex(input: String, modifiers: UIKeyModifierFlags) -> Int? {
    return mainMenuTable.firstIndex(where: { $0.input == input && $0.modifiers == modifiers })
}

/// The items of `section` for the shortcuts on offer (`(title, input, modifiers)`, in the order the screens list
/// them, later screens first wins as in `KeyShortcutsController`): untitled shortcuts are left out, every key appears
/// once.
public func mainMenuItems(section: MainMenuSection, shortcuts: [(title: String, input: String, modifiers: UIKeyModifierFlags)]) -> [MainMenuItem] {
    var titles: [Int: String] = [:]
    for shortcut in shortcuts {
        guard let index = mainMenuTableIndex(input: shortcut.input, modifiers: shortcut.modifiers), mainMenuTable[index].section == section else {
            continue
        }
        // A later screen's shortcut replaces an earlier one with the same key (`KeyShortcutsController`); one
        // without a title then hides the item rather than keeping a title that no longer describes the key.
        titles[index] = shortcut.title
    }
    return titles.keys.sorted().compactMap { index -> MainMenuItem? in
        guard let title = titles[index], !title.isEmpty else {
            return nil
        }
        let entry = mainMenuTable[index]
        return MainMenuItem(
            title: title,
            input: entry.input,
            modifiers: entry.modifiers,
            showsKeyEquivalent: !mainMenuKeyIsSystemBound(input: entry.input, modifiers: entry.modifiers),
            isRepeatable: mainMenuItemIsRepeatable(input: entry.input, modifiers: entry.modifiers)
        )
    }
}
