#import <XCTest/XCTest.h>

#import <MtProtoKit/MTApiEnvironment.h>
#import <MtProtoKit/MTMessageTransaction.h>
#import <MtProtoKit/MTOutgoingMessage.h>
#import <MtProtoKit/MTRequest.h>
#import <MtProtoKit/MTRequestMessageService.h>

#import "MTTestSupport.h"

// A request goes out wrapped in invokeWithLayer + initConnection only when the
// key's stored apiInitializationHash differs from the environment's. The backup
// address fetch (getConfig through a backup IP) builds a fresh context for each
// fetch but reuses one in-memory keychain per address, so from the second fetch
// on the hash was already stored and getConfig went out bare. The server then
// answered in its base layer (config#232d5905, "Type constructor 232d5905 not
// found" in the field logs), the parse failed with TL_PARSING_ERROR and the
// fetched address list was lost. `alwaysInitializeApi` makes such a service
// wrap every request whatever the key remembers.

static const NSInteger kApiInitDatacenterId = 2;

static uint32_t apiInitFirstWord(NSData *data) {
    uint32_t value = 0;
    if (data.length >= 4) {
        [data getBytes:&value length:4];
    }
    return value;
}

@interface MTApiInitializationTests : XCTestCase
@end

@implementation MTApiInitializationTests {
    MTContext *_context;
    MTProto *_proto;
}

- (void)setUp {
    [super setUp];
    _context = MTTestMakeContext(false);
    MTTestSetAddress(_context, kApiInitDatacenterId, false);

    // The key already went through initConnection with this environment.
    MTDatacenterAuthInfo *authInfo = MTTestMakeAuthInfo();
    NSString *hash = _context.apiEnvironment.apiInitializationHash;
    XCTAssertNotNil(hash);
    authInfo = [authInfo withUpdatedAuthKeyAttributes:@{@"apiInitializationHash": hash != nil ? hash : @""}];
    [_context updateAuthInfoForDatacenterWithId:kApiInitDatacenterId authInfo:authInfo selector:MTDatacenterAuthInfoSelectorPersistent];

    _proto = [[MTProto alloc] initWithContext:_context datacenterId:kApiInitDatacenterId usageCalculationInfo:nil requiredAuthToken:nil authTokenMasterDatacenterId:0];
    [_proto pause];
}

- (void)tearDown {
    [_proto stop];
    [super tearDown];
}

- (MTRequestMessageService *)addServiceAlwaysInitializingApi:(bool)alwaysInitializeApi {
    MTRequestMessageService *service = [[MTRequestMessageService alloc] initWithContext:_context];
    service.alwaysInitializeApi = alwaysInitializeApi;
    [_proto addMessageService:service];
    MTTestOnManagerQueue(^{});

    MTRequest *request = [[MTRequest alloc] init];
    // help.getConfig
    uint32_t getConfig = 0xc4f9186b;
    [request setPayload:[NSData dataWithBytes:&getConfig length:4] metadata:@"getConfig" shortMetadata:@"getConfig" responseParser:^id(NSData *data) {
        return data;
    }];
    [service addRequest:request];
    MTTestOnManagerQueue(^{});
    return service;
}

- (uint32_t)firstWordOfOutgoingRequest:(MTRequestMessageService *)service {
    __block MTMessageTransaction *transaction = nil;
    MTProto *proto = _proto;
    MTTestOnManagerQueue(^{
        transaction = [service mtProtoMessageTransaction:proto authInfoSelector:MTDatacenterAuthInfoSelectorPersistent sessionInfo:nil scheme:nil];
    });
    for (MTOutgoingMessage *message in transaction.messagePayload) {
        if ([message.metadata isEqual:@"getConfig"]) {
            return apiInitFirstWord(message.data);
        }
    }
    XCTFail(@"getConfig did not go out");
    return 0;
}

- (void)testAKeyThatRemembersTheEnvironmentSendsTheRequestBareByDefault {
    MTRequestMessageService *service = [self addServiceAlwaysInitializingApi:false];
    XCTAssertEqual([self firstWordOfOutgoingRequest:service], 0xc4f9186b, @"upstream behaviour for long-lived sessions is unchanged");
}

- (void)testAlwaysInitializeApiWrapsTheRequestEvenWhenTheKeyRemembersTheEnvironment {
    MTRequestMessageService *service = [self addServiceAlwaysInitializingApi:true];
    XCTAssertEqual([self firstWordOfOutgoingRequest:service], 0xda9b0d0d, @"invokeWithLayer, so the server answers in our layer and not with config#232d5905");
}

@end
