import Foundation
import Postbox
internal import TelegramApi
import SwiftSignalKit
import MtProtoKit

private func hashForIds(_ ids: [Int64]) -> Int64 {
    var acc: UInt64 = 0
    
    for id in ids {
        combineInt64Hash(&acc, with: UInt64(bitPattern: id))
    }
    return finalizeInt64Hash(acc)
}

/// The items in order, each id once (the first occurrence kept); a list is never stored with an id twice.
private func uniqueOrderedItemListEntries(_ sourceItems: [OrderedItemListEntry]) -> [OrderedItemListEntry] {
    var items: [OrderedItemListEntry] = []
    var existingIds = Set<Data>()
    for item in sourceItems {
        let id = item.id.makeData()
        if !existingIds.contains(id) {
            existingIds.insert(id)
            items.append(item)
        }
    }
    return items
}

private func managedRecentMedia(postbox: Postbox, network: Network, collectionId: Int32, extractItemId: @escaping (MemoryBuffer) -> Int64?, reverseHashOrder: Bool, forceFetch: Bool, fetch: @escaping (Int64) -> Signal<[OrderedItemListEntry]?, NoError>) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Signal<Void, NoError> in
        var itemIds = transaction.getOrderedListItemIds(collectionId: collectionId).compactMap(extractItemId)
        if reverseHashOrder {
            itemIds.reverse()
        }
        return fetch(forceFetch ? 0 : hashForIds(itemIds))
            |> mapToSignal { sourceItems in
                if let sourceItems = sourceItems {
                    let items = uniqueOrderedItemListEntries(sourceItems)
                    return postbox.transaction { transaction -> Void in
                        transaction.replaceOrderedItemListItems(collectionId: collectionId, items: items)
                    }
                } else {
                    return .complete()
                }
            }
    } |> switchToLatest
}

func managedRecentStickers(postbox: Postbox, network: Network, forceFetch: Bool = false) -> Signal<Void, NoError> {
    return managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudRecentStickers, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: forceFetch, fetch: { hash in
        return network.request(Api.functions.messages.getRecentStickers(flags: 0, hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
                case .recentStickersNotModified:
                    return .single(nil)
                case let .recentStickers(recentStickersData):
                    let stickers = recentStickersData.stickers
                    var items: [OrderedItemListEntry] = []
                    for sticker in stickers {
                        if let file = telegramMediaFileFromApiDocument(sticker, altDocuments: []), let id = file.id {
                            if let entry = CodableEntry(RecentMediaItem(file)) {
                                items.append(OrderedItemListEntry(id: RecentMediaItemId(id).rawValue, contents: entry))
                            }
                        }
                    }
                    return .single(items)
            }
        }
    })
}

func managedRecentGifs(postbox: Postbox, network: Network, forceFetch: Bool = false) -> Signal<Void, NoError> {
    return managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudRecentGifs, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: forceFetch, fetch: { hash in
        return network.request(Api.functions.messages.getSavedGifs(hash: hash))
            |> retryRequestIfNotFrozen
            |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
                guard let result else {
                    return .single(nil)
                }
                switch result {
                    case .savedGifsNotModified:
                        return .single(nil)
                    case let .savedGifs(savedGifsData):
                        let gifs = savedGifsData.gifs
                        var items: [OrderedItemListEntry] = []
                        for gif in gifs {
                            if let file = telegramMediaFileFromApiDocument(gif, altDocuments: []), let id = file.id {
                                if let entry = CodableEntry(RecentMediaItem(file)) {
                                    items.append(OrderedItemListEntry(id: RecentMediaItemId(id).rawValue, contents: entry))
                                }
                            }
                        }
                        return .single(items)
                }
        }
    })
}

