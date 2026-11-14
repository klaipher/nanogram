// The layer-tree painter (M1d plan, Task 6): a published LayerTree drawn into a CGContext by replaying its items
// through LHContainer's CoreGraphics code (LHHostSupport.h), as LHDocument draws a document: the tile primitive the app
// paints with. It reads only the tree, so a tree whose runtime is gone still paints.
#pragma once

#include <CoreGraphics/CoreGraphics.h>

#include <cstddef>

class LHEffectStore;

namespace wr {
class LayerTree;
}

namespace wr::ios {

/// Filters nested past this draw their content unfiltered: each level is a bitmap made inside the one around it, and
/// widget-sandbox v0.6.5 (paint-filter-depth) has every client draw at most 16 (2,000 nested layers overflowed a stack).
constexpr size_t kMaxNestedFilters = 16;

constexpr bool canNestFilter(size_t openFilters) { return openFilters < kMaxNestedFilters; }

class LayerTreePainter {
public:
    /// Paints `tree`'s `rect` (CSS px) into `context` at `scale` device pixels per CSS px: the context's origin is the
    /// rect's top-left, y down, as LHDocument's copyImage draws. Filters stay CoreImage, as today. The paints of one draw
    /// pass one `effects` (twidget edit 64), so that each filter and backdrop result they show is made once.
    static void paint(const LayerTree& tree, CGContextRef context, CGRect rect, CGFloat scale, LHEffectStore* effects = nullptr);
    /// A `rect` image at `scale`: a premultiplied BGRA bitmap of ceil(width × scale) × ceil(height × scale) pixels, at
    /// most 4096 a side (nullptr past that, or for an empty rect). +1.
    static CGImageRef copyImage(const LayerTree& tree, CGRect rect, CGFloat scale, LHEffectStore* effects = nullptr);
};

} // namespace wr::ios
