#import <XCTest/XCTest.h>

#import <MtProtoKit/MTEncryption.h>
#import <MtProtoKit/MTKeychain.h>

// A keychain whose cache says every number is a safe prime, and counts how often it is asked.
@interface MTSafePrimeCacheTestsKeychain : NSObject <MTKeychain>
@property (nonatomic) NSInteger numberReads;
@end

@implementation MTSafePrimeCacheTestsKeychain

- (void)setObject:(id)__unused object forKey:(NSString *)__unused aKey group:(NSString *)__unused group {
}

- (NSDictionary *)dictionaryForKey:(NSString *)__unused aKey group:(NSString *)__unused group {
    return nil;
}

- (NSNumber *)numberForKey:(NSString *)__unused aKey group:(NSString *)__unused group {
    self.numberReads += 1;
    return @YES;
}

- (void)removeObjectForKey:(NSString *)__unused aKey group:(NSString *)__unused group {
}

@end

@interface MTSafePrimeCacheTests : XCTestCase
@end

@implementation MTSafePrimeCacheTests

// The shape checks and the cached verdict never touch the provider.
static id<EncryptionProvider> MTSafePrimeCacheTestsNoProvider(void) {
    return nil;
}

- (void)testACachedVerdictCannotVouchForAShortNumber {
    MTSafePrimeCacheTestsKeychain *keychain = [[MTSafePrimeCacheTestsKeychain alloc] init];
    NSMutableData *number = [[NSMutableData alloc] initWithLength:255];
    ((uint8_t *)number.mutableBytes)[0] = 0xff;
    XCTAssertFalse(MTCheckIsSafePrime(MTSafePrimeCacheTestsNoProvider(), number, keychain));
    XCTAssertEqual(keychain.numberReads, 0);
}

- (void)testACachedVerdictCannotVouchForANumberWithoutTheTopBit {
    MTSafePrimeCacheTestsKeychain *keychain = [[MTSafePrimeCacheTestsKeychain alloc] init];
    NSMutableData *number = [[NSMutableData alloc] initWithLength:256];
    ((uint8_t *)number.mutableBytes)[0] = 0x7f;
    ((uint8_t *)number.mutableBytes)[255] = 0x01;
    XCTAssertFalse(MTCheckIsSafePrime(MTSafePrimeCacheTestsNoProvider(), number, keychain));
    XCTAssertEqual(keychain.numberReads, 0);
}

- (void)testAWellShapedNumberStillUsesTheCache {
    MTSafePrimeCacheTestsKeychain *keychain = [[MTSafePrimeCacheTestsKeychain alloc] init];
    NSMutableData *number = [[NSMutableData alloc] initWithLength:256];
    ((uint8_t *)number.mutableBytes)[0] = 0x80;
    ((uint8_t *)number.mutableBytes)[255] = 0x01;
    XCTAssertTrue(MTCheckIsSafePrime(MTSafePrimeCacheTestsNoProvider(), number, keychain));
    XCTAssertEqual(keychain.numberReads, 1);
}

@end
