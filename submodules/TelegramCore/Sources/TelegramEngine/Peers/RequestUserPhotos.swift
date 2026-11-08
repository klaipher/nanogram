
import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit


public struct TelegramPeerPhoto {
    public let image: TelegramMediaImage
    public let reference: TelegramMediaImageReference?
    public let date: Int32
    public let index: Int
    public let totalCount: Int
    public let messageId: MessageId?
    public init(image: TelegramMediaImage, reference: TelegramMediaImageReference?, date: Int32, index: Int, totalCount: Int, messageId: MessageId?) {
        self.image = image
        self.reference = reference
        self.date = date
        self.index = index
        self.totalCount = totalCount
        self.messageId = messageId
    }
}

/// Identifies one photo-list request: the list changes when the peer's photo does, so the peer's current
/// photo is part of the key and a changed photo never meets an older list.
struct PeerPhotosRequestKey: Hashable {
    let accountPeerId: PeerId
    let peerId: PeerId
    let currentPhotos: [String]
}

/// `profileImageRepresentations` reduced to what tells two photos apart.
func peerPhotosFingerprint(_ representations: [TelegramMediaImageRepresentation]) -> [String] {
    return representations.map { "\($0.resource.id.stringRepresentation)#\($0.isPersonal ? 1 : 0)" }
}

/// Photo lists remembered for a minute and shared between concurrent callers (log of 2026-11-07: 282
/// `photos.getUserPhotos` in 93 min, three within 2 ms, five FLOOD_WAITs). Dropped by
/// `invalidatePeerPhotosCache` whenever the account sets, replaces or deletes a profile photo.
let peerPhotosRequestCoalescer = RequestCoalescer<PeerPhotosRequestKey, [TelegramPeerPhoto]>(lifetime: 60.0)

func invalidatePeerPhotosCache() {
    peerPhotosRequestCoalescer.invalidateAll()
}

func _internal_requestPeerPhotos(accountPeerId: PeerId, postbox: Postbox, network: Network, peerId: PeerId) -> Signal<[TelegramPeerPhoto], NoError> {
    return postbox.transaction { transaction -> Peer? in
        return transaction.getPeer(peerId)
    }
    |> mapToSignal { peer -> Signal<[TelegramPeerPhoto], NoError> in
        let key = PeerPhotosRequestKey(accountPeerId: accountPeerId, peerId: peerId, currentPhotos: peerPhotosFingerprint(peer?.profileImageRepresentations ?? []))
        return peerPhotosRequestCoalescer.signal(key: key, fallback: [], fetch: _internal_requestPeerPhotosUncached(accountPeerId: accountPeerId, postbox: postbox, network: network, peer: peer))
    }
}

