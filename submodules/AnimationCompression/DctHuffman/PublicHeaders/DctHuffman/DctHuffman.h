#ifndef DctHuffman_h
#define DctHuffman_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Huffman-codes a plane of quantized DCT coefficients (8x8 blocks, zigzag order within a block).
/// Returns nil when the size is not whole blocks or a coefficient is not finite or is outside what
/// the coder represents: such a plane is not DCT output.
NSData * _Nullable writeDCTBlocks(int width, int height, float const * _Nonnull coefficients);
void readDCTBlocks(int width, int height, NSData * _Nonnull blockData, float * _Nonnull coefficients, int elementsPerRow);

#ifdef __cplusplus
}
#endif

#endif /* DctHuffman_h */
