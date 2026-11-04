#import <MtProtoKit/MTSessionInfo.h>

#import <MtProtoKit/MTLogging.h>
#import <MtProtoKit/MTContext.h>

@interface MTScheduledMessageConfirmation : NSObject

@property (nonatomic) int64_t messageId;
@property (nonatomic) NSInteger size;
@property (nonatomic, strong) NSMutableArray *transactionIds;

@end

@implementation MTScheduledMessageConfirmation

- (instancetype)initWithMessageId:(int64_t)messageId size:(NSInteger)size
{
    self = [super init];
    if (self != nil)
    {
        _messageId = messageId;
        _size = size;
    }
    return self;
}

- (void)addTransactionId:(id)transactionId
{
    if (_transactionIds == nil)
        _transactionIds = [[NSMutableArray alloc] init];
    if (![_transactionIds containsObject:transactionId])
        [_transactionIds addObject:transactionId];
}

- (bool)containedInTransactionId:(id)transactionId
{
    return [_transactionIds containsObject:transactionId];
}

@end

// The newest message ids of one kind in a session, kept sorted. An id older than every kept one
// counts as seen once the window is full: like tdlib's MessageIdDuplicateChecker and the Rust
// engine's DuplicateChecker, replays of old packets are still ignored, and the session no longer
// keeps every id it ever saw (a long session grew by one boxed number per message).
static const NSUInteger MTSessionInfoMessageIdWindowCapacity = 2000;

typedef struct {
    int64_t *ids;
    NSUInteger count;
} MTSessionInfoMessageIdWindow;