func managedSavedStickers(postbox: Postbox, network: Network, forceFetch: Bool = false) -> Signal<Void, NoError> {
    return managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudSavedStickers, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: true, forceFetch: forceFetch, fetch: { hash in
        return network.request(Api.functions.messages.getFavedStickers(hash: hash))
            |> retryRequestIfNotFrozen
            |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
                guard let result else {
                    return .single(nil)
                }
                switch result {
                    case .favedStickersNotModified:
                        return .single(nil)
                    case let .favedStickers(favedStickersData):
                        let (packs, stickers) = (favedStickersData.packs, favedStickersData.stickers)
                        var fileStringRepresentations: [MediaId: [String]] = [:]
                        for pack in packs {
                            switch pack {
                                case let .stickerPack(stickerPackData):
                                    let (text, fileIds) = (stickerPackData.emoticon, stickerPackData.documents)
                                    for fileId in fileIds {
                                        let mediaId = MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)
                                        if fileStringRepresentations[mediaId] == nil {
                                            fileStringRepresentations[mediaId] = [text]
                                        } else {
                                            fileStringRepresentations[mediaId]!.append(text)
                                        }
                                    }
                            }
                        }
                        
                        var items: [OrderedItemListEntry] = []
                        for sticker in stickers {
                            if let file = telegramMediaFileFromApiDocument(sticker, altDocuments: []), let id = file.id {
                                var stringRepresentations: [String] = []
                                if let representations = fileStringRepresentations[id] {
                                    stringRepresentations = representations
                                }
                                if let entry = CodableEntry(SavedStickerItem(file: file, stringRepresentations: stringRepresentations)) {
                                    items.append(OrderedItemListEntry(id: RecentMediaItemId(id).rawValue, contents: entry))
                                }
                            }
                        }
                        return .single(items)
                }
        }
    })
}

/// `messages.getStickers(emoticon:)` answers with a hash of its own (`messages.stickers.hash`, which the sticker
/// search also sends back), so the standard hash of the stored ids is no use for these lists. The server's hash is
/// kept per list together with the hash of the ids stored with it, written in the transaction that stores the list.
private struct EmoticonStickerListHash: Codable {
    let serverHash: Int64
    let idsHash: Int64

    enum CodingKeys: String, CodingKey {
        case serverHash = "s"
        case idsHash = "i"
    }
}

private func emoticonStickerListHashEntryId(collectionId: Int32) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 4)
    key.setInt32(0, value: collectionId)
    return ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.emoticonStickerListHashes, key: key)
}

/// The hash to ask with: the server's hash kept with the stored list, or 0 (the full list) when nothing is stored,
/// no hash is kept, or the list changed since the hash was kept. A cleared list is asked for in full, or the server
/// would answer "not modified" and leave it empty.
private func emoticonStickerListRequestHash(transaction: Transaction, collectionId: Int32) -> Int64 {
    let storedIds = transaction.getOrderedListItemIds(collectionId: collectionId).map { RecentMediaItemId($0).mediaId.id }
    guard !storedIds.isEmpty, let kept = transaction.retrieveItemCacheEntry(id: emoticonStickerListHashEntryId(collectionId: collectionId))?.get(EmoticonStickerListHash.self), kept.idsHash == hashForIds(storedIds) else {
        return 0
    }
    return kept.serverHash
}

private func storeEmoticonStickerList(transaction: Transaction, collectionId: Int32, items sourceItems: [OrderedItemListEntry], serverHash: Int64) {
    let items = uniqueOrderedItemListEntries(sourceItems)
    transaction.replaceOrderedItemListItems(collectionId: collectionId, items: items)
    let entryId = emoticonStickerListHashEntryId(collectionId: collectionId)
    let storedIds = items.map { RecentMediaItemId($0.id).mediaId.id }
    if serverHash != 0, !storedIds.isEmpty, let entry = CodableEntry(EmoticonStickerListHash(serverHash: serverHash, idsHash: hashForIds(storedIds))) {
        transaction.putItemCacheEntry(id: entryId, entry: entry)
    } else {
        transaction.removeItemCacheEntry(id: entryId)
    }
}

