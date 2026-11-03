import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import SwiftSignalKit
import AccountContext
import SwiftUI
import TelegramUIPreferences

public func presentTranslateScreen(
    context: AccountContext,
    text: String,
    entities: [MessageTextEntity] = [],
    canCopy: Bool,
    fromLanguage: String?,
    toLanguage: String? = nil,
    isExpanded: Bool = false,
    ignoredLanguages: [String]? = nil,
    replaceText: ((String, [MessageTextEntity]) -> Void)? = nil,
    translateChat: ((String, String) -> Void)? = nil,
    pushController: @escaping (ViewController) -> Void = { _ in },
    presentController: @escaping (ViewController) -> Void = { _ in },
    wasDismissed: (() -> Void)? = nil,
    sourceRect: CGRect? = nil,
    display: (ViewController) -> Void
) {
    let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
    var useSystemTranslation = false
    switch translationConfiguration.manual {
    case .system:
        if #available(iOS 18.0, *) {
            useSystemTranslation = true
        }
    default:
        break
    }
    
    if useSystemTranslation {
        presentSystemTranslateScreen(context: context, text: text, sourceRect: sourceRect, replaceText: replaceText)
    } else {
    }
}

/// iPad (`sourceRect`, in the window's coordinates): the popover points at the translated text, not at the whole
/// window, and a composer translation gets the system's Replace button (`replaceText`; the translation is plain text).
/// iPhone presents the system sheet as upstream.
private func presentSystemTranslateScreen(context: AccountContext, text: String, sourceRect: CGRect?, replaceText: ((String, [MessageTextEntity]) -> Void)?) {
    if #available(iOS 18.0, *), let rootViewController = context.sharedContext.mainWindow?.viewController?.view.window?.rootViewController {
        let isTablet = context.sharedContext.mainWindow?.deviceType == .tablet
        var anchorRect: CGRect?
        if isTablet, let sourceRect, let window = rootViewController.view.window {
            anchorRect = nativePopoverSourceRect(windowBounds: window.bounds, sourceFrame: sourceRect)
        }
        var replacementAction: ((String) -> Void)?
        if isTablet, let replaceText {
            replacementAction = { translated in
                DispatchQueue.main.async {
                    replaceText(translated, [])
                }
            }
        }
        var dismissImpl: (() -> Void)?
        let pickerView = TranslateScreenHostingView(text: text, anchorRect: anchorRect, replacementAction: replacementAction, completionHandler: { [weak rootViewController] in
            DispatchQueue.main.async(execute: {
                guard let presentedController = rootViewController?.presentedViewController, presentedController.isBeingDismissed == false else { return }
                dismissImpl?()
            })
        })
        let hostingController = UIHostingController(rootView: pickerView)
        hostingController.view.isHidden = true
        hostingController.modalPresentationStyle = .overCurrentContext
        rootViewController.present(hostingController, animated: true)
        dismissImpl = { [weak hostingController] in
            Queue.mainQueue().after(0.4, {
                hostingController?.dismiss(animated: false)
            })
        }
    }
}

@available(iOS 18.0, *)
struct TranslateScreenHostingView: View {
    @State var presented = true
    var text: String
    var anchorRect: CGRect?
    var replacementAction: ((String) -> Void)?
    var handler: () -> Void
    
    init(text: String, anchorRect: CGRect? = nil, replacementAction: ((String) -> Void)? = nil, completionHandler: @escaping () -> Void) {
        self.text = text
        self.anchorRect = anchorRect
        self.replacementAction = replacementAction
        self.handler = completionHandler
    }
    
    var body: some View {
        Group {
            if let anchorRect {
                // iPad: the view fills the whole window, so the anchor rect is in window coordinates.
                Color.clear
                    .ignoresSafeArea()
                    .translationPresentation(
                        isPresented: $presented,
                        text: text,
                        attachmentAnchor: .rect(.rect(anchorRect)),
                        replacementAction: replacementAction
                    )
            } else {
                Spacer()
                    .translationPresentation(
                        isPresented: $presented,
                        text: text,
                        replacementAction: replacementAction
                    )
            }
        }
            .onChange(of: presented) { newValue in
                if newValue == false {
                    handler()
                }
            }
    }
}
