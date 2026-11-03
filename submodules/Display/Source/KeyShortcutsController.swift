import UIKit

public protocol KeyShortcutResponder {
    var keyShortcuts: [KeyShortcut] { get };
}

public class KeyShortcutsController: UIResponder {
    private var effectiveShortcuts: [KeyShortcut]?
    private var viewControllerEnumerator: (@escaping (ContainableController) -> Bool) -> Void
    
    public static var isAvailable: Bool {
        return true
    }
    
    public init(enumerator: @escaping (@escaping (ContainableController) -> Bool) -> Void) {
        self.viewControllerEnumerator = enumerator
        super.init()
    }
    
    public override var keyCommands: [UIKeyCommand]? {
        let shortcuts = self.collectShortcuts()
        self.effectiveShortcuts = shortcuts
        return shortcuts.map { $0.uiKeyCommand }
    }
    
    private func collectShortcuts() -> [KeyShortcut] {
        var shortcuts: [KeyShortcut] = []
        
        self.viewControllerEnumerator({ viewController -> Bool in
            guard let viewController = viewController as? KeyShortcutResponder else {
                return true
            }
            // `keyShortcuts` is an EXPENSIVE computed property (a controller rebuilds its whole shortcut
            // array — closures and all — on every access). UIKit queries `keyCommands` on every hardware
            // key-down, so this getter is hot. Read it ONCE per controller: the old
            // `removeAll(where: { viewController.keyShortcuts.contains($0) })` re-invoked the getter once
            // per already-accumulated shortcut (quadratic rebuilds), then `append` invoked it again.
            let viewControllerShortcuts = viewController.keyShortcuts
            shortcuts.removeAll(where: { viewControllerShortcuts.contains($0) })
            shortcuts.append(contentsOf: viewControllerShortcuts)
            return true
        })
        return shortcuts
    }
    
    @objc func handleKeyCommand(_ command: UIKeyCommand) {
        if let shortcut = findShortcut(for: command) {
            shortcut.action()
        }
    }
    
    private func findShortcut(for command: UIKeyCommand) -> KeyShortcut? {
        if let shortcuts = self.effectiveShortcuts {
            for shortcut in shortcuts {
                if shortcut.isEqual(to: command) {
                    return shortcut
                }
            }
        }
        return nil
    }
    
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if let keyCommand = sender as? UIKeyCommand, let _ = findShortcut(for: keyCommand) {
            return true
        } else if action == #selector(KeyShortcutsController.handleMainMenuCommand(_:)), let command = sender as? UICommand, self.findShortcut(forMainMenuCommand: command) != nil {
            return true
        } else {
            return super.canPerformAction(action, withSender: sender)
        }
    }
    
    public override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if let keyCommand = sender as? UIKeyCommand, let _ = findShortcut(for: keyCommand) {
            return self
        } else if action == #selector(KeyShortcutsController.handleMainMenuCommand(_:)), let command = sender as? UICommand, self.findShortcut(forMainMenuCommand: command) != nil {
            return self
        } else {
            return super.target(forAction: action, withSender: sender)
        }
    }
    
    public override var canBecomeFirstResponder: Bool {
        return true
    }
    
    // MARK: - A-6 Menu bar (iPadOS 26+)
    
    /// Fills Nanogram's menu bar menus (`MainMenuSection`) with the shortcuts the visible screens offer now
    /// (`mainMenuItems`). An item with a key equivalent is a `UIKeyCommand` with the same action as the screen's own
    /// key command, so choosing it runs exactly what the key does; a title-only one (`showsKeyEquivalent` false) runs
    /// it through `handleMainMenuCommand`.
    @available(iOS 26.0, *)
    public override func provider(for deferredElement: UIDeferredMenuElement) -> UIDeferredMenuElement.Provider? {
        guard let section = MainMenuSection(deferredElementIdentifier: deferredElement.identifier.rawValue) else {
            return super.provider(for: deferredElement)
        }
        return UIDeferredMenuElement.Provider { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            let shortcuts = self.collectShortcuts()
            self.effectiveShortcuts = shortcuts
            let items = mainMenuItems(section: section, shortcuts: shortcuts.map { (title: $0.title, input: $0.input, modifiers: $0.modifiers) })
            completion(items.map { item -> UIMenuElement in
                let command: UICommand
                if item.showsKeyEquivalent {
                    command = UIKeyCommand(title: item.title, action: #selector(KeyShortcutsController.handleKeyCommand(_:)), input: item.input, modifierFlags: item.modifiers)
                } else {
                    command = UICommand(title: item.title, action: #selector(KeyShortcutsController.handleMainMenuCommand(_:)), propertyList: KeyShortcutsController.mainMenuPropertyList(input: item.input, modifiers: item.modifiers))
                }
                if !item.isRepeatable {
                    command.repeatBehavior = .nonRepeatable
                }
                return command
            })
        }
    }
    
    private static func mainMenuPropertyList(input: String, modifiers: UIKeyModifierFlags) -> String {
        return "\(modifiers.rawValue):\(input)"
    }
    
    private func findShortcut(forMainMenuCommand command: UICommand) -> KeyShortcut? {
        guard let propertyList = command.propertyList as? String else {
            return nil
        }
        return (self.effectiveShortcuts ?? []).first(where: { KeyShortcutsController.mainMenuPropertyList(input: $0.input, modifiers: $0.modifiers) == propertyList })
    }
    
    @objc func handleMainMenuCommand(_ command: UICommand) {
        self.effectiveShortcuts = self.collectShortcuts()
        if let shortcut = self.findShortcut(forMainMenuCommand: command) {
            shortcut.action()
        }
    }
}
