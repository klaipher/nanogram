

#import <Foundation/Foundation.h>

@class MTContext;

@interface MTSessionInfo : NSObject

@property (nonatomic) bool scheduledForCleanup;
@property (nonatomic) bool canBeDeleted;

- (instancetype)initWithRandomSessionIdAndContext:(MTContext *)context;
- (instancetype)initWithSessionId:(int64_t)sessionId context:(MTContext *)context;

- (int64_t)sessionId;
- (int64_t)generateClientMessageId:(bool *)monotonityViolated;
- (int64_t)generateServerMessageId;
- (int64_t)actualClientMessagId;

// True for an id already processed, and for an id older than the last 2000 processed ones (a replay).
- (bool)messageProcessed:(int64_t)messageId;
- (void)setMessageProcessed:(int64_t)messageId;
- (bool)wasMessageSentOnce:(int64_t)messageId;
- (void)setMessageWasSentOnce:(int64_t)messageId;
- (void)scheduleMessageConfirmation:(int64_t)messageId size:(NSInteger)size;
- (NSArray *)scheduledMessageConfirmations;
- (bool)scheduledMessageConfirmationsExceedSize:(NSInteger)sizeLimit orCount:(NSUInteger)countLimit;
- (void)removeScheduledMessageConfirmationsWithIds:(NSArray *)messageIds;
- (void)assignTransactionId:(id)transactionId toScheduledMessageConfirmationsWithIds:(NSArray *)messageIds;
- (void)removeScheduledMessageConfirmationsWithTransactionIds:(NSArray *)transactionIds;

- (void)addContainerMessageIdMapping:(int64_t)containerMessageId childMessageIds:(NSArray *)childMessageIds;
- (NSArray *)messageIdsInContainer:(int64_t)containerMessageId;
- (NSArray *)messageIdsInContainersAfterMessageId:(int64_t)firstMessageId;
// Mappings kept; ones an hour older than the newest container are dropped as containers are added.
- (NSUInteger)containerMessageIdMappingCount;

- (int32_t)takeSeqNo:(bool)messageIsMeaningful;

@end