/// One poll of a list fetched with `messages.getStickers(emoticon:)`. Upstream asks with hash 0, so the server can never
/// answer `stickersNotModified` and every poll rewrites the whole list (fresh file references change its bytes).
/// This sends the kept server hash; "not modified" opens no transaction.
func managedEmoticonStickerListPoll(postbox: Postbox, network: Network, collectionId: Int32, emoticon: String) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Int64 in
        return emoticonStickerListRequestHash(transaction: transaction, collectionId: collectionId)
    }
    |> mapToSignal { hash -> Signal<Void, NoError> in
        return network.request(Api.functions.messages.getStickers(emoticon: emoticon, hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<Void, NoError> in
            guard let result else {
                return .complete()
            }
            switch result {
                case .stickersNotModified:
                    return .complete()
                case let .stickers(stickersData):
                    let (serverHash, stickers) = (stickersData.hash, stickersData.stickers)
                    var items: [OrderedItemListEntry] = []
                    for sticker in stickers {
                        if let file = telegramMediaFileFromApiDocument(sticker, altDocuments: []), let id = file.id {
                            if let entry = CodableEntry(RecentMediaItem(file)) {
                                items.append(OrderedItemListEntry(id: RecentMediaItemId(id).rawValue, contents: entry))
                            }
                        }
                    }
                    return postbox.transaction { transaction -> Void in
                        storeEmoticonStickerList(transaction: transaction, collectionId: collectionId, items: items, serverHash: serverHash)
                    }
            }
        }
    }
}

