#ifndef SparseCoefficients_h
#define SparseCoefficients_h

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Packs int16 coefficients as groups of 8: one byte with a bit per non-zero
// value, then the non-zero values (little endian). Mostly-zero DCT data
// shrinks ~6x, so the general-purpose compressor after it has less to do.

size_t sparseCoefficientsMaxEncodedLength(size_t count);
size_t sparseCoefficientsEncode(int16_t const *source, size_t count, uint8_t *dest);
// Returns false unless `source` decodes to exactly `count` values and is fully consumed.
bool sparseCoefficientsDecode(uint8_t const *source, size_t sourceLength, int16_t *dest, size_t count);

#ifdef __cplusplus
}
#endif

#endif /* SparseCoefficients_h */
