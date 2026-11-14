#import <Foundation/Foundation.h>

#import <MtProtoKit/MTEncryption.h>


// Each returns true on success. On failure (bad key or length, or a CommonCrypto
// error) the whole output buffer is zeroed and false is returned, so a caller
// that ignores the result never forwards plaintext-derived bytes.
bool MyAesIgeEncrypt(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv);
bool MyAesIgeDecrypt(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv);
bool MyAesCbcDecrypt(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv);
// The per-block CommonCrypto implementation, kept as the oracle for tests and as the non-arm64 path.
bool MyAesIgeDecryptReference(const void *inBytes, int length, void *outBytes, const void *key, int keyLength, void *iv);