private func managedEmoticonStickerList(postbox: Postbox, network: Network, collectionId: Int32, emoticon: String) -> Signal<Void, NoError> {
    let poll = managedEmoticonStickerListPoll(postbox: postbox, network: network, collectionId: collectionId, emoticon: emoticon)
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedGreetingStickers(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    return managedEmoticonStickerList(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudGreetingStickers, emoticon: "👋⭐️")
}

func managedPremiumStickers(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    return managedEmoticonStickerList(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudPremiumStickers, emoticon: "⭐️⭐️")
}

func managedAllPremiumStickers(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    return managedEmoticonStickerList(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudAllPremiumStickers, emoticon: "📂⭐️")
}

func managedRecentStatusEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudRecentStatusEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getRecentEmojiStatuses(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiStatusesNotModified:
                return .single(nil)
            case let .emojiStatuses(emojiStatusesData):
                let statuses = emojiStatusesData.statuses
                let parsedStatuses = statuses.compactMap(PeerEmojiStatus.init(apiStatus:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedStatuses.compactMap(\.emojiFileId))
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for status in parsedStatuses {
                        guard let fileId = status.emojiFileId, let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedFeaturedStatusEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudFeaturedStatusEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getDefaultEmojiStatuses(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiStatusesNotModified:
                return .single(nil)
            case let .emojiStatuses(emojiStatusesData):
                let statuses = emojiStatusesData.statuses
                let parsedStatuses = statuses.compactMap(PeerEmojiStatus.init(apiStatus:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedStatuses.compactMap(\.emojiFileId))
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for status in parsedStatuses {
                        guard let fileId = status.emojiFileId, let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedFeaturedChannelStatusEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudFeaturedChannelStatusEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getChannelDefaultEmojiStatuses(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiStatusesNotModified:
                return .single(nil)
            case let .emojiStatuses(emojiStatusesData):
                let statuses = emojiStatusesData.statuses
                let parsedStatuses = statuses.compactMap(PeerEmojiStatus.init(apiStatus:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedStatuses.compactMap(\.emojiFileId))
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for status in parsedStatuses {
                        guard let fileId = status.emojiFileId, let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedUniqueStarGifts(accountPeerId: PeerId, postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudUniqueStarGifts, extractItemId: { RecentStarGiftItemId($0).id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getCollectibleEmojiStatuses(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiStatusesNotModified:
                return .single(nil)
            case let .emojiStatuses(emojiStatusesData):
                let statuses = emojiStatusesData.statuses
                let parsedStatuses = statuses.compactMap(PeerEmojiStatus.init(apiStatus:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedStatuses.flatMap(\.associatedFileIds))
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for status in parsedStatuses {
                        switch status.content {
                        case let .starGift(id, fileId, title, slug, patternFileId, innerColor, outerColor, patternColor, textColor):
                            let slugComponents = slug.components(separatedBy: "-")
                            if let file = files[fileId], let patternFile = files[patternFileId], let numberString = slugComponents.last, let number = Int32(numberString) {
                                let gift = StarGift.UniqueGift(
                                    id: id,
                                    giftId: 0,
                                    title: title,
                                    number: number,
                                    slug: slug,
                                    owner: .peerId(accountPeerId),
                                    attributes: [
                                        .model(name: "", file: file, rarity: .rare, crafted: true),
                                        .pattern(name: "", file: patternFile, rarity: .rare),
                                        .backdrop(name: "", id: 0, innerColor: innerColor, outerColor: outerColor, patternColor: patternColor, textColor: textColor, rarity: .rare)
                                    ],
                                    availability: StarGift.UniqueGift.Availability(issued: 0, total: 0),
                                    giftAddress: nil,
                                    resellAmounts: nil,
                                    resellForTonOnly: false,
                                    releasedBy: nil,
                                    valueAmount: nil,
                                    valueCurrency: nil,
                                    valueUsdAmount: nil,
                                    flags: [],
                                    themePeerId: nil,
                                    peerColor: nil,
                                    hostPeerId: nil,
                                    minOfferStars: nil,
                                    craftChancePermille: nil
                                )
                                if let entry = CodableEntry(RecentStarGiftItem(gift)) {
                                    items.append(OrderedItemListEntry(id: RecentStarGiftItemId(id).rawValue, contents: entry))
                                }
                            }
                        default:
                            break
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(1.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}


func managedProfilePhotoEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudFeaturedProfilePhotoEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getDefaultProfilePhotoEmojis(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiListNotModified:
                return .single(nil)
            case let .emojiList(emojiListData):
                let documentIds = emojiListData.documentId
                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: documentIds)
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for fileId in documentIds {
                        guard let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedGroupPhotoEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudFeaturedGroupPhotoEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getDefaultGroupPhotoEmojis(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiListNotModified:
                return .single(nil)
            case let .emojiList(emojiListData):
                let documentIds = emojiListData.documentId
                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: documentIds)
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for fileId in documentIds {
                        guard let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedBackgroundIconEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudFeaturedBackgroundIconEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getDefaultBackgroundEmojis(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiListNotModified:
                return .single(nil)
            case let .emojiList(emojiListData):
                let documentIds = emojiListData.documentId
                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: documentIds)
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for fileId in documentIds {
                        guard let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedDisabledChannelStatusIconEmoji(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudDisabledChannelStatusEmoji, extractItemId: { RecentMediaItemId($0).mediaId.id }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.account.getChannelRestrictedStatusEmojis(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .emojiListNotModified:
                return .single(nil)
            case let .emojiList(emojiListData):
                let documentIds = emojiListData.documentId
                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: documentIds)
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for fileId in documentIds {
                        guard let file = files[fileId] else {
                            continue
                        }
                        if let entry = CodableEntry(RecentMediaItem(file)) {
                            items.append(OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedRecentReactions(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudRecentReactions, extractItemId: { rawId in
        switch RecentReactionItemId(rawId).id {
        case .builtin:
            return 0
        case let .custom(fileId):
            return fileId.id
        case .stars:
            return 0
        }
    }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.messages.getRecentReactions(limit: 100, hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .reactionsNotModified:
                return .single(nil)
            case let .reactions(reactionsData):
                let reactions = reactionsData.reactions
                let parsedReactions = reactions.compactMap(MessageReaction.Reaction.init(apiReaction:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedReactions.compactMap { reaction -> Int64? in
                    switch reaction {
                    case .builtin:
                        return nil
                    case let .custom(fileId):
                        return fileId
                    case .stars:
                        return nil
                    }
                })
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for reaction in parsedReactions {
                        let item: RecentReactionItem
                        switch reaction {
                        case let .builtin(value):
                            item = RecentReactionItem(.builtin(value))
                        case let .custom(fileId):
                            guard let file = files[fileId] else {
                                continue
                            }
                            item = RecentReactionItem(.custom(TelegramMediaFile.Accessor(file)))
                        case .stars:
                            item = RecentReactionItem(.stars)
                        }
                        if let entry = CodableEntry(item) {
                            items.append(OrderedItemListEntry(id: item.id.rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedTopReactions(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudTopReactions, extractItemId: { rawId in
        switch RecentReactionItemId(rawId).id {
        case .builtin:
            return 0
        case let .custom(fileId):
            return fileId.id
        case .stars:
            return 0
        }
    }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.messages.getTopReactions(limit: 32, hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .reactionsNotModified:
                return .single(nil)
            case let .reactions(reactionsData):
                let reactions = reactionsData.reactions
                let parsedReactions = reactions.compactMap(MessageReaction.Reaction.init(apiReaction:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedReactions.compactMap { reaction -> Int64? in
                    switch reaction {
                    case .builtin:
                        return nil
                    case let .custom(fileId):
                        return fileId
                    case .stars:
                        return nil
                    }
                })
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for reaction in parsedReactions {
                        let item: RecentReactionItem
                        switch reaction {
                        case let .builtin(value):
                            item = RecentReactionItem(.builtin(value))
                        case let .custom(fileId):
                            guard let file = files[fileId] else {
                                continue
                            }
                            item = RecentReactionItem(.custom(TelegramMediaFile.Accessor(file)))
                        case .stars:
                            item = RecentReactionItem(.stars)
                        }
                        if let entry = CodableEntry(item) {
                            items.append(OrderedItemListEntry(id: item.id.rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

func managedDefaultTagReactions(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let poll = managedRecentMedia(postbox: postbox, network: network, collectionId: Namespaces.OrderedItemList.CloudDefaultTagReactions, extractItemId: { rawId in
        switch RecentReactionItemId(rawId).id {
        case .builtin:
            return 0
        case let .custom(fileId):
            return fileId.id
        case .stars:
            return 0
        }
    }, reverseHashOrder: false, forceFetch: false, fetch: { hash in
        return network.request(Api.functions.messages.getDefaultTagReactions(hash: hash))
        |> retryRequestIfNotFrozen
        |> mapToSignal { result -> Signal<[OrderedItemListEntry]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            switch result {
            case .reactionsNotModified:
                return .single(nil)
            case let .reactions(reactionsData):
                let reactions = reactionsData.reactions
                let parsedReactions = reactions.compactMap(MessageReaction.Reaction.init(apiReaction:))

                return _internal_resolveInlineStickers(postbox: postbox, network: network, fileIds: parsedReactions.compactMap { reaction -> Int64? in
                    switch reaction {
                    case .builtin:
                        return nil
                    case let .custom(fileId):
                        return fileId
                    case .stars:
                        return nil
                    }
                })
                |> map { files -> [OrderedItemListEntry] in
                    var items: [OrderedItemListEntry] = []
                    for reaction in parsedReactions {
                        let item: RecentReactionItem
                        switch reaction {
                        case let .builtin(value):
                            item = RecentReactionItem(.builtin(value))
                        case let .custom(fileId):
                            guard let file = files[fileId] else {
                                continue
                            }
                            item = RecentReactionItem(.custom(TelegramMediaFile.Accessor(file)))
                        case .stars:
                            item = RecentReactionItem(.stars)
                        }
                        if let entry = CodableEntry(item) {
                            items.append(OrderedItemListEntry(id: item.id.rawValue, contents: entry))
                        }
                    }
                    return items
                }
            }
        }
    })
    return (poll |> then(.complete() |> suspendAwareDelay(3.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}
