import Foundation
import UIKit

/// A-6: installs Nanogram's File / View / Chat / Format menu bar content on iPadOS 26+ (`mainMenuIsInstalled`).
/// Each menu holds one focus-based deferred element (`MainMenuSection.deferredElementIdentifier`) that
/// `KeyShortcutsController` fulfils from the visible screens' shortcuts every time the menu opens, so the menus list
/// only what works now and need no rebuild when screens change. The system's own groups Nanogram has no use for go:
/// new window (one window only, which also frees ⌘N for New Message), document and printing. Find and the Format
/// menu's Font items stay, since web and text views outside the composer use them; Nanogram's items that would
/// repeat their keys are listed by title only (`mainMenuItems`).
@available(iOS 26.0, *)
public enum MainMenuInstaller {
    /// Titles of the menus the system does not provide (localized by the app; read at every build).
    public static var chatMenuTitle: () -> String = { "Chat" }
    public static var formatMenuTitle: () -> String = { "Format" }

    public static let chatMenuIdentifier = UIMenu.Identifier("org.nanogram.menu.chat.root")
    public static let formatMenuIdentifier = UIMenu.Identifier("org.nanogram.menu.format.root")

    public static func install() {
        let configuration = UIMainMenuSystem.Configuration()
        configuration.newScenePreference = .removed
        configuration.documentPreference = .removed
        configuration.printingPreference = .removed
        UIMainMenuSystem.shared.setBuildConfiguration(configuration, buildHandler: { builder in
            MainMenuInstaller.build(builder)
        })
    }

    /// Rebuilds the menus, for a change of the titles' language.
    public static func setNeedsRebuild() {
        UIMainMenuSystem.shared.setNeedsRebuild()
    }

    private static func deferredElement(_ section: MainMenuSection) -> UIDeferredMenuElement {
        return UIDeferredMenuElement.usingFocus(identifier: UIDeferredMenuElement.Identifier(section.deferredElementIdentifier), shouldCacheItems: false)
    }

    private static func inlineGroup(_ section: MainMenuSection) -> UIMenu {
        return UIMenu(title: "", options: .displayInline, children: [MainMenuInstaller.deferredElement(section)])
    }

    static func build(_ builder: UIMenuBuilder) {
        if builder.menu(for: .file) != nil {
            builder.insertElements([MainMenuInstaller.inlineGroup(.file)], atStartOfMenu: .file)
        }
        if builder.menu(for: .view) != nil {
            builder.insertElements([MainMenuInstaller.inlineGroup(.view)], atStartOfMenu: .view)
        }

        let chatMenu = UIMenu(title: MainMenuInstaller.chatMenuTitle(), identifier: MainMenuInstaller.chatMenuIdentifier, children: [MainMenuInstaller.deferredElement(.chat)])
        if builder.menu(for: .view) != nil {
            builder.insertSibling(chatMenu, afterMenu: .view)
        } else if builder.menu(for: .edit) != nil {
            builder.insertSibling(chatMenu, afterMenu: .edit)
        }

        if builder.menu(for: .format) != nil {
            builder.insertElements([MainMenuInstaller.inlineGroup(.format)], atStartOfMenu: .format)
        } else {
            let formatMenu = UIMenu(title: MainMenuInstaller.formatMenuTitle(), identifier: MainMenuInstaller.formatMenuIdentifier, children: [MainMenuInstaller.deferredElement(.format)])
            if builder.menu(for: .edit) != nil {
                builder.insertSibling(formatMenu, afterMenu: .edit)
            }
        }
    }
}
