#import "MTAes.h"

#import <CommonCrypto/CommonCrypto.h>

#if defined(__aarch64__) && defined(__ARM_NEON)
#define MT_AES_HAS_ARMV8_AES 1
#include <arm_neon.h>
#else
#define MT_AES_HAS_ARMV8_AES 0
#endif

#import <MtProtoKit/MTLogging.h>

# define AES_MAXNR 14
# define AES_BLOCK_SIZE 16

#define N_WORDS (AES_BLOCK_SIZE / sizeof(unsigned long))
typedef struct {
    unsigned long data[N_WORDS];
} aes_block_t;

/* XXX: probably some better way to do this */
#if defined(__i386__) || defined(__x86_64__)
# define UNALIGNED_MEMOPS_ARE_FAST 1
#else
# define UNALIGNED_MEMOPS_ARE_FAST 0
#endif

#if UNALIGNED_MEMOPS_ARE_FAST
# define load_block(d, s)        (d) = *(const aes_block_t *)(s)
# define store_block(d, s)       *(aes_block_t *)(d) = (s)
#else
# define load_block(d, s)        memcpy((d).data, (s), AES_BLOCK_SIZE)
# define store_block(d, s)       memcpy((d), (s).data, AES_BLOCK_SIZE)
#endif

// Every failure path below zeroes the whole output buffer before returning
// false. The IGE feedback passes XOR plaintext blocks into the output, so a
// buffer left untouched after a failed CCCrypt would carry the plaintext
// shifted by one block; a caller that ignores the result must never be able
// to forward that. Release builds compile assert() out, so these checks are
// real branches rather than assertions.
static void MTAesZeroOutput(void *outBytes, int length) {
    if (outBytes != NULL && length > 0) {
        memset(outBytes, 0, (size_t)length);
    }
}

static void MTAesLogFailure(const char *operation, int status) {
    if (MTLogEnabled()) {
        MTLog(@"***** %s: CommonCrypto failed with status %d", operation, status);
    }
}

