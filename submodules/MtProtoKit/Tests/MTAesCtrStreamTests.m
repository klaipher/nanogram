#import <XCTest/XCTest.h>

#import <CommonCrypto/CommonCrypto.h>

#import <MtProtoKit/MTEncryption.h>

// Known-answer tests for MTAesCtr, the obfuscated-transport and CDN cipher.
// The reference below is OpenSSL's AES-256-CTR: one ECB block per 16 bytes
// and a 128-bit big-endian counter. The server uses the same, so MTAesCtr
// must match it byte for byte however the stream is chunked.

static NSData *ctrRandomData(NSUInteger length) {
    NSMutableData *data = [[NSMutableData alloc] initWithLength:length];
    if (length != 0) {
        arc4random_buf(data.mutableBytes, length);
    }
    return data;
}

static void ctrIncrement128(unsigned char *counter) {
    for (int i = 15; i >= 0; i--) {
        counter[i]++;
        if (counter[i] != 0) {
            break;
        }
    }
}

static void ctrEncryptBlock(const unsigned char *key, const unsigned char *block, unsigned char *out) {
    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, key, 32, NULL, block, 16, out, 16, &moved);
    assert(status == kCCSuccess && moved == 16);
    (void)status;
}

static NSData *ctrReference(NSData *key, NSData *iv, NSData *input) {
    unsigned char counter[16];
    memcpy(counter, iv.bytes, 16);
    unsigned char keystream[16];
    NSMutableData *output = [[NSMutableData alloc] initWithLength:input.length];
    const unsigned char *in = input.bytes;
    unsigned char *out = output.mutableBytes;
    for (NSUInteger i = 0; i < input.length; i++) {
        if (i % 16 == 0) {
            ctrEncryptBlock(key.bytes, counter, keystream);
            ctrIncrement128(counter);
        }
        out[i] = in[i] ^ keystream[i % 16];
    }
    return output;
}

// Feeds `input` to `ctr` in chunks of the given lengths, cycling through them.
static NSData *ctrRunChunked(MTAesCtr *ctr, NSData *input, const size_t *chunks, size_t chunkCount) {
    NSMutableData *output = [[NSMutableData alloc] initWithLength:input.length];
    size_t offset = 0;
    size_t index = 0;
    while (offset < input.length) {
        size_t length = chunks[index % chunkCount];
        index++;
        if (length > input.length - offset) {
            length = input.length - offset;
        }
        bool ok = [ctr encryptIn:(const unsigned char *)input.bytes + offset out:(unsigned char *)output.mutableBytes + offset len:length];
        assert(ok);
        (void)ok;
        offset += length;
    }
    return output;
}

static NSData *ctrIvWithLow64(uint64_t low) {
    NSMutableData *iv = [ctrRandomData(16) mutableCopy];
    unsigned char *bytes = iv.mutableBytes;
    for (int i = 0; i < 8; i++) {
        bytes[15 - i] = (unsigned char)(low >> (8 * i));
    }
    return iv;
}

@interface MTAesCtrStreamTests : XCTestCase
@end

@implementation MTAesCtrStreamTests

- (void)testOddLengthChunkedStreamsMatchReference {
    const size_t patterns[][8] = {
        { 1, 0 },
        { 3, 5, 7, 0 },
        { 15, 17, 0 },
        { 16, 0 },
        { 1, 15, 16, 17, 31, 33, 4095, 0 },
        { 4096, 0 },
        { 65537, 1, 0 },
    };
    NSUInteger lengths[] = { 0, 1, 15, 16, 17, 255, 4097, 100003 };
    for (size_t p = 0; p < sizeof(patterns) / sizeof(patterns[0]); p++) {
        size_t chunkCount = 0;
        while (chunkCount < 8 && patterns[p][chunkCount] != 0) {
            chunkCount++;
        }
        for (size_t l = 0; l < sizeof(lengths) / sizeof(lengths[0]); l++) {
            NSData *key = ctrRandomData(32);
            NSData *iv = ctrRandomData(16);
            NSData *input = ctrRandomData(lengths[l]);
            for (int decrypt = 0; decrypt < 2; decrypt++) {
                MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:decrypt != 0];
                XCTAssertNotNil(ctr);
                NSData *output = ctrRunChunked(ctr, input, patterns[p], chunkCount);
                XCTAssertEqualObjects(output, ctrReference(key, iv, input), @"pattern %zu, length %lu", p, (unsigned long)lengths[l]);
            }
        }
    }
}

