import Foundation
import Postbox

func channelStateUpdatedByPoll(_ current: ChannelState?, pts: Int32) -> ChannelState? {
    if let current, current.pts == pts {
        return nil
    }
    let state = current ?? ChannelState(pts: pts, invalidatedPts: nil, synchronizedUntilMessageId: nil)
    return state.withUpdatedPts(pts)
}

func cachedChannelDataWithParticipantsCount(_ current: CachedPeerData?, participantsCount: Int32) -> CachedPeerData? {
    let previous: CachedChannelData
    if let current = current as? CachedChannelData {
        if current.participantsSummary.memberCount == participantsCount {
            return nil
        }
        previous = current
    } else {
        previous = CachedChannelData()
    }
    return previous.withUpdatedParticipantsSummary(previous.participantsSummary.withUpdatedMemberCount(participantsCount))
}

func messageAttributesWithIncreasedViewCount(_ attributes: [MessageAttribute], count: Int) -> [MessageAttribute]? {
    var attributes = attributes
    for j in 0 ..< attributes.count {
        if let attribute = attributes[j] as? ViewCountMessageAttribute {
            if count > attribute.count {
                attributes[j] = ViewCountMessageAttribute(count: count)
                return attributes
            }
            return nil
        }
    }
    return nil
}

func messageAttributesWithIncreasedForwardCount(_ attributes: [MessageAttribute], count: Int) -> [MessageAttribute]? {
    var attributes = attributes
    for j in 0 ..< attributes.count {
        if let attribute = attributes[j] as? ForwardCountMessageAttribute {
            if count > attribute.count {
                attributes[j] = ForwardCountMessageAttribute(count: count)
                return attributes
            }
            return nil
        }
    }
    return nil
}

struct MessageViewsPollResult {
    var views: Int32?
    var forwards: Int32?
    var repliesCount: Int32?
    var recentRepliersPeerIds: [PeerId]?
    var commentsChannelId: PeerId?
    var repliesMaxId: Int32?
}

func applyMessageViewsPollResult(_ result: MessageViewsPollResult, to attributes: inout [MessageAttribute], repliesReadMaxId: inout Int32?) -> (changed: Bool, foundReplies: Bool) {
    var changed = false
    var foundReplies = false
    for j in 0 ..< attributes.count {
        if let attribute = attributes[j] as? ViewCountMessageAttribute {
            if let views = result.views, Int(views) > attribute.count {
                attributes[j] = ViewCountMessageAttribute(count: Int(views))
                changed = true
            }
        } else if let attribute = attributes[j] as? ForwardCountMessageAttribute {
            if let forwards = result.forwards, Int(forwards) != attribute.count {
                attributes[j] = ForwardCountMessageAttribute(count: Int(forwards))
                changed = true
            }
        } else if let attribute = attributes[j] as? ReplyThreadMessageAttribute {
            foundReplies = true
            if let repliesCount = result.repliesCount {
                var resolvedMaxReadMessageId: MessageId.Id?
                if let previousMaxReadMessageId = attribute.maxReadMessageId, let repliesReadMaxIdValue = repliesReadMaxId {
                    resolvedMaxReadMessageId = max(previousMaxReadMessageId, repliesReadMaxIdValue)
                    repliesReadMaxId = resolvedMaxReadMessageId
                } else if let repliesReadMaxIdValue = repliesReadMaxId {
                    resolvedMaxReadMessageId = repliesReadMaxIdValue
                    repliesReadMaxId = resolvedMaxReadMessageId
                } else {
                    resolvedMaxReadMessageId = attribute.maxReadMessageId
                }
                let updatedAttribute = ReplyThreadMessageAttribute(count: repliesCount, latestUsers: result.recentRepliersPeerIds ?? [], commentsPeerId: result.commentsChannelId, maxMessageId: result.repliesMaxId, maxReadMessageId: resolvedMaxReadMessageId)
                if updatedAttribute.count != attribute.count || updatedAttribute.latestUsers != attribute.latestUsers || updatedAttribute.commentsPeerId != attribute.commentsPeerId || updatedAttribute.maxMessageId != attribute.maxMessageId || updatedAttribute.maxReadMessageId != attribute.maxReadMessageId {
                    attributes[j] = updatedAttribute
                    changed = true
                }
            }
        }
    }
    if !foundReplies, let repliesCount = result.repliesCount {
        attributes.append(ReplyThreadMessageAttribute(count: repliesCount, latestUsers: result.recentRepliersPeerIds ?? [], commentsPeerId: result.commentsChannelId, maxMessageId: result.repliesMaxId, maxReadMessageId: repliesReadMaxId))
        changed = true
    }
    return (changed, foundReplies)
}