bool MyAesIgeEncrypt(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv) {
    if (length < 0 || length % AES_BLOCK_SIZE != 0) {
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    if (length == 0) {
        return true;
    }

    int len;
    size_t n;
    void const *inB;
    void *outB;
    
    unsigned char aesIv[AES_BLOCK_SIZE];
    memcpy(aesIv, iv, AES_BLOCK_SIZE);
    unsigned char ccIv[AES_BLOCK_SIZE];
    memcpy(ccIv, iv + AES_BLOCK_SIZE, AES_BLOCK_SIZE);
    
    assert(((size_t)inBytes | (size_t)outBytes | (size_t)aesIv | (size_t)ccIv) % sizeof(long) ==
           0);
    
    void *tmpInBytes = malloc(length);
    if (tmpInBytes == NULL) {
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    len = length / AES_BLOCK_SIZE;
    inB = inBytes;
    outB = tmpInBytes;
    
    aes_block_t *inp = (aes_block_t *)inB;
    aes_block_t *outp = (aes_block_t *)outB;
    for (n = 0; n < N_WORDS; ++n) {
        outp->data[n] = inp->data[n];
    }
    
    --len;
    inB += AES_BLOCK_SIZE;
    outB += AES_BLOCK_SIZE;
    void const *inBCC = inBytes;
    
    aes_block_t const *iv3p = (aes_block_t *)ccIv;
    
    if (len > 0) {
        while (len) {
            aes_block_t *inp = (aes_block_t *)inB;
            aes_block_t *outp = (aes_block_t *)outB;
            
            for (n = 0; n < N_WORDS; ++n) {
                outp->data[n] = inp->data[n] ^ iv3p->data[n];
            }
            
            iv3p = inBCC;
            --len;
            inBCC += AES_BLOCK_SIZE;
            inB += AES_BLOCK_SIZE;
            outB += AES_BLOCK_SIZE;
        }
    }
    
    size_t realOutLength = 0;
    CCCryptorStatus result = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, 0, key, keyLength, aesIv, tmpInBytes, length, outBytes, length, &realOutLength);
    free(tmpInBytes);
    
    if (result != kCCSuccess || realOutLength != (size_t)length) {
        MTAesLogFailure("MyAesIgeEncrypt", (int)result);
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    
    len = length / AES_BLOCK_SIZE;
    
    aes_block_t const *ivp = inB;
    aes_block_t *iv2p = (aes_block_t *)ccIv;
    
    inB = inBytes;
    outB = outBytes;
    
    while (len) {
        aes_block_t *inp = (aes_block_t *)inB;
        aes_block_t *outp = (aes_block_t *)outB;
        
        for (n = 0; n < N_WORDS; ++n) {
            outp->data[n] ^= iv2p->data[n];
        }
        ivp = outp;
        iv2p = inp;
        --len;
        inB += AES_BLOCK_SIZE;
        outB += AES_BLOCK_SIZE;
    }
    
    memcpy(iv, ivp->data, AES_BLOCK_SIZE);
    memcpy(iv + AES_BLOCK_SIZE, iv2p->data, AES_BLOCK_SIZE);
    return true;
}

#if MT_AES_HAS_ARMV8_AES

#define MT_AES_MAX_ROUND_KEYS 15

__attribute__((target("aes")))
static uint32_t MTAesSubWord(uint32_t word) {
    uint8x16_t state = vreinterpretq_u8_u32(vdupq_n_u32(word));
    uint8x16_t substituted = vaeseq_u8(state, vdupq_n_u8(0));
    return vgetq_lane_u32(vreinterpretq_u32_u8(substituted), 0);
}

// FIPS 197 key expansion. Returns the round count, or 0 for an unsupported key length.
__attribute__((target("aes")))
static int MTAesExpandKey(const void *key, int keyLength, uint8x16_t *roundKeys) {
    if (keyLength != 16 && keyLength != 24 && keyLength != 32) {
        return 0;
    }
    const int wordsInKey = keyLength / 4;
    const int rounds = wordsInKey + 6;
    const int totalWords = 4 * (rounds + 1);
    uint32_t words[60];
    memcpy(words, key, (size_t)keyLength);
    uint32_t rcon = 1;
    for (int i = wordsInKey; i < totalWords; i++) {
        uint32_t temp = words[i - 1];
        if (i % wordsInKey == 0) {
            temp = MTAesSubWord((temp >> 8) | (temp << 24)) ^ rcon;
            rcon = (rcon << 1) ^ ((rcon & 0x80) ? 0x11b : 0);
        } else if (wordsInKey > 6 && i % wordsInKey == 4) {
            temp = MTAesSubWord(temp);
        }
        words[i] = words[i - wordsInKey] ^ temp;
    }
    for (int i = 0; i <= rounds; i++) {
        roundKeys[i] = vld1q_u8((const uint8_t *)&words[4 * i]);
    }
    return rounds;
}

// IGE decrypt as one fused loop on the ARMv8 AESD/AESIMC instructions:
// plain[i] = D(cipher[i] ^ plain[i-1]) ^ cipher[i-1]. Block reads happen before
// block writes, so it is also safe for in-place use.
__attribute__((target("aes")))
static bool MyAesIgeDecryptArmv8(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv) {
    uint8x16_t roundKeys[MT_AES_MAX_ROUND_KEYS];
    int rounds = MTAesExpandKey(key, keyLength, roundKeys);
    if (rounds == 0) {
        MTAesLogFailure("MyAesIgeDecrypt (key)", -1);
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    uint8x16_t inverseKeys[MT_AES_MAX_ROUND_KEYS];
    for (int r = 1; r < rounds; r++) {
        inverseKeys[r] = vaesimcq_u8(roundKeys[r]);
    }
    
    const uint8_t *in = (const uint8_t *)inBytes;
    uint8_t *out = (uint8_t *)outBytes;
    uint8x16_t previousCipher = vld1q_u8((const uint8_t *)iv);
    uint8x16_t previousPlain = vld1q_u8((const uint8_t *)iv + AES_BLOCK_SIZE);
    const uint8x16_t lastKey = roundKeys[rounds];
    const uint8x16_t firstKey = roundKeys[0];
    
    for (int blocks = length / AES_BLOCK_SIZE; blocks > 0; blocks--) {
        uint8x16_t cipher = vld1q_u8(in);
        uint8x16_t state = vaesdq_u8(veorq_u8(cipher, previousPlain), lastKey);
        for (int r = rounds - 1; r >= 1; r--) {
            state = vaesdq_u8(vaesimcq_u8(state), inverseKeys[r]);
        }
        uint8x16_t plain = veorq_u8(veorq_u8(state, firstKey), previousCipher);
        vst1q_u8(out, plain);
        previousCipher = cipher;
        previousPlain = plain;
        in += AES_BLOCK_SIZE;
        out += AES_BLOCK_SIZE;
    }
    
    vst1q_u8((uint8_t *)iv, previousCipher);
    vst1q_u8((uint8_t *)iv + AES_BLOCK_SIZE, previousPlain);
    return true;
}

#endif

bool MyAesIgeDecryptReference(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv) {
    if (length < 0 || length % AES_BLOCK_SIZE != 0) {
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    if (length == 0) {
        return true;
    }
    void *outStart = outBytes;
    
    unsigned char aesIv[AES_BLOCK_SIZE];
    memcpy(aesIv, iv, AES_BLOCK_SIZE);
    unsigned char ccIv[AES_BLOCK_SIZE];
    memcpy(ccIv, iv + AES_BLOCK_SIZE, AES_BLOCK_SIZE);
    
    assert(((size_t)inBytes | (size_t)outBytes | (size_t)aesIv | (size_t)ccIv) % sizeof(long) ==
           0);
    
    CCCryptorRef decryptor = NULL;
    CCCryptorStatus createStatus = CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode, key, keyLength, nil, &decryptor);
    if (createStatus != kCCSuccess || decryptor == NULL) {
        MTAesLogFailure("MyAesIgeDecrypt (create)", (int)createStatus);
        MTAesZeroOutput(outStart, length);
        return false;
    }
    
    int len;
    size_t n;
    
    len = length / AES_BLOCK_SIZE;
    
    aes_block_t *ivp = (aes_block_t *)(aesIv);
    aes_block_t *iv2p = (aes_block_t *)(ccIv);
    
    while (len) {
        aes_block_t tmp;
        aes_block_t *inp = (aes_block_t *)inBytes;
        aes_block_t *outp = (aes_block_t *)outBytes;
        
        for (n = 0; n < N_WORDS; ++n)
            tmp.data[n] = inp->data[n] ^ iv2p->data[n];
        
        size_t dataOutMoved = 0;
        CCCryptorStatus result = CCCryptorUpdate(decryptor, &tmp, AES_BLOCK_SIZE, outBytes, AES_BLOCK_SIZE, &dataOutMoved);
        if (result != kCCSuccess || dataOutMoved != AES_BLOCK_SIZE) {
            MTAesLogFailure("MyAesIgeDecrypt (update)", (int)result);
            CCCryptorRelease(decryptor);
            MTAesZeroOutput(outStart, length);
            return false;
        }
        
        for (n = 0; n < N_WORDS; ++n)
            outp->data[n] ^= ivp->data[n];
        
        ivp = inp;
        iv2p = outp;
        
        inBytes += AES_BLOCK_SIZE;
        outBytes += AES_BLOCK_SIZE;
        
        --len;
    }
    
    memcpy(iv, ivp->data, AES_BLOCK_SIZE);
    memcpy(iv + AES_BLOCK_SIZE, iv2p->data, AES_BLOCK_SIZE);
    
    CCCryptorRelease(decryptor);
    return true;
}

bool MyAesIgeDecrypt(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv) {
#if MT_AES_HAS_ARMV8_AES
    if (length < 0 || length % AES_BLOCK_SIZE != 0) {
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    if (length == 0) {
        return true;
    }
    return MyAesIgeDecryptArmv8(inBytes, length, outBytes, key, keyLength, iv);
#else
    return MyAesIgeDecryptReference(inBytes, length, outBytes, key, keyLength, iv);
#endif
}

bool MyAesCbcDecrypt(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv) {
    if (length < 0) {
        return false;
    }
    size_t outLength = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, 0, key, keyLength, iv, inBytes, length, outBytes, length, &outLength);
    if (status != kCCSuccess || outLength != (size_t)length) {
        MTAesLogFailure("MyAesCbcDecrypt", (int)status);
        MTAesZeroOutput(outBytes, length);
        return false;
    }
    return true;
}

// 128-bit big-endian counter, as in OpenSSL's CRYPTO_ctr128_encrypt.
static void ctr128_inc(unsigned char *counter)
{
    uint32_t n = 16, c = 1;
    
    do {
        --n;
        c += counter[n];
        counter[n] = (uint8_t)c;
        c >>= 8;
    } while (n);
}

static uint64_t ctr128_low64(const unsigned char *counter)
{
    uint64_t value = 0;
    for (int i = 8; i < 16; i++) {
        value = (value << 8) | counter[i];
    }
    return value;
}

static void ctr128_add(unsigned char *counter, uint64_t blocks)
{
    uint64_t low = ctr128_low64(counter);
    uint64_t sum = low + blocks;
    for (int i = 15; i >= 8; i--) {
        counter[i] = (uint8_t)sum;
        sum >>= 8;
    }
    if (low + blocks < low) {
        for (int i = 7; i >= 0; i--) {
            counter[i]++;
            if (counter[i] != 0) {
                break;
            }
        }
    }
}

@interface MTAesCtr () {
    // ECB, for the rare stream that crosses a 2^64-block counter boundary.
    CCCryptorRef _cryptor;
    // Native CTR. CommonCrypto's counter is only 64 bits wide (it wraps
    // without a carry), so it is dropped at that boundary.
    CCCryptorRef _ctrCryptor;
    
    // Counter of the next keystream block; the CTR cryptor is always at it.
    unsigned char _ivec[16] __attribute__((aligned(16)));
    unsigned int _num;
    // Keystream of the current block; valid while _num != 0.
    unsigned char _ecount[16] __attribute__((aligned(16)));
}

@end

@implementation MTAesCtr

- (instancetype)initWithKey:(const void *)key keyLength:(int)keyLength iv:(const void *)iv decrypt:(bool)decrypt {
    self = [super init];
    if (self != nil) {
        _num = 0;
        memset(_ecount, 0, 16);
        memcpy(_ivec, iv, 16);
        
        if (![self createCryptorWithKey:key keyLength:keyLength]) {
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithKey:(const void *)key keyLength:(int)keyLength iv:(const void *)iv ecount:(void *)ecount num:(uint32_t)num {
    self = [super init];
    if (self != nil) {
        _num = num % 16;
        memcpy(_ecount, ecount, 16);
        memcpy(_ivec, iv, 16);
        
        if (![self createCryptorWithKey:key keyLength:keyLength]) {
            return nil;
        }
    }
    return self;
}

// Without a cryptor the keystream would be all zeros and encryptIn:out:len:
// would copy its input through unchanged, so a failed create must fail the init.
- (bool)createCryptorWithKey:(const void *)key keyLength:(int)keyLength {
    CCCryptorStatus status = CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode, key, keyLength, nil, &_cryptor);
    if (status != kCCSuccess || _cryptor == NULL) {
        MTAesLogFailure("MTAesCtr (create)", (int)status);
        _cryptor = NULL;
        return false;
    }
    status = CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, _ivec, key, keyLength, NULL, 0, 0, kCCModeOptionCTR_BE, &_ctrCryptor);
    if (status != kCCSuccess || _ctrCryptor == NULL) {
        MTAesLogFailure("MTAesCtr (create ctr)", (int)status);
        _ctrCryptor = NULL;
        return false;
    }
    return true;
}

- (void)dealloc {
    if (_cryptor) {
        CCCryptorRelease(_cryptor);
    }
    if (_ctrCryptor) {
        CCCryptorRelease(_ctrCryptor);
    }
}

- (uint32_t)num {
    return _num;
}

- (void *)ecount {
    return _ecount;
}

- (void)getIv:(void *)iv {
    memcpy(iv, _ivec, 16);
}

// XORs `blocks` whole keystream blocks into in -> out and advances _ivec.
- (bool)xorBlocksIn:(const unsigned char *)in out:(unsigned char *)out blocks:(size_t)blocks {
    while (blocks != 0) {
        if (_ctrCryptor != NULL) {
            // Blocks left before the low 64 bits wrap; 0 stands for 2^64.
            uint64_t untilWrap = 0 - ctr128_low64(_ivec);
            size_t chunk = blocks;
            bool reachesWrap = false;
            if (untilWrap != 0 && (uint64_t)chunk >= untilWrap) {
                chunk = (size_t)untilWrap;
                reachesWrap = true;
            }
            size_t bytes = chunk * 16;
            size_t moved = 0;
            CCCryptorStatus status = CCCryptorUpdate(_ctrCryptor, in, bytes, out, bytes, &moved);
            if (status != kCCSuccess || moved != bytes) {
                MTAesLogFailure("MTAesCtr (update)", (int)status);
                return false;
            }
            ctr128_add(_ivec, chunk);
            if (reachesWrap) {
                CCCryptorRelease(_ctrCryptor);
                _ctrCryptor = NULL;
            }
            in += bytes;
            out += bytes;
            blocks -= chunk;
        } else {
            unsigned char keystream[16];
            size_t moved = 0;
            CCCryptorStatus status = CCCryptorUpdate(_cryptor, _ivec, 16, keystream, 16, &moved);
            if (status != kCCSuccess || moved != 16) {
                MTAesLogFailure("MTAesCtr (update)", (int)status);
                return false;
            }
            ctr128_inc(_ivec);
            for (int i = 0; i < 16; i++) {
                out[i] = in[i] ^ keystream[i];
            }
            in += 16;
            out += 16;
            blocks -= 1;
        }
    }
    return true;
}

// On a keystream failure the not-yet-processed output is zeroed and false is
// returned; the input is never copied through.
- (bool)encryptIn:(const unsigned char *)in out:(unsigned char *)out len:(size_t)len {
    assert(in);
    assert(out);
    assert(_num < 16);
    
    unsigned int n = _num;
    while (n != 0 && len != 0) {
        *(out++) = *(in++) ^ _ecount[n];
        --len;
        n = (n + 1) % 16;
    }
    _num = n;
    if (len == 0) {
        return true;
    }
    
    size_t blocks = len / 16;
    if (blocks != 0) {
        if (![self xorBlocksIn:in out:out blocks:blocks]) {
            memset(out, 0, len);
            return false;
        }
        in += blocks * 16;
        out += blocks * 16;
        len -= blocks * 16;
    }
    
    if (len != 0) {
        static const unsigned char zeros[16] = { 0 };
        if (![self xorBlocksIn:zeros out:_ecount blocks:1]) {
            memset(out, 0, len);
            return false;
        }
        for (size_t i = 0; i < len; i++) {
            out[i] = in[i] ^ _ecount[i];
        }
        _num = (unsigned int)len;
    }
    return true;
}

@end
