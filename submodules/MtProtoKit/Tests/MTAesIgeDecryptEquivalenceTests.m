#import <XCTest/XCTest.h>

#import "MTAes.h"

// MyAesIgeDecrypt runs a fused ARMv8 AES loop on arm64 and the per-block
// CommonCrypto code elsewhere. MyAesIgeDecryptReference is the original code,
// so every case below checks that both give identical output and iv state.
@interface MTAesIgeDecryptEquivalenceTests : XCTestCase

- (void)testDecryptBenchmark {
    NSMutableData *input = [[NSMutableData alloc] initWithLength:1048576];
    NSMutableData *output = [[NSMutableData alloc] initWithLength:1048576];
    fillRandom(input.mutableBytes, input.length);
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    [self measureBlock:^{
        uint8_t iv[32] __attribute__((aligned(16))) = { 0 };
        MyAesIgeDecrypt(input.bytes, 1048576, output.mutableBytes, key, 32, iv);
    }];
}

@end

@implementation MTAesIgeDecryptEquivalenceTests

static void fillRandom(uint8_t *bytes, size_t length) {
    if (length != 0) {
        arc4random_buf(bytes, length);
    }
}

// The reference asserts 8-byte aligned buffers, so it always runs on aligned
// copies; the fused path runs on the (possibly unaligned) offsets.
- (void)checkLength:(int)length keyLength:(int)keyLength inOffset:(size_t)inOffset outOffset:(size_t)outOffset {
    NSMutableData *inStorage = [[NSMutableData alloc] initWithLength:(NSUInteger)length + 16];
    NSMutableData *inAligned = [[NSMutableData alloc] initWithLength:(NSUInteger)length];
    NSMutableData *outA = [[NSMutableData alloc] initWithLength:(NSUInteger)length];
    NSMutableData *outB = [[NSMutableData alloc] initWithLength:(NSUInteger)length + 16];
    fillRandom(inStorage.mutableBytes, inStorage.length);
    memset(outB.mutableBytes, 0xA5, outB.length);
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    uint8_t ivA[32] __attribute__((aligned(16)));
    fillRandom(ivA, sizeof(ivA));
    uint8_t ivB[32] __attribute__((aligned(16)));
    memcpy(ivB, ivA, sizeof(ivA));

    const uint8_t *input = (const uint8_t *)inStorage.bytes + inOffset;
    memcpy(inAligned.mutableBytes, input, (size_t)length);
    XCTAssertTrue(MyAesIgeDecryptReference(inAligned.bytes, length, outA.mutableBytes, key, keyLength, ivA));
    XCTAssertTrue(MyAesIgeDecrypt(input, length, (uint8_t *)outB.mutableBytes + outOffset, key, keyLength, ivB));
    XCTAssertEqual(memcmp(outA.bytes, (const uint8_t *)outB.bytes + outOffset, (size_t)length), 0, @"length %d key %d offsets %zu/%zu", length, keyLength, inOffset, outOffset);
    XCTAssertEqual(memcmp(ivA, ivB, sizeof(ivA)), 0, @"iv out differs, length %d key %d", length, keyLength);
}

- (void)testMatchesReferenceOnRandomVectors {
    const int keyLengths[] = { 16, 24, 32 };
    const int lengths[] = { 16, 32, 48, 64, 256, 1024, 4096, 65536, 1048576 };
    for (size_t k = 0; k < sizeof(keyLengths) / sizeof(keyLengths[0]); k++) {
        for (size_t l = 0; l < sizeof(lengths) / sizeof(lengths[0]); l++) {
            for (int round = 0; round < (lengths[l] > 65536 ? 1 : 8); round++) {
                [self checkLength:lengths[l] keyLength:keyLengths[k] inOffset:0 outOffset:0];
            }
        }
    }
}

- (void)testMatchesReferenceOnUnalignedBuffers {
    for (size_t inOffset = 0; inOffset < 8; inOffset++) {
        for (size_t outOffset = 0; outOffset < 8; outOffset++) {
            [self checkLength:160 keyLength:32 inOffset:inOffset outOffset:outOffset];
        }
    }
}