private func _internal_requestPeerPhotosUncached(accountPeerId: PeerId, postbox: Postbox, network: Network, peer: Peer?) -> Signal<(value: [TelegramPeerPhoto]?, retryAfter: Double), NoError> {
    if let peer = peer as? TelegramUser, let inputUser = apiInputUser(peer) {
            return network.request(Api.functions.photos.getUserPhotos(userId: inputUser, offset: 0, maxId: 0, limit: 100))
            |> map { (result: Api.photos.Photos) -> (Api.photos.Photos?, Double) in
                return (result, 0.0)
            }
            |> `catch` { error -> Signal<(Api.photos.Photos?, Double), NoError> in
                return .single((nil, requestCoalescerRetryAfter(errorDescription: error.errorDescription)))
            }
            |> map { result, retryAfter -> (value: [TelegramPeerPhoto]?, retryAfter: Double) in
                if let result = result {
                    let totalCount:Int
                    let photos: [Api.Photo]
                    switch result {
                        case let .photos(photosData):
                            let (photosValue, _) = (photosData.photos, photosData.users)
                            photos = photosValue
                            totalCount = photos.count
                        case let .photosSlice(photosSliceData):
                            let (count, photosValue, _) = (photosSliceData.count, photosSliceData.photos, photosSliceData.users)
                            photos = photosValue
                            totalCount = Int(count)
                    }
                    
                    var images: [TelegramPeerPhoto] = []
                    for i in 0 ..< photos.count {
                        if let image = telegramMediaImageFromApiPhoto(photos[i]), let reference = image.reference {
                            var date: Int32 = 0
                            switch photos[i] {
                                case let .photo(photoData):
                                    let apiDate = photoData.date
                                    date = apiDate
                                case .photoEmpty:
                                    break
                            }
                            images.append(TelegramPeerPhoto(image: image, reference: reference, date: date, index: i, totalCount: totalCount, messageId: nil))
                        }
                    }
                    
                    return (images, 0.0)
                } else {
                    return (nil, retryAfter)
                }
            }
        } else if let peer = peer, let inputPeer = apiInputPeer(peer) {
            return network.request(Api.functions.messages.search(flags: 0, peer: inputPeer, q: "", fromId: nil, savedPeerId: nil, savedReaction: nil, topMsgId: nil, filter: .inputMessagesFilterChatPhotos, minDate: 0, maxDate: 0, offsetId: 0, addOffset: 0, limit: 1000, maxId: 0, minId: 0, hash: 0))
            |> map { (result: Api.messages.Messages) -> (Api.messages.Messages?, Double) in
                return (result, 0.0)
            }
            |> `catch` { error -> Signal<(Api.messages.Messages?, Double), NoError> in
                return .single((nil, requestCoalescerRetryAfter(errorDescription: error.errorDescription)))
            }
            |> mapToSignal { result, retryAfter -> Signal<(value: [TelegramPeerPhoto]?, retryAfter: Double), NoError> in
                if let result = result {
                    let messages: [Api.Message]
                    let chats: [Api.Chat]
                    let users: [Api.User]
                    switch result {
                        case let .channelMessages(channelMessagesData):
                            let (apiMessages, apiChats, apiUsers) = (channelMessagesData.messages, channelMessagesData.chats, channelMessagesData.users)
                            messages = apiMessages
                            chats = apiChats
                            users = apiUsers
                        case let .messages(messagesData):
                            let (apiMessages, apiChats, apiUsers) = (messagesData.messages, messagesData.chats, messagesData.users)
                            messages = apiMessages
                            chats = apiChats
                            users = apiUsers
                        case let .messagesSlice(messagesSliceData):
                            let (apiMessages, apiChats, apiUsers) = (messagesSliceData.messages, messagesSliceData.chats, messagesSliceData.users)
                            messages = apiMessages
                            chats = apiChats
                            users = apiUsers
                        case .messagesNotModified:
                            messages = []
                            chats = []
                            users = []
                    }
                    
                    return postbox.transaction { transaction -> [Message] in
                        var peers: [PeerId: Peer] = [:]
                        
                        for user in users {
                            if let user = TelegramUser.merge(transaction.getPeer(user.peerId) as? TelegramUser, rhs: user) {
                                peers[user.id] = user
                            }
                        }
                        
                        for chat in chats {
                            if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                peers[groupOrChannel.id] = groupOrChannel
                            }
                        }
                        
                        var renderedMessages: [Message] = []
                        for message in messages {
                            if let message = StoreMessage(apiMessage: message, accountPeerId: accountPeerId, peerIsForum: peer.isForumOrMonoForum), let renderedMessage = locallyRenderedMessage(message: message, peers: peers) {
                                renderedMessages.append(renderedMessage)
                            }
                        }
                        
                        return renderedMessages
                    } |> map { messages -> (value: [TelegramPeerPhoto]?, retryAfter: Double) in
                        var photos: [TelegramPeerPhoto] = []
                        var index:Int = 0
                        for message in messages {
                            if let media = message.media.first as? TelegramMediaAction {
                                switch media.action {
                                    case let .photoUpdated(image):
                                        if let image = image {
                                            photos.append(TelegramPeerPhoto(image: image, reference: image.reference, date: message.timestamp, index: index, totalCount: messages.count, messageId: message.id))
                                        }
                                    default:
                                        break
                                }
                            }
                            index += 1
                        }
                        return (photos, 0.0)
                    }
                    
                } else {
                    return .single((nil, retryAfter))
                }
            }
        } else {
            // Nothing to ask (no peer record or no access hash): answered with an empty list, not remembered.
            return .single((nil, 0.0))
        }
}

/// `signal`, with the remembered photo lists dropped before it starts and again whenever it reports
/// progress, completes or is cancelled, so the next gallery asks the server for the list the change produced.
func peerPhotosCacheInvalidating<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> {
    return signal
    |> beforeStarted {
        invalidatePeerPhotosCache()
    }
    |> afterNext { _ in
        invalidatePeerPhotosCache()
    }
    |> afterCompleted {
        invalidatePeerPhotosCache()
    }
    |> afterDisposed {
        invalidatePeerPhotosCache()
    }
}
