// Host test for SparseCoefficients.c, built with AddressSanitizer and UndefinedBehaviorSanitizer
// (see BUILD). The decoder reads animation cache files from disk, so it must reject any
// input without reading or writing out of bounds. Buffers are allocated at their exact
// size so ASan reports a one-byte overrun.
//
// Run: tools/dev/tg test //submodules/TelegramUI/Components/AnimationCache/ImageDCT:SparseCoefficientsSanitizerTests

#include <ImageDCT/SparseCoefficients.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        failures++; \
        fprintf(stderr, "%s:%d: CHECK failed: %s: ", __FILE__, __LINE__, #cond); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
    } \
} while (0)

static uint64_t rngState = 0x9e3779b97f4a7c15ull;

static uint32_t nextRandom(void) {
    rngState ^= rngState << 13;
    rngState ^= rngState >> 7;
    rngState ^= rngState << 17;
    return (uint32_t)(rngState >> 32);
}

static void *exactAlloc(size_t size) {
    // malloc(0) may return NULL; keep a valid pointer that ASan still bounds-checks.
    void *p = malloc(size == 0 ? 1 : size);
    if (!p) {
        abort();
    }
    return p;
}

static void fillCoefficients(int16_t *values, size_t count, uint32_t density) {
    for (size_t i = 0; i < count; i++) {
        values[i] = (nextRandom() % 100) < density ? (int16_t)(nextRandom() & 0xffff) : 0;
    }
}

// Encoding into a buffer of exactly sparseCoefficientsMaxEncodedLength bytes and decoding the
// result gives the original values; every strict prefix of the encoding is rejected.
static void testRoundTripAndTruncation(size_t count, uint32_t density) {
    int16_t *source = exactAlloc(count * sizeof(int16_t));
    fillCoefficients(source, count, density);
    size_t maxLength = sparseCoefficientsMaxEncodedLength(count);
    uint8_t *encoded = exactAlloc(maxLength);
    size_t length = sparseCoefficientsEncode(source, count, encoded);
    CHECK(length <= maxLength, "count %zu: length %zu > max %zu", count, length, maxLength);

    uint8_t *exact = exactAlloc(length);
    memcpy(exact, encoded, length);
    int16_t *decoded = exactAlloc(count * sizeof(int16_t));
    CHECK(sparseCoefficientsDecode(exact, length, decoded, count), "count %zu density %u: decode failed", count, density);
    CHECK(count == 0 || memcmp(source, decoded, count * sizeof(int16_t)) == 0, "count %zu density %u: values differ", count, density);
    free(exact);

    for (size_t prefix = 0; prefix < length; prefix++) {
        uint8_t *truncated = exactAlloc(prefix);
        memcpy(truncated, encoded, prefix);
        CHECK(!sparseCoefficientsDecode(truncated, prefix, decoded, count), "count %zu: prefix %zu of %zu accepted", count, prefix, length);
        free(truncated);
    }

    // Trailing bytes are rejected too.
    uint8_t *longer = exactAlloc(length + 1);
    memcpy(longer, encoded, length);
    longer[length] = 0;
    CHECK(!sparseCoefficientsDecode(longer, length + 1, decoded, count), "count %zu: trailing byte accepted", count);
    free(longer);

    free(decoded);
    free(encoded);
    free(source);
}

// Arbitrary bytes (a corrupted cache file) never make the decoder touch memory outside its buffers.
static void testRandomInput(size_t iterations) {
    for (size_t n = 0; n < iterations; n++) {
        size_t count = nextRandom() % 80;
        size_t length = nextRandom() % 200;
        uint8_t *input = exactAlloc(length);
        for (size_t i = 0; i < length; i++) {
            // Mostly small masks, so inputs often get deep into the stream.
            input[i] = (nextRandom() % 4) == 0 ? (uint8_t)nextRandom() : (uint8_t)(nextRandom() & 0x03);
        }
        int16_t *output = exactAlloc(count * sizeof(int16_t));
        (void)sparseCoefficientsDecode(input, length, output, count);
        free(output);
        free(input);
    }
}

// A final partial group whose mask names values past `count` is rejected.
static void testMaskBitsPastCount(void) {
    uint8_t input[3] = { 0x02, 0x01, 0x00 };  // value at index 1 of a 1-value group
    int16_t output[1];
    CHECK(!sparseCoefficientsDecode(input, sizeof(input), output, 1), "mask bit past count accepted");
}

int main(void) {
    static const uint32_t densities[] = { 0, 5, 30, 100 };
    for (size_t count = 0; count <= 70; count++) {
        for (size_t d = 0; d < sizeof(densities) / sizeof(densities[0]); d++) {
            testRoundTripAndTruncation(count, densities[d]);
        }
    }
    testRoundTripAndTruncation(4096, 20);
    testRandomInput(200000);
    testMaskBitsPastCount();
    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("SparseCoefficientsSanitizerTests: all checks passed\n");
    return 0;
}