- (void)testIvChainingAcrossSplitBuffers {
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    uint8_t iv[32];
    fillRandom(iv, sizeof(iv));
    uint8_t whole[256];
    fillRandom(whole, sizeof(whole));

    uint8_t ivOnce[32];
    memcpy(ivOnce, iv, sizeof(iv));
    uint8_t outOnce[256];
    XCTAssertTrue(MyAesIgeDecrypt(whole, 256, outOnce, key, 32, ivOnce));

    uint8_t ivSplit[32];
    memcpy(ivSplit, iv, sizeof(iv));
    uint8_t outSplit[256];
    XCTAssertTrue(MyAesIgeDecrypt(whole, 96, outSplit, key, 32, ivSplit));
    XCTAssertTrue(MyAesIgeDecrypt(whole + 96, 160, outSplit + 96, key, 32, ivSplit));

    XCTAssertEqual(memcmp(outOnce, outSplit, sizeof(outOnce)), 0);
    XCTAssertEqual(memcmp(ivOnce, ivSplit, sizeof(iv)), 0);
}

- (void)testDecryptInvertsEncrypt {
    for (int round = 0; round < 16; round++) {
        uint8_t key[32];
        fillRandom(key, sizeof(key));
        uint8_t iv[32] __attribute__((aligned(16)));
        fillRandom(iv, sizeof(iv));
        uint8_t ivDecrypt[32] __attribute__((aligned(16)));
        memcpy(ivDecrypt, iv, sizeof(iv));
        int length = 16 * (1 + (int)arc4random_uniform(200));
        NSMutableData *plain = [[NSMutableData alloc] initWithLength:(NSUInteger)length];
        fillRandom(plain.mutableBytes, plain.length);
        NSMutableData *cipher = [[NSMutableData alloc] initWithLength:(NSUInteger)length];
        NSMutableData *back = [[NSMutableData alloc] initWithLength:(NSUInteger)length];

        XCTAssertTrue(MyAesIgeEncrypt(plain.bytes, length, cipher.mutableBytes, key, 32, iv));
        XCTAssertTrue(MyAesIgeDecrypt(cipher.bytes, length, back.mutableBytes, key, 32, ivDecrypt));
        XCTAssertEqualObjects(plain, back);
    }
}

- (void)testUnsupportedKeyLengthFailsAndZeroesOutput {
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    uint8_t iv[32];
    fillRandom(iv, sizeof(iv));
    uint8_t input[64];
    fillRandom(input, sizeof(input));
    const int badLengths[] = { 0, 1, 15, 17, 31, 33 };
    for (size_t i = 0; i < sizeof(badLengths) / sizeof(badLengths[0]); i++) {
        uint8_t out[64];
        memset(out, 0x5A, sizeof(out));
        XCTAssertFalse(MyAesIgeDecrypt(input, 64, out, key, badLengths[i], iv));
        for (size_t b = 0; b < sizeof(out); b++) {
            XCTAssertEqual(out[b], 0, @"key length %d left byte %zu", badLengths[i], b);
        }
    }
}

- (void)testNonBlockMultipleLengthFailsAndZeroesOutput {
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    uint8_t iv[32];
    fillRandom(iv, sizeof(iv));
    uint8_t input[64];
    fillRandom(input, sizeof(input));
    uint8_t out[64];
    memset(out, 0x5A, sizeof(out));
    XCTAssertFalse(MyAesIgeDecrypt(input, 50, out, key, 32, iv));
    for (size_t b = 0; b < 50; b++) {
        XCTAssertEqual(out[b], 0);
    }
}

- (void)testZeroLengthSucceedsAndLeavesIvUntouched {
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    uint8_t iv[32];
    fillRandom(iv, sizeof(iv));
    uint8_t ivCopy[32];
    memcpy(ivCopy, iv, sizeof(iv));
    uint8_t out[16];
    XCTAssertTrue(MyAesIgeDecrypt(out, 0, out, key, 32, iv));
    XCTAssertEqual(memcmp(iv, ivCopy, sizeof(iv)), 0);
}


- (void)testDecryptBenchmark {
    NSMutableData *input = [[NSMutableData alloc] initWithLength:1048576];
    NSMutableData *output = [[NSMutableData alloc] initWithLength:1048576];
    fillRandom(input.mutableBytes, input.length);
    uint8_t key[32];
    fillRandom(key, sizeof(key));
    [self measureBlock:^{
        uint8_t iv[32] __attribute__((aligned(16))) = { 0 };
        MyAesIgeDecrypt(input.bytes, 1048576, output.mutableBytes, key, 32, iv);
    }];
}

@end
