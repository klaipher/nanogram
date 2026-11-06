import Foundation
import UIKit
import AsyncDisplayKit
import TelegramCore
import SwiftSignalKit
import Display
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import LocalizedPeerData
import AlertUI
import PresentationDataUtils
import TextFormat
import Markdown
import TelegramNotices
import TelegramStringFormatting
import ChatPresentationInterfaceState
import TextNodeWithEntities
import AnimationCache
import MultiAnimationRenderer
import AccessoryPanelNode
import AppBundle
import ComponentFlow
import AlertComponent

func textStringForForwardedMessage(_ message: EngineRawMessage, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> (text: NSAttributedString, entities: [MessageTextEntity], isMedia: Bool) {
    for attribute in message.attributes {
        if let attribute = attribute as? RichTextMessageAttribute {
            return (attribute.instantPage.previewAttributedText(strings: strings, dateTimeFormat: dateTimeFormat, associatedMedia: { message.associatedMedia[$0].map(EngineMedia.init) }), [], false)
        }
    }
    for media in message.media {
        switch media {
        case _ as TelegramMediaImage:
            return (NSAttributedString(string: strings.Message_Photo), [], true)
        case let file as TelegramMediaFile:
            if file.isVideoSticker || file.isAnimatedSticker {
                return (NSAttributedString(string: strings.Message_Sticker), [], true)
            }
            var fileName: String = strings.Message_File
            for attribute in file.attributes {
                switch attribute {
                case .Sticker:
                    return (NSAttributedString(string: strings.Message_Sticker), [], true)
                case let .FileName(name):
                    fileName = name
                case let .Audio(isVoice, _, title, performer, _):
                    if isVoice {
                        return (NSAttributedString(string: strings.Message_Audio), [], true)
                    } else {
                        if let title = title, let performer = performer, !title.isEmpty, !performer.isEmpty {
                            return (NSAttributedString(string: title + " — " + performer), [], true)
                        } else if let title = title, !title.isEmpty {
                            return (NSAttributedString(string: title), [], true)
                        } else if let performer = performer, !performer.isEmpty {
                            return (NSAttributedString(string: performer), [], true)
                        } else {
                            return (NSAttributedString(string: strings.Message_Audio), [], true)
                        }
                    }
                case .Video:
                    if file.isAnimated {
                        return (NSAttributedString(string: strings.Message_Animation), [], true)
                    } else {
                        return (NSAttributedString(string: strings.Message_Video), [], true)
                    }
                default:
                    break
                }
            }
            return (NSAttributedString(string: fileName), [], true)
        case _ as TelegramMediaContact:
            return (NSAttributedString(string: strings.Message_Contact), [], true)
        case let game as TelegramMediaGame:
            return (NSAttributedString(string: game.title), [], true)
        case _ as TelegramMediaMap:
            return (NSAttributedString(string: strings.Message_Location), [], true)
        case _ as TelegramMediaAction:
            return (NSAttributedString(), [], true)
        case _ as TelegramMediaPoll:
            return (NSAttributedString(string: strings.ForwardedPolls(1)), [], true)
        case let todo as TelegramMediaTodo:
            return (NSAttributedString(string: todo.text), [], true)
        case _ as TelegramMediaWidget where message.text.isEmpty:
            return (NSAttributedString(string: strings.Message_Widget), [], true)
        case let dice as TelegramMediaDice:
            return (NSAttributedString(string: dice.emoji), [], true)
        case let invoice as TelegramMediaInvoice:
            return (NSAttributedString(string: invoice.title), [], true)
        default:
            break
        }
    }
    return (NSAttributedString(string: message.text), message.textEntitiesAttribute?.entities ?? [], false)
}

public final class ForwardAccessoryPanelNode: AccessoryPanelNode {
    /// What the panel shows for one set of inputs. The chat picker lays itself out on every
    /// keystroke in its comment field and every selection change, and each layout calls
    /// `updateState` with the same inputs, so the strings and their layout are kept between calls.
    private struct Content {
        struct Key: Equatable {
            let messagesVersion: Int
            let theme: PresentationTheme
            let strings: PresentationStrings
            let dateTimeFormat: PresentationDateTimeFormat
            let hideNames: Bool

            static func ==(lhs: Key, rhs: Key) -> Bool {
                return lhs.messagesVersion == rhs.messagesVersion && lhs.theme === rhs.theme && lhs.strings === rhs.strings && lhs.dateTimeFormat == rhs.dateTimeFormat && lhs.hideNames == rhs.hideNames
            }
        }

        let key: Key
        let title: NSAttributedString
        let text: NSAttributedString
        let accessibilityLabel: String
    }

    /// The text layout last applied: valid while both nodes still hold these strings and the width
    /// is the same.
    private struct TextLayout {
        let title: NSAttributedString
        let text: NSAttributedString
        let constrainedSize: CGSize
        let titleSize: CGSize
        let textSize: CGSize
    }

    private let messageDisposable = MetaDisposable()
    public let messageIds: [EngineMessage.Id]
    private var messages: [EngineRawMessage] = [] {
        didSet {
            self.messagesVersion += 1
        }
    }
    private var messagesVersion = 0
    private var content: Content?
    private var textLayout: TextLayout?
    
    let closeButton: HighlightableButtonNode
    let lineNode: ASImageNode
    let iconView: UIImageView
    let titleNode: ImmediateTextNode
    let textNode: ImmediateTextNodeWithEntities
    private var originalText: NSAttributedString?
    
    let actionArea: AccessibilityAreaNode
    
    let context: AccountContext
    var theme: PresentationTheme
    var strings: PresentationStrings
    var fontSize: PresentationFontSize
    var nameDisplayOrder: PresentationPersonNameOrder
    var forwardOptionsState: ChatInterfaceForwardOptionsState?
    
    private var validLayout: (size: CGSize, inset: CGFloat, interfaceState: ChatPresentationInterfaceState)?
    
    public init(context: AccountContext, messageIds: [EngineMessage.Id], theme: PresentationTheme, strings: PresentationStrings, fontSize: PresentationFontSize, nameDisplayOrder: PresentationPersonNameOrder, forwardOptionsState: ChatInterfaceForwardOptionsState?, animationCache: AnimationCache?, animationRenderer: MultiAnimationRenderer?) {
        self.context = context
        self.messageIds = messageIds
        self.theme = theme
        self.strings = strings
        self.fontSize = fontSize
        self.nameDisplayOrder = nameDisplayOrder
        self.forwardOptionsState = forwardOptionsState
        
        self.closeButton = HighlightableButtonNode()
        self.closeButton.accessibilityLabel = strings.VoiceOver_DiscardPreparedContent
        self.closeButton.setImage(PresentationResourcesChat.chatInputPanelCloseIconImage(theme), for: [])
        self.closeButton.hitTestSlop = UIEdgeInsets(top: -8.0, left: -8.0, bottom: -8.0, right: -8.0)
        self.closeButton.displaysAsynchronously = false
        
        self.lineNode = ASImageNode()
        self.lineNode.displayWithoutProcessing = false
        self.lineNode.displaysAsynchronously = false
        self.lineNode.image = PresentationResourcesChat.chatInputPanelVerticalSeparatorLineImage(theme)
        
        self.iconView = UIImageView()
        self.iconView.image = UIImage(bundleImageName: "Chat/Input/Accessory Panels/ForwardSettingsIcon")?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = theme.chat.inputPanel.panelControlAccentColor
        
        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.displaysAsynchronously = false
        
        self.textNode = ImmediateTextNodeWithEntities()
        self.textNode.maximumNumberOfLines = 1
        self.textNode.displaysAsynchronously = false
        
        self.actionArea = AccessibilityAreaNode()
        
        super.init()
        
        self.closeButton.addTarget(self, action: #selector(self.closePressed), forControlEvents: [.touchUpInside])
        self.addSubnode(self.closeButton)
        
        self.addSubnode(self.lineNode)
        self.view.addSubview(self.iconView)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.actionArea)
        
        if let animationCache = animationCache, let animationRenderer = animationRenderer {
            self.textNode.arguments = TextNodeWithEntities.Arguments(
                context: context,
                cache: animationCache,
                renderer: animationRenderer,
                placeholderColor: theme.list.mediaPlaceholderColor,
                attemptSynchronous: false
            )
        }
        
        self.messageDisposable.set((context.engine.data.get(EngineDataMap(messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init)))
        |> map { messageMap -> [EngineRawMessage] in
            return messageIds.compactMap { messageMap[$0]??._asMessage() }
        }
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            if let strongSelf = self {
                if messages.isEmpty {
                    strongSelf.dismiss?()
                } else {
                    strongSelf.messages = messages

                    if let (size, inset, interfaceState) = strongSelf.validLayout {
                        strongSelf.updateState(size: size, inset: inset, interfaceState: interfaceState)
                    }
                    
                    let _ = (ApplicationSpecificNotice.getChatForwardOptionsTip(accountManager: strongSelf.context.sharedContext.accountManager)
                    |> deliverOnMainQueue).start(next: { [weak self] count in
                        if let strongSelf = self, count < 3 {
                            Queue.mainQueue().after(3.0) {
                                if let snapshotView = strongSelf.textNode.view.snapshotContentTree() {
                                    let text: String
                                    if let (size, _, _) = strongSelf.validLayout, size.width > 320.0 {
                                        text = strongSelf.strings.Conversation_ForwardOptions_TapForOptions
                                    } else {
                                        text = strongSelf.strings.Conversation_ForwardOptions_TapForOptionsShort
                                    }
                                    
                                    strongSelf.textNode.attributedText = NSAttributedString(string: text, font: Font.regular(15.0), textColor: strongSelf.theme.chat.inputPanel.secondaryTextColor)
                                    
                                    strongSelf.view.addSubview(snapshotView)
                                    
                                    if let (size, inset, interfaceState) = strongSelf.validLayout {
                                        strongSelf.updateState(size: size, inset: inset, interfaceState: interfaceState)
                                    }
                                    
                                    strongSelf.textNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                                        snapshotView?.removeFromSuperview()
                                    })
                                }
                                
                                let _ = ApplicationSpecificNotice.incrementChatForwardOptionsTip(accountManager: strongSelf.context.sharedContext.accountManager).start()
                            }
                        }
                    })
                }
            }
        }))
    }
    
    deinit {
        self.messageDisposable.dispose()
    }
    
    override public func didLoad() {
        super.didLoad()
        
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }
    
    override public func animateIn() {
        self.iconView.layer.animateScale(from: 0.001, to: 1.0, duration: 0.2)
    }
    
    override public func animateOut() {
        self.iconView.layer.animateScale(from: 1.0, to: 0.001, duration: 0.2, removeOnCompletion: false)
    }
    
    override public func updateThemeAndStrings(theme: PresentationTheme, strings: PresentationStrings) {
        self.updateThemeAndStrings(theme: theme, strings: strings, forwardOptionsState: self.forwardOptionsState)
    }
    
    public func updateThemeAndStrings(theme: PresentationTheme, strings: PresentationStrings, forwardOptionsState: ChatInterfaceForwardOptionsState?, force: Bool = false) {
        if force || self.theme !== theme || self.strings !== strings || self.forwardOptionsState != forwardOptionsState {
            self.theme = theme
            self.strings = strings
            self.forwardOptionsState = forwardOptionsState
            
            self.closeButton.setImage(PresentationResourcesChat.chatInputPanelCloseIconImage(theme), for: [])
            self.lineNode.image = PresentationResourcesChat.chatInputPanelVerticalSeparatorLineImage(theme)
            self.iconView.tintColor = theme.chat.inputPanel.panelControlAccentColor
            
            let filteredMessages = self.messages
            
            var title = ""
            if filteredMessages.count == 1 {
                title = self.strings.Conversation_ForwardOptions_ForwardTitleSingle
            } else {
                title = self.strings.Conversation_ForwardOptions_ForwardTitle(Int32(filteredMessages.count))
            }
            
            self.titleNode.attributedText = NSAttributedString(string: title, font: Font.medium(15.0), textColor: self.theme.chat.inputPanel.panelControlAccentColor)
            
            if let attributedText = self.textNode.attributedText {
                let updatedText = NSMutableAttributedString(attributedString: attributedText)
                updatedText.addAttribute(.foregroundColor, value: self.theme.chat.inputPanel.secondaryTextColor, range: NSRange(location: 0, length: updatedText.length))
                self.textNode.attributedText = updatedText
                self.originalText = updatedText
            }
            
            if let (size, inset, interfaceState) = self.validLayout {
                self.updateState(size: size, inset: inset, interfaceState: interfaceState)
            }
        }
    }

    override public func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: constrainedSize.width, height: 45.0)
    }

    override public func updateState(size: CGSize, inset: CGFloat, interfaceState: ChatPresentationInterfaceState) {
        self.validLayout = (size, inset, interfaceState)

        let bounds = CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: 45.0))
        let leftInset: CGFloat = 55.0 + inset
        let rightInset: CGFloat = 55.0 + inset
        let textLineInset: CGFloat = 10.0
        let textRightInset: CGFloat = 20.0

        let closeButtonSize = CGSize(width: 44.0, height: bounds.height)
        let closeButtonFrame = CGRect(origin: CGPoint(x: bounds.width - closeButtonSize.width - inset, y: 2.0), size: closeButtonSize)
        self.closeButton.frame = closeButtonFrame
        self.closeButton.isHidden = interfaceState.renderedPeer == nil

        self.actionArea.frame = CGRect(origin: CGPoint(x: leftInset, y: 2.0), size: CGSize(width: closeButtonFrame.minX - leftInset, height: bounds.height))

        self.lineNode.frame = CGRect(origin: CGPoint(x: leftInset, y: 8.0), size: CGSize(width: 2.0, height: bounds.size.height - 10.0))

        if let icon = self.iconView.image {
            self.iconView.frame = CGRect(origin: CGPoint(x: 7.0 + inset, y: 10.0), size: icon.size)
        }
        
        let key = Content.Key(messagesVersion: self.messagesVersion, theme: self.theme, strings: self.strings, dateTimeFormat: interfaceState.dateTimeFormat, hideNames: interfaceState.interfaceState.forwardOptionsState?.hideNames == true)
        let content: Content
        if let current = self.content, current.key == key {
            content = current
        } else {
            content = self.makeContent(key: key, dateTimeFormat: interfaceState.dateTimeFormat)
            self.content = content
        }
        
        // Text written into the nodes from elsewhere (the theme refresh, the options tip) is
        // replaced, as every layout always did.
        if self.titleNode.attributedText !== content.title {
            self.titleNode.attributedText = content.title
        }
        if self.textNode.attributedText !== content.text {
            self.textNode.attributedText = content.text
        }
        self.originalText = content.text
        self.textNode.visibility = true
        
        self.actionArea.accessibilityLabel = content.accessibilityLabel
        
        let constrainedSize = CGSize(width: bounds.size.width - leftInset - textLineInset - rightInset - textRightInset, height: bounds.size.height)
        let titleSize: CGSize
        let textSize: CGSize
        if let textLayout = self.textLayout, textLayout.title === content.title, textLayout.text === content.text, textLayout.constrainedSize == constrainedSize {
            titleSize = textLayout.titleSize
            textSize = textLayout.textSize
        } else {
            titleSize = self.titleNode.updateLayout(constrainedSize)
            textSize = self.textNode.updateLayout(constrainedSize)
            self.textLayout = TextLayout(title: content.title, text: content.text, constrainedSize: constrainedSize, titleSize: titleSize, textSize: textSize)
        }
        self.titleNode.frame = CGRect(origin: CGPoint(x: leftInset + textLineInset, y: 7.0), size: titleSize)
        self.textNode.frame = CGRect(origin: CGPoint(x: leftInset + textLineInset, y: 25.0), size: textSize)
    }
    
    private func makeContent(key: Content.Key, dateTimeFormat: PresentationDateTimeFormat) -> Content {
        let messages = self.messages
        let strings = self.strings
        
        var authors = ""
        var uniquePeerIds = Set<EnginePeer.Id>()
        var title = ""
        var text = NSMutableAttributedString(string: "")
        
        for message in messages {
            if let author = message.forwardInfo?.author ?? message.effectiveAuthor, !uniquePeerIds.contains(author.id) {
                uniquePeerIds.insert(author.id)
                if !authors.isEmpty {
                    authors.append(", ")
                }
                if author.id == self.context.account.peerId {
                    authors.append(strings.DialogList_You)
                } else {
                    authors.append(EnginePeer(author).compactDisplayTitle)
                }
            }
        }
        
        var richAccessibilityText: String?
        if messages.count == 1 {
            title = strings.Conversation_ForwardOptions_ForwardTitleSingle
            let (string, entities, _) = textStringForForwardedMessage(messages[0], strings: strings, dateTimeFormat: dateTimeFormat)
            if messages[0].attributes.contains(where: { $0 is RichTextMessageAttribute }) {
                richAccessibilityText = "\(authors): \(instantPagePreviewPlainText(string))"
            }
            
            text = NSMutableAttributedString(attributedString: NSAttributedString(string: "\(authors): ", font: Font.regular(15.0), textColor: self.theme.chat.inputPanel.secondaryTextColor))
            
            let additionalText = NSMutableAttributedString(attributedString: styleInstantPagePreview(string, font: Font.regular(15.0), italicFont: Font.italic(15.0), textColor: self.theme.chat.inputPanel.secondaryTextColor))
            for entity in entities {
                switch entity.type {
                case let .CustomEmoji(_, fileId):
                    let range = NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound)
                    if range.lowerBound >= 0 && range.upperBound <= additionalText.length {
                        additionalText.addAttribute(ChatTextInputAttributes.customEmoji, value: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: nil, fileId: fileId, file: messages[0].associatedMedia[EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile), range: range)
                    }
                default:
                    break
                }
            }
            
            text.append(renderInstantPagePreviewIcons(additionalText, font: Font.regular(15.0), textColor: self.theme.chat.inputPanel.secondaryTextColor))
        } else {
            title = strings.Conversation_ForwardOptions_ForwardTitle(Int32(clamping: messages.count))
            text = NSMutableAttributedString(attributedString: NSAttributedString(string: strings.Conversation_ForwardFrom(authors).string, font: Font.regular(15.0), textColor: self.theme.chat.inputPanel.secondaryTextColor))
        }
        
        if key.hideNames {
            richAccessibilityText = nil
            text = NSMutableAttributedString(attributedString: NSAttributedString(string: strings.Conversation_ForwardOptions_SenderNamesRemoved, font: Font.regular(15.0), textColor: self.theme.chat.inputPanel.secondaryTextColor))
        }

        let accessibilityText = richAccessibilityText ?? text.string
        let renderedText = renderInstantPagePreviewIcons(text, font: Font.regular(15.0), textColor: self.theme.chat.inputPanel.secondaryTextColor)
        
        let headerString: String
        if messages.count == 1 {
            headerString = "Forward message"
        } else {
            headerString = "Forward messages"
        }
        
        return Content(
            key: key,
            title: NSAttributedString(string: title, font: Font.medium(15.0), textColor: self.theme.chat.inputPanel.panelControlAccentColor),
            text: renderedText,
            accessibilityLabel: "\(headerString). From: \(authors).\n\(accessibilityText)"
        )
    }
    
    @objc private func closePressed() {
        guard let message = self.messages.first, let peer = message.peers[message.id.peerId] else {
            return
        }
        let peerId = peer.id
        let peerDisplayTitle = EnginePeer(peer).displayTitle(strings: self.strings, displayOrder: self.nameDisplayOrder)

        let messageCount = Int32(self.messageIds.count)
        let messages = self.strings.Conversation_ForwardOptions_Messages(messageCount)
        let string: PresentationStrings.FormattedString
        if peerId == self.context.account.peerId {
            string = self.strings.Conversation_ForwardOptions_TextSaved(messages)
        } else if peerId.namespace == Namespaces.Peer.CloudUser {
            string = self.strings.Conversation_ForwardOptions_TextPersonal(messages, peerDisplayTitle)
        } else {
            string = self.strings.Conversation_ForwardOptions_Text(messages, peerDisplayTitle)
        }

        let font = Font.regular(15.0)
        let boldFont = Font.semibold(15.0)
        let body = MarkdownAttributeSet(font: font, textColor: self.theme.actionSheet.primaryTextColor)
        let bold = MarkdownAttributeSet(font: boldFont, textColor: self.theme.actionSheet.primaryTextColor)
        let text = addAttributesToStringWithRanges(string._tuple, body: body, argumentAttributes: [0: bold, 1: bold], textAlignment: .natural)
        
        var content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = []
        content.append(AnyComponentWithIdentity(
            id: "title",
            component: AnyComponent(
                AlertTitleComponent(
                    title: strings.Conversation_ForwardOptions_Title(messageCount)
                )
            )
        ))
        content.append(AnyComponentWithIdentity(
            id: "text",
            component: AnyComponent(
                AlertTextComponent(content: .attributed(text))
            )
        ))
        
        let alertController = AlertScreen(
            context: context,
            configuration: AlertScreen.Configuration(actionAlignment: .vertical),
            content: content,
            actions: [
                .init(title: strings.Conversation_ForwardOptions_ShowOptions, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.interfaceInteraction?.presentForwardOptions(self.view)
                    Queue.mainQueue().after(0.5) {
                        self.updateThemeAndStrings(theme: self.theme, strings: self.strings, forwardOptionsState: self.forwardOptionsState, force: true)
                    }
                    let _ = ApplicationSpecificNotice.incrementChatForwardOptionsTip(accountManager: self.context.sharedContext.accountManager, count: 3).start()
                }),
                .init(title: strings.Conversation_ForwardOptions_CancelForwarding, type: .destructive, action: { [weak self] in
                    self?.dismiss?()
                })
            ]
        )
        self.interfaceInteraction?.presentController(alertController, nil)
    }
    
    private var previousTapTimestamp: Double?
    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            let timestamp = CFAbsoluteTimeGetCurrent()
            if let previousTapTimestamp = self.previousTapTimestamp, previousTapTimestamp + 1.0 > timestamp {
                return
            }
            self.previousTapTimestamp = CFAbsoluteTimeGetCurrent()
            self.interfaceInteraction?.presentForwardOptions(self.view)
            Queue.mainQueue().after(1.5) {
                self.updateThemeAndStrings(theme: self.theme, strings: self.strings, forwardOptionsState: self.forwardOptionsState, force: true)
            }
            
            let _ = ApplicationSpecificNotice.incrementChatForwardOptionsTip(accountManager: self.context.sharedContext.accountManager, count: 3).start()
        }
    }
}