- (void)testRandomChunkingMatchesReference {
    for (int round = 0; round < 50; round++) {
        NSData *key = ctrRandomData(32);
        NSData *iv = ctrRandomData(16);
        NSData *input = ctrRandomData(arc4random_uniform(20000));
        MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:false];
        size_t chunks[16];
        for (int i = 0; i < 16; i++) {
            chunks[i] = 1 + arc4random_uniform(700);
        }
        XCTAssertEqualObjects(ctrRunChunked(ctr, input, chunks, 16), ctrReference(key, iv, input));
    }
}

// The counter is 128 bits: a carry out of the low 64 bits must reach the high
// 64 bits, and the all-ones counter wraps to zero.
- (void)testCounterCarriesAcrossLow64Boundary {
    uint64_t lows[] = { UINT64_MAX, UINT64_MAX - 1, UINT64_MAX - 3, UINT64_MAX - 300, 0 };
    const size_t chunkSets[][3] = { { 1, 0, 0 }, { 7, 0, 0 }, { 16, 0, 0 }, { 33, 4096, 5 } };
    for (size_t i = 0; i < sizeof(lows) / sizeof(lows[0]); i++) {
        for (size_t c = 0; c < sizeof(chunkSets) / sizeof(chunkSets[0]); c++) {
            size_t chunkCount = chunkSets[c][1] == 0 ? 1 : 3;
            NSData *key = ctrRandomData(32);
            NSData *iv = ctrIvWithLow64(lows[i]);
            NSData *input = ctrRandomData(16 * 400 + 9);
            MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:false];
            XCTAssertEqualObjects(ctrRunChunked(ctr, input, chunkSets[c], chunkCount), ctrReference(key, iv, input), @"low64 %llu, chunks %zu", lows[i], c);
        }
    }
    NSData *key = ctrRandomData(32);
    NSMutableData *allOnes = [[NSMutableData alloc] initWithLength:16];
    memset(allOnes.mutableBytes, 0xff, 16);
    NSData *input = ctrRandomData(100);
    MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:allOnes.bytes decrypt:false];
    const size_t single[] = { 100 };
    XCTAssertEqualObjects(ctrRunChunked(ctr, input, single, 1), ctrReference(key, allOnes, input));
}

// num, getIv and ecount follow OpenSSL's CRYPTO_ctr128_encrypt state.
- (void)testStateAccessorsFollowOpenSslSemantics {
    NSData *key = ctrRandomData(32);
    NSData *iv = ctrIvWithLow64(UINT64_MAX - 1);
    MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:false];
    XCTAssertEqual([ctr num], 0u);

    size_t steps[] = { 5, 11, 16, 1, 30, 3, 64, 7 };
    size_t total = 0;
    NSMutableData *buffer = [[NSMutableData alloc] initWithLength:64];
    for (size_t s = 0; s < sizeof(steps) / sizeof(steps[0]); s++) {
        XCTAssertTrue([ctr encryptIn:buffer.bytes out:buffer.mutableBytes len:steps[s]]);
        total += steps[s];
        size_t blocks = (total + 15) / 16;

        unsigned char expectedIv[16];
        memcpy(expectedIv, iv.bytes, 16);
        for (size_t b = 0; b < blocks; b++) {
            ctrIncrement128(expectedIv);
        }
        unsigned char actualIv[16];
        [ctr getIv:actualIv];
        XCTAssertEqual(memcmp(actualIv, expectedIv, 16), 0, @"iv after %zu bytes", total);
        XCTAssertEqual([ctr num], (uint32_t)(total % 16));

        if (total % 16 != 0) {
            unsigned char lastCounter[16];
            memcpy(lastCounter, iv.bytes, 16);
            for (size_t b = 0; b + 1 < blocks; b++) {
                ctrIncrement128(lastCounter);
            }
            unsigned char expectedEcount[16];
            ctrEncryptBlock(key.bytes, lastCounter, expectedEcount);
            XCTAssertEqual(memcmp([ctr ecount], expectedEcount, 16), 0, @"ecount after %zu bytes", total);
        }
    }
}