static NSUInteger MTSessionInfoMessageIdWindowLowerBound(MTSessionInfoMessageIdWindow const *window, int64_t messageId) {
    NSUInteger low = 0;
    NSUInteger high = window->count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (window->ids[middle] < messageId) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

static bool MTSessionInfoMessageIdWindowContains(MTSessionInfoMessageIdWindow const *window, int64_t messageId) {
    if (window->count == 0) {
        return false;
    }
    if (window->count >= MTSessionInfoMessageIdWindowCapacity && messageId < window->ids[0]) {
        return true;
    }
    NSUInteger index = MTSessionInfoMessageIdWindowLowerBound(window, messageId);
    return index < window->count && window->ids[index] == messageId;
}

static void MTSessionInfoMessageIdWindowAdd(MTSessionInfoMessageIdWindow *window, int64_t messageId) {
    if (window->ids == NULL) {
        window->ids = malloc(sizeof(int64_t) * MTSessionInfoMessageIdWindowCapacity);
        if (window->ids == NULL) {
            return;
        }
    }
    NSUInteger index = MTSessionInfoMessageIdWindowLowerBound(window, messageId);
    if (index < window->count && window->ids[index] == messageId) {
        return;
    }
    if (window->count >= MTSessionInfoMessageIdWindowCapacity) {
        if (index == 0) {
            return;
        }
        // Drop the oldest id to make room.
        memmove(window->ids, window->ids + 1, sizeof(int64_t) * (index - 1));
        window->ids[index - 1] = messageId;
        return;
    }
    memmove(window->ids + index + 1, window->ids + index, sizeof(int64_t) * (window->count - index));
    window->ids[index] = messageId;
    window->count += 1;
}

// Container mappings answer bad_msg_notification and new_session_created, which name messages of the
// last few minutes; mappings older than this behind the newest container are dropped.
static const int64_t MTSessionInfoContainerMappingLifetime = 60 * 60;
static const NSUInteger MTSessionInfoContainerMappingPruneMinimum = 256;


@interface MTSessionInfo ()
{
    int64_t _sessionId;
    MTContext *_context;
    
    int64_t _lastClientMessageId;
    int32_t _seqNo;
    
    int64_t _lastServerMessageId;
    
    MTSessionInfoMessageIdWindow _processedMessageIds;
    NSMutableArray *_scheduledMessageConfirmations;
    NSMutableDictionary *_containerMessagesMappingDict;
    NSUInteger _containerMappingPruneThreshold;
    MTSessionInfoMessageIdWindow _sentMessageIds;
}

@end

@implementation MTSessionInfo

- (instancetype)initWithRandomSessionIdAndContext:(MTContext *)context
{
    int64_t randomId = 0;
    arc4random_buf(&randomId, sizeof(randomId));
    return [self initWithSessionId:randomId context:context];
}

- (instancetype)initWithSessionId:(int64_t)sessionId context:(MTContext *)context
{
    self = [super init];
    if (self != nil)
    {
        _sessionId = sessionId;
        _context = context;
        
        _scheduledMessageConfirmations = [[NSMutableArray alloc] init];
        
        _containerMessagesMappingDict = [[NSMutableDictionary alloc] init];
        _containerMappingPruneThreshold = MTSessionInfoContainerMappingPruneMinimum;
    }
    return self;
}

- (void)dealloc
{
    free(_processedMessageIds.ids);
    free(_sentMessageIds.ids);
}

- (int64_t)sessionId
{
    return _sessionId;
}

- (int64_t)generateClientMessageId:(bool *)monotonityViolated
{
    int64_t messageId = (int64_t)([_context globalTime] * 4294967296);
    
    if (messageId < _lastClientMessageId)
    {
        if (monotonityViolated != NULL)
            *monotonityViolated = true;
    }
    
    if (messageId == _lastClientMessageId)
        messageId = _lastClientMessageId + 1;
    
    while (messageId % 4 != 0)
        messageId++;
    
    _lastClientMessageId = messageId;
    return messageId;
}

- (int64_t)actualClientMessagId
{
    int64_t messageId = (int64_t)([_context globalTime] * 4294967296);
    
    while (messageId % 4 != 0)
        messageId++;
    
    return messageId;
}

- (int64_t)generateServerMessageId
{
    int64_t messageId = (int64_t)(([_context globalTime]) * 4294967296);
    if (messageId == _lastServerMessageId)
        messageId++;
    while (messageId % 4 != 1)
        messageId++;
    
    _lastServerMessageId = messageId;
    return messageId;
}

- (bool)messageProcessed:(int64_t)messageId
{
    return MTSessionInfoMessageIdWindowContains(&_processedMessageIds, messageId);
}

- (void)setMessageProcessed:(int64_t)messageId
{
    MTSessionInfoMessageIdWindowAdd(&_processedMessageIds, messageId);
}

- (bool)wasMessageSentOnce:(int64_t)messageId {
    return MTSessionInfoMessageIdWindowContains(&_sentMessageIds, messageId);
}

- (void)setMessageWasSentOnce:(int64_t)messageId {
    MTSessionInfoMessageIdWindowAdd(&_sentMessageIds, messageId);
}

- (void)scheduleMessageConfirmation:(int64_t)messageId size:(NSInteger)size
{
    bool found = false;
    for (MTScheduledMessageConfirmation *confirmation in _scheduledMessageConfirmations)
    {
        if (confirmation.messageId == messageId)
        {
            found = true;
            break;
        }
    }
    
    if (!found)
        [_scheduledMessageConfirmations addObject:[[MTScheduledMessageConfirmation alloc] initWithMessageId:messageId size:size]];
}

- (NSArray *)scheduledMessageConfirmations
{
    if (_scheduledMessageConfirmations.count == 0)
        return nil;
    
    NSMutableArray *filteredConfirmations = [[NSMutableArray alloc] init];
    
    for (MTScheduledMessageConfirmation *confirmation in _scheduledMessageConfirmations)
    {
        [filteredConfirmations addObject:@(confirmation.messageId)];
    }
    
    return filteredConfirmations;
}

- (bool)scheduledMessageConfirmationsExceedSize:(NSInteger)sizeLimit orCount:(NSUInteger)countLimit
{
    if (_scheduledMessageConfirmations.count > countLimit)
        return true;
    
    if (_scheduledMessageConfirmations.count == 0)
        return false;
    
    NSInteger completeSize = 0;
    for (MTScheduledMessageConfirmation *confirmation in _scheduledMessageConfirmations)
    {
        completeSize += confirmation.size;
    }
    
    if (completeSize <= sizeLimit)
        return false;
    
    return true;
}

- (void)removeScheduledMessageConfirmationsWithIds:(NSArray *)messageIds
{
    for (NSNumber *nMessageId in messageIds)
    {
        int64_t messageId = (int64_t)[nMessageId longLongValue];
        
        NSInteger count = (NSInteger)_scheduledMessageConfirmations.count;
        for (NSInteger i = 0; i < count; i++)
        {
            if (((MTScheduledMessageConfirmation *)_scheduledMessageConfirmations[(NSUInteger)i]).messageId == messageId)
            {
                [_scheduledMessageConfirmations removeObjectAtIndex:(NSUInteger)i];
                
                break;
            }
        }
    }
}

- (void)assignTransactionId:(id)transactionId toScheduledMessageConfirmationsWithIds:(NSArray *)messageIds
{
    for (MTScheduledMessageConfirmation *confirmation in _scheduledMessageConfirmations)
    {
        if ([messageIds containsObject:@(confirmation.messageId)])
            [confirmation addTransactionId:transactionId];
    }
}

- (void)removeScheduledMessageConfirmationsWithTransactionIds:(NSArray *)transactionIds
{
    NSInteger count = (NSInteger)_scheduledMessageConfirmations.count;
    for (NSInteger i = 0; i < count; i++)
    {
        for (id transactionId in transactionIds)
        {
            if ([((MTScheduledMessageConfirmation *)_scheduledMessageConfirmations[(NSUInteger)i]) containedInTransactionId:transactionId])
            {
                [_scheduledMessageConfirmations removeObjectAtIndex:(NSUInteger)i];
                i--;
                count--;
                
                break;
            }
        }
    }
}

- (void)addContainerMessageIdMapping:(int64_t)containerMessageId childMessageIds:(NSArray *)childMessageIds
{
    _containerMessagesMappingDict[@(containerMessageId)] = childMessageIds;
    if (_containerMessagesMappingDict.count >= _containerMappingPruneThreshold) {
        [self pruneContainerMappingsOlderThan:containerMessageId - (MTSessionInfoContainerMappingLifetime << 32)];
        // Prune again only after the map has doubled, so a busy session does not scan it on every send.
        _containerMappingPruneThreshold = MAX(MTSessionInfoContainerMappingPruneMinimum, _containerMessagesMappingDict.count * 2);
    }
}

- (void)pruneContainerMappingsOlderThan:(int64_t)oldestKeptMessageId
{
    NSMutableArray<NSNumber *> *expired = [[NSMutableArray alloc] init];
    for (NSNumber *nContainerMessageId in _containerMessagesMappingDict) {
        if ((int64_t)[nContainerMessageId longLongValue] < oldestKeptMessageId) {
            [expired addObject:nContainerMessageId];
        }
    }
    [_containerMessagesMappingDict removeObjectsForKeys:expired];
}

- (NSUInteger)containerMessageIdMappingCount
{
    return _containerMessagesMappingDict.count;
}

- (NSArray *)messageIdsInContainer:(int64_t)containerMessageId
{
    return _containerMessagesMappingDict[@(containerMessageId)];
}

- (NSArray *)messageIdsInContainersAfterMessageId:(int64_t)firstMessageId
{
    NSMutableArray *array = [[NSMutableArray alloc] init];
    
    [_containerMessagesMappingDict enumerateKeysAndObjectsUsingBlock:^(NSNumber *nContainerMessageId, NSArray *messageIds, __unused BOOL *stop)
    {
        int64_t containerMessageId = (int64_t)[nContainerMessageId longLongValue];
        for (NSNumber *nMessageId in messageIds)
        {
            if (containerMessageId >= firstMessageId || ((int64_t)[nMessageId longLongValue]) >= firstMessageId)
            {
                [array addObject:nMessageId];
            }
        }
    }];
    
    return array;
}

- (int32_t)takeSeqNo:(bool)messageIsMeaningful
{
    int32_t seqNo = 0;
    
    if (messageIsMeaningful)
    {
        seqNo = _seqNo + 1;
        _seqNo += 2;
    }
    else
        seqNo = _seqNo;
    
    return seqNo;
}

@end
