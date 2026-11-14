// iOS only, Nanogram's, not twidget's. Four headers of the fork's Apple layer (include/LHDocument.h, LHGPURenderer.h,
// LHImages.h, LHTextFragment.h) and LHContainer.mm start with a stray `#import <Cocoa/Cocoa.h>` ahead of their
// `#if TARGET_OS_OSX ... #else Foundation, CoreGraphics #endif` block (a merge artifact; iOS has no Cocoa). This header, on
// the include path of :LiteHTML only, answers that import with what the guard imports for iOS. Delete it, with its
// `textual_hdrs` and `includes` entries in BUILD, once the fork drops the stray lines (VENDOR.md, "Fork follow-up").
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