// A cipher rebuilt from (iv, ecount, num) continues the same stream.
- (void)testEcountInitializerResumesStream {
    NSData *key = ctrRandomData(32);
    NSData *iv = ctrRandomData(16);
    NSData *input = ctrRandomData(1000);
    NSData *expected = ctrReference(key, iv, input);
    size_t splits[] = { 1, 7, 15, 16, 17, 333 };
    for (size_t s = 0; s < sizeof(splits) / sizeof(splits[0]); s++) {
        size_t split = splits[s];
        MTAesCtr *first = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:false];
        NSMutableData *output = [[NSMutableData alloc] initWithLength:input.length];
        XCTAssertTrue([first encryptIn:input.bytes out:output.mutableBytes len:split]);

        unsigned char resumeIv[16];
        [first getIv:resumeIv];
        unsigned char resumeEcount[16];
        memcpy(resumeEcount, [first ecount], 16);
        MTAesCtr *second = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:resumeIv ecount:resumeEcount num:[first num]];
        XCTAssertNotNil(second);
        XCTAssertTrue([second encryptIn:(const unsigned char *)input.bytes + split out:(unsigned char *)output.mutableBytes + split len:input.length - split]);
        XCTAssertEqualObjects(output, expected, @"split at %zu", split);
    }
}

- (void)testInPlaceAndUnalignedBuffers {
    NSData *key = ctrRandomData(32);
    NSData *iv = ctrRandomData(16);
    NSData *input = ctrRandomData(5000);
    NSData *expected = ctrReference(key, iv, input);
    for (size_t shift = 0; shift < 4; shift++) {
        NSMutableData *buffer = [[NSMutableData alloc] initWithLength:input.length + shift];
        memcpy((unsigned char *)buffer.mutableBytes + shift, input.bytes, input.length);
        MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:true];
        unsigned char *bytes = (unsigned char *)buffer.mutableBytes + shift;
        XCTAssertTrue([ctr encryptIn:bytes out:bytes len:3]);
        XCTAssertTrue([ctr encryptIn:bytes + 3 out:bytes + 3 len:input.length - 3]);
        XCTAssertEqual(memcmp(bytes, expected.bytes, input.length), 0, @"shift %zu", shift);
    }
}

- (void)testCdnHelperMatchesReference {
    NSData *key = ctrRandomData(32);
    NSData *iv = ctrRandomData(16);
    NSData *input = ctrRandomData(128 * 1024 + 3);
    XCTAssertEqualObjects(MTAesCtrDecrypt(input, key, iv), ctrReference(key, iv, input));
}

// Cost of the transport cipher, in the chunk sizes TCP reads deliver.
- (void)testThroughputBenchmark {
    NSData *key = ctrRandomData(32);
    NSData *iv = ctrRandomData(16);
    const size_t total = 8 * 1024 * 1024;
    NSMutableData *buffer = [ctrRandomData(total) mutableCopy];
    MTAesCtr *ctr = [[MTAesCtr alloc] initWithKey:key.bytes keyLength:32 iv:iv.bytes decrypt:false];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    size_t offset = 0;
    const size_t chunk = 4093;
    while (offset < total) {
        size_t length = MIN(chunk, total - offset);
        [ctr encryptIn:(unsigned char *)buffer.mutableBytes + offset out:(unsigned char *)buffer.mutableBytes + offset len:length];
        offset += length;
    }
    double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    NSLog(@"MTAesCtr benchmark: 8 MiB in 4093-byte chunks: %.2f ms (%.1f MB/s)", ms, (double)total / 1e6 / (ms / 1000.0));
}

@end
