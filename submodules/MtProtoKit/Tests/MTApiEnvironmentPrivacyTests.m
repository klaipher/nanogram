#import <XCTest/XCTest.h>

#import <MtProtoKit/MTApiEnvironment.h>

// What initConnection tells Telegram about the device: only the product family, the major system
// version and the language without a region.
@interface MTApiEnvironmentPrivacyTests : XCTestCase
@end

@implementation MTApiEnvironmentPrivacyTests

- (void)testDeviceModelIsOnlyTheFamily {
    XCTAssertEqualObjects([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:@"iPhone17,2"], @"iPhone");
    XCTAssertEqualObjects([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:@"iPod9,1"], @"iPhone");
    XCTAssertEqualObjects([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:@"iPad14,3"], @"iPad");
    XCTAssertEqualObjects([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:@"MacBookPro18,1"], @"Mac");
    XCTAssertEqualObjects([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:@"Mac14,2"], @"Mac");
    XCTAssertNil([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:@"arm64"]);
    XCTAssertNil([MTApiEnvironment deviceFamilyNameForHardwareIdentifier:nil]);
}

- (void)testSystemVersionKeepsOnlyTheMajorNumber {
    XCTAssertEqualObjects([MTApiEnvironment majorSystemVersion:@"18.2.1"], @"18");
    XCTAssertEqualObjects([MTApiEnvironment majorSystemVersion:@"26.0"], @"26");
    XCTAssertEqualObjects([MTApiEnvironment majorSystemVersion:@"15"], @"15");
    XCTAssertEqualObjects([MTApiEnvironment majorSystemVersion:@""], @"");
    XCTAssertEqualObjects([MTApiEnvironment majorSystemVersion:nil], @"");
}

- (void)testLanguageCodeHasNoRegion {
    XCTAssertEqualObjects([MTApiEnvironment languageCodeWithoutRegion:@"en-US"], @"en");
    XCTAssertEqualObjects([MTApiEnvironment languageCodeWithoutRegion:@"de-AT"], @"de");
    XCTAssertEqualObjects([MTApiEnvironment languageCodeWithoutRegion:@"uk"], @"uk");
    XCTAssertEqualObjects([MTApiEnvironment languageCodeWithoutRegion:@"zh-Hans-CN"], @"zh-Hans");
    XCTAssertEqualObjects([MTApiEnvironment languageCodeWithoutRegion:nil], @"en");
}

- (void)testEnvironmentCarriesNoExactDeviceDetails {
    MTApiEnvironment *environment = [[MTApiEnvironment alloc] init];
    NSArray<NSString *> *knownModels = @[@"iPhone", @"iPad", @"Mac"];
    XCTAssertTrue([knownModels containsObject:environment.deviceModel]);
    XCTAssertFalse([environment.systemVersion containsString:@"."]);
    XCTAssertFalse([environment.systemLangCode containsString:@"_"]);
    XCTAssertTrue([environment.systemLangCode componentsSeparatedByString:@"-"].count <= 2);
}

@end
