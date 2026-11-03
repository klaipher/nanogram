import Foundation
import UIKit
import Intents
import Display
import TelegramCore
import SwiftSignalKit
import TelegramUIPreferences
import TelegramPresentationData
import AvatarNode
import AccountContext
import NotificationsPresentationData

nonisolated(unsafe) private let savedMessagesSuggestionAvatar: INImage? = savedMessagesAvatar.pngData().flatMap(INImage.init(imageData:))

private let savedMessagesAvatar: UIImage = {
    return generateImage(CGSize(width: 60.0, height: 60.0), rotatedContext: { size, context in
        var locations: [CGFloat] = [1.0, 0.0]
               
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [UIColor(rgb: 0x2a9ef1).cgColor, UIColor(rgb: 0x72d5fd).cgColor] as CFArray, locations: &locations)!
               
        context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
        
        let factor = size.width / 60.0
        context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
        context.scaleBy(x: factor, y: -factor)
        context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
        
        if let savedMessagesIcon = generateTintedImage(image: UIImage(bundleImageName: "Avatar/SavedMessagesIcon"), color: .white) {
            context.draw(savedMessagesIcon.cgImage!, in: CGRect(origin: CGPoint(x: floor((size.width - savedMessagesIcon.size.width) / 2.0), y: floor((size.height - savedMessagesIcon.size.height) / 2.0)), size: savedMessagesIcon.size))
        }
    })!
}()

public enum SendMessageIntentContext {
    case chat
    case share
}

public enum SendMessageIntentSubject: CaseIterable {
    case contact
    case savedMessages
    case privateChat
    case group
    
    func toString() -> String {
        switch self {
            case .contact:
                return "contact"
            case .savedMessages:
                return "savedMessages"
            case .privateChat:
                return "privateChat"
            case .group:
                return "group"
        }
    }
}

/// Encoded suggestion avatars, by peer and photo: every send donates again, and the avatar only
/// changes with the photo.
private final class SuggestionAvatarCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: INImage] = [:]

    func get(_ key: String) -> INImage? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.images[key]
    }

    func set(_ key: String, _ image: INImage) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.images.count >= 64 {
            self.images.removeAll()
        }
        self.images[key] = image
    }
}

private let suggestionAvatarCache = SuggestionAvatarCache()

private func suggestionAvatarImage(_ image: UIImage) -> INImage? {
    guard let data = image.pngData() else {
        return nil
    }
    return INImage(imageData: data)
}

/// The avatar a suggestion shows: the full photo once it is downloaded, never the blurred mini
/// thumbnail first (which made each send donate twice), or the letters after 2 s without it.
private func suggestionAvatar(account: Account, peer: EngineRawPeer) -> Signal<INImage?, NoError> {
    let size = CGSize(width: 60.0, height: 60.0)
    let representation = peer.smallProfileImage
    let cacheKey = "\(peer.id.toInt64()):\(representation?.resource.id.stringRepresentation ?? "letters")"
    if let cached = suggestionAvatarCache.get(cacheKey) {
        return .single(cached)
    }
    
    let lettersImage: () -> INImage? = {
        let avatarFont = avatarPlaceholderFont(size: 26.0)
        guard let image = generateImage(size, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            drawPeerAvatarLetters(context: context, size: size, font: avatarFont, letters: peer.displayLetters, peerId: peer.id, nameColor: peer.nameColor)
        }) else {
            return nil
        }
        return suggestionAvatarImage(image)
    }
    
    let completeData: Signal<Data?, NoError>
    if let imageData = peerAvatarImageData(account: account, peerReference: PeerReference(peer), authorOfMessage: nil, representation: representation, synchronousLoad: false) {
        completeData = imageData
        |> filter { value in
            if let (_, type) = value, case .blurred = type {
                return false
            }
            return true
        }
        |> map { value -> Data? in
            return value?.0
        }
        |> take(1)
        |> timeout(2.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
    } else {
        completeData = .single(nil)
    }
    
    return completeData
    |> deliverOn(Queue.concurrentDefaultQueue())
    |> map { data -> INImage? in
        if let data, let photo = UIImage(data: data), let image = generateImage(size, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            let photoSize = photo.size.aspectFilled(size)
            UIGraphicsPushContext(context)
            photo.draw(in: CGRect(origin: CGPoint(x: (size.width - photoSize.width) / 2.0, y: (size.height - photoSize.height) / 2.0), size: photoSize))
            UIGraphicsPopContext()
        }), let result = suggestionAvatarImage(image) {
            suggestionAvatarCache.set(cacheKey, result)
            return result
        }
        // Not cached, so a photo that downloads later replaces the letters.
        return lettersImage()
    }
}

