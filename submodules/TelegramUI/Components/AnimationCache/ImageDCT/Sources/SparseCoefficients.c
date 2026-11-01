#include <ImageDCT/SparseCoefficients.h>

#include <string.h>
#include <pthread.h>

#if defined(__aarch64__)
#include <arm_neon.h>

// For each mask byte: the byte shuffle that spreads the packed values into 8 lanes.
// Index 0xff yields 0 in vqtbl1q_u8.
static uint8_t expandTable[256][16];
static pthread_once_t expandTableOnce = PTHREAD_ONCE_INIT;

static void buildExpandTable(void) {
    for (int bits = 0; bits < 256; bits++) {
        int k = 0;
        for (int j = 0; j < 8; j++) {
            if (bits & (1 << j)) {
                expandTable[bits][j * 2] = (uint8_t)(k * 2);
                expandTable[bits][j * 2 + 1] = (uint8_t)(k * 2 + 1);
                k++;
            } else {
                expandTable[bits][j * 2] = 0xff;
                expandTable[bits][j * 2 + 1] = 0xff;
            }
        }
    }
}
#endif

size_t sparseCoefficientsMaxEncodedLength(size_t count) {
    return (count + 7) / 8 + count * 2;
}

size_t sparseCoefficientsEncode(int16_t const *source, size_t count, uint8_t *dest) {
    uint8_t *out = dest;
    size_t i = 0;
    while (i + 8 <= count) {
        uint64_t a, b;
        memcpy(&a, source + i, 8);
        memcpy(&b, source + i + 4, 8);
        if ((a | b) == 0) {
            *out++ = 0;
        } else {
            uint8_t *mask = out++;
            uint8_t bits = 0;
            for (int j = 0; j < 8; j++) {
                int16_t value = source[i + j];
                if (value != 0) {
                    bits |= (uint8_t)(1 << j);
                    memcpy(out, &value, 2);
                    out += 2;
                }
            }
            *mask = bits;
        }
        i += 8;
    }
    if (i < count) {
        uint8_t *mask = out++;
        uint8_t bits = 0;
        for (int j = 0; i + j < count; j++) {
            int16_t value = source[i + j];
            if (value != 0) {
                bits |= (uint8_t)(1 << j);
                memcpy(out, &value, 2);
                out += 2;
            }
        }
        *mask = bits;
    }
    return (size_t)(out - dest);
}

bool sparseCoefficientsDecode(uint8_t const *source, size_t sourceLength, int16_t *dest, size_t count) {
    size_t offset = 0;
    size_t i = 0;
#if defined(__aarch64__)
    pthread_once(&expandTableOnce, buildExpandTable);
    uint8x16_t const zero = vdupq_n_u8(0);
    while (i + 8 <= count) {
        if (offset >= sourceLength) {
            return false;
        }
        uint8_t bits = source[offset++];
        if (bits == 0) {
            vst1q_u8((uint8_t *)(dest + i), zero);
        } else {
            size_t needed = (size_t)__builtin_popcount(bits) * 2;
            if (sourceLength - offset < needed) {
                return false;
            }
            if (sourceLength - offset >= 16) {
                uint8x16_t packed = vld1q_u8(source + offset);
                vst1q_u8((uint8_t *)(dest + i), vqtbl1q_u8(packed, vld1q_u8(expandTable[bits])));
            } else {
                for (size_t j = 0, k = 0; j < 8; j++) {
                    if (bits & (1 << j)) {
                        memcpy(dest + i + j, source + offset + k, 2);
                        k += 2;
                    } else {
                        dest[i + j] = 0;
                    }
                }
            }
            offset += needed;
        }
        i += 8;
    }
#endif
    while (i < count) {
        if (offset >= sourceLength) {
            return false;
        }
        uint8_t bits = source[offset++];
        size_t groupCount = count - i < 8 ? count - i : 8;
        if (groupCount < 8 && (bits >> groupCount) != 0) {
            return false;
        }
        if (bits == 0) {
            memset(dest + i, 0, groupCount * 2);
        } else {
            size_t needed = (size_t)__builtin_popcount(bits) * 2;
            if (sourceLength - offset < needed) {
                return false;
            }
            for (size_t j = 0; j < groupCount; j++) {
                if (bits & (1 << j)) {
                    memcpy(dest + i + j, source + offset, 2);
                    offset += 2;
                } else {
                    dest[i + j] = 0;
                }
            }
        }
        i += groupCount;
    }
    return offset == sourceLength;
}