public func donateSendMessageIntent(account: Account, sharedContext: SharedAccountContext, intentContext: SendMessageIntentContext, peerIds: [EnginePeer.Id]) {
    let _ = (sharedContext.accountManager.transaction { transaction -> Bool in
        if case .none = transaction.getAccessChallengeData() {
            return true
        } else {
            return false
        }
    }
    |> mapToSignal { unlocked -> Signal<[(EngineRawPeer, SendMessageIntentSubject, INImage?)], NoError> in
        if unlocked {
            return sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.intentsSettings])
            |> take(1)
            |> mapToSignal { sharedData -> Signal<[(EngineRawPeer, SendMessageIntentSubject)], NoError> in
                let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.intentsSettings]?.get(IntentsSettings.self) ?? IntentsSettings.defaultSettings
                if let accountId = settings.account, accountId != account.peerId {
                    return .single([])
                }
                if case .chat = intentContext, settings.onlyShared {
                    return .single([])
                }
                
                return TelegramEngine(account: account).data.get(
                    EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)),
                    EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.IsContact.init)),
                    EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Messages.ChatListGroup.init))
                )
                |> map { peerMap, isContactMap, chatListGroupMap -> [(EngineRawPeer, SendMessageIntentSubject)] in
                    var peers: [(EngineRawPeer, SendMessageIntentSubject)] = []
                    for peerId in peerIds {
                        if peerId.namespace != Namespaces.Peer.SecretChat, let maybePeer = peerMap[peerId], let peer = maybePeer {
                            var subject: SendMessageIntentSubject?
                            let chatListGroup = chatListGroupMap[peerId]
                            if chatListGroup == .archive {
                                continue
                            }
                            if peerId.namespace == Namespaces.Peer.CloudUser {
                                if peerId == account.peerId {
                                    if !settings.savedMessages {
                                        continue
                                    }
                                    subject = .savedMessages
                                } else if let isContact = isContactMap[peerId], isContact {
                                    if !settings.contacts {
                                        continue
                                    }
                                    subject = .contact
                                } else {
                                    if !settings.privateChats {
                                        continue
                                    }
                                    subject = .privateChat
                                }
                            } else if peerId.namespace == Namespaces.Peer.CloudGroup {
                                if !settings.groups {
                                     continue
                                }
                                subject = .group
                            } else if case let .channel(peer) = peer {
                                if case .group = peer.info {
                                    if !settings.groups {
                                        continue
                                    }
                                    subject = .group
                                } else {
                                    continue
                                }
                            } else {
                                continue
                            }
                            
                            if let subject = subject {
                                peers.append((peer._asPeer(), subject))
                            }
                        }
                    }
                    return peers
                }
            }
            |> mapToSignal { peers -> Signal<[(EngineRawPeer, SendMessageIntentSubject, INImage?)], NoError> in
                var signals: [Signal<(EngineRawPeer, SendMessageIntentSubject, INImage?), NoError>] = []
                for (peer, subject) in peers {
                    if peer.id == account.peerId {
                        signals.append(.single((peer, subject, savedMessagesSuggestionAvatar)))
                    } else {
                        signals.append(suggestionAvatar(account: account, peer: peer)
                        |> map { image -> (EngineRawPeer, SendMessageIntentSubject, INImage?) in
                            return (peer, subject, image)
                        })
                    }
                }
                return combineLatest(signals)
                |> take(1)
            }
        } else {
            return .single([])
        }
    }
    |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { peers in
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        
        for (peer, _, personImage) in peers {
            let identifier = SendMessageSuggestions.conversationIdentifier(peerId: peer.id.toInt64())
            let recipientHandle = INPersonHandle(value: identifier, type: .unknown)
            let displayTitle: String
            var nameComponents = PersonNameComponents()
            
            if let peer = peer as? TelegramUser {
                if peer.botInfo != nil || peer.flags.contains(.isSupport) {
                    continue
                }
                
                if peer.id == account.peerId {
                    displayTitle = presentationData.strings.DialogList_SavedMessages
                    nameComponents.givenName = displayTitle
                } else {
                    displayTitle = EnginePeer(peer).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                    nameComponents.givenName = peer.firstName
                    nameComponents.familyName = peer.lastName
                }
            } else {
                displayTitle = EnginePeer(peer).compactDisplayTitle
                nameComponents.givenName = displayTitle
            }
            
            let recipient = INPerson(personHandle: recipientHandle, nameComponents: nameComponents, displayName: displayTitle, image: personImage, contactIdentifier: nil, customIdentifier: identifier)
           
            let intent = INSendMessageIntent(recipients: [recipient], outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: INSpeakableString(spokenPhrase: displayTitle), conversationIdentifier: identifier, serviceName: nil, sender: nil, attachments: nil)
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .outgoing
            interaction.groupIdentifier = SendMessageSuggestions.groupIdentifier(peerId: peer.id.toInt64())
            interaction.donate { error in
                if let error = error {
                    print(error)
                }
            }
        }
    })
}

public func deleteSendMessageIntents(peerId: EnginePeer.Id) {
    INInteraction.delete(with: SendMessageSuggestions.groupIdentifier(peerId: peerId.toInt64()))
}

public func deleteAllSendMessageIntents() {
    INInteraction.deleteAll()
}
