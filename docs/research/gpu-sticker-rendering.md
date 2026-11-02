# GPU rendering of animated stickers and emoji (research note, 2026-11-01)

Status (2026-11-02): both GPU paths are **on by default** ("GPU for large" stickers and the emoji YUVA
path), after the owner checked them on an iPhone 17 Pro Max. Settings saved by earlier builds are upgraded
once (`ExperimentalUISettings.nanogramDefaultsRevision`); the two Debug Settings rows, side by side in
Experiments, still switch them back to the CPU, and that choice is kept.

## What GPU paths exist

1. **Stickers: `CompressedAnimationRenderer`** (`submodules/AnimatedStickerNode/Sources/CompressedAnimationRenderer.swift`).
   A Metal renderer for `DefaultAnimatedStickerNodeImpl`. It draws into a `MetalImageLayer`
   (`submodules/Components/MetalImageView`), which renders into a texture and hands the result to
   Core Animation as a `CGImage` in `layer.contents` (buffer-backed on device, so no copy). It draws
   three frame kinds: ARGB (an uncached rlottie frame), YUVA (the CPU frame cache, `.cached` sources,
   video stickers) and DCT. The DCT kind comes from its own frame cache, the `-mtl` file
   (`AnimatedStickerDirectFrameSourceCache(useHardware: true)`): each rlottie frame is DCT-encoded on
   the GPU and Huffman-coded on the CPU (`AnimationCompression`), and decoded with an IDCT compute
   kernel. Upstream wires it up only for `init(useMetalCache: true)`, which no caller passes; the
   global switch in `didLoad` is commented out. Dormant.
2. **Emoji: the DCT animation cache's YUVA path** (`DCTMultiAnimationRendererImpl.useYuvA`, behind
   `ExperimentalUISettings.compressedEmojiCache`). Custom emoji and other `MultiAnimationRenderer`
   items keep their frames as YUVA and convert them for display without the per-frame RGBA image.
   Its colour range/matrix bugs and buffer pooling were fixed in the perf-round2 branch
   (commit 632f1d87, "The DCT emoji YUVA path has correct range/matrix and pooled buffers"). Still off.

## Why they are probably off

- **Per-sticker Metal objects.** Every sticker node gets its own layer, command queue, texture sets
  and drawable pool. A chat or a sticker panel shows dozens of small animations; that is many small
  GPU uploads and command buffers per frame instead of one shared one.
- **Small images.** Most animations are 100-400 px. For an image that size, uploading it and waking
  the GPU can cost more than converting it on the CPU.
- **The cost is not compositing.** The expensive part is producing frames: rlottie rasterization,
  VP9 decode for video stickers, and compressing frames into the caches. A GPU renderer only replaces
  the last step (YUVA to RGBA and handing the image to Core Animation), and the DCT cache adds a GPU
  encode plus a CPU Huffman pass on the first play.
- **Feature gaps in the Metal sticker renderer**: no template tinting (`dynamicColor`, used by
  template custom emoji), no `averageColor` callback, `currentFrameImage` is nil, no frame cloning
  between nodes. These matter in "GPU for all"; "GPU for large" mostly avoids them. (`mulAlpha` is
  honoured since the first device run: `renderRgb` takes it from the frame.)

## What was measured on the device (CPU path)

iPhone 17 Pro Max, iOS 27.2, TestFlight build 202610312302, 10.9 min session with Instruments Time
Profiler (all processes), Activity Monitor and Power Profiler. Foreground total 167.7 s CPU.

- `SoftwareAnimationRenderer.render`: 4.1 s, of which 0.74 s on the main thread.
- `decodeYUVAToRGBA`: 2.5 s.
- `UIImageView` `setImage` for sticker frames: 1.1 s on the main thread (perf-round2 now writes
  untinted frames straight to `layer.contents`).
- For comparison, frame production: `cacheVideoAnimation` 13.9 s, `AnimationCacheItemWriterImpl.add`
  9.6 s, `VideoStickerDirectFrameSource.takeFrame` 7.0 s, LZFSE encode 12.1 s in total.

So the part a GPU renderer can take over is about 4-8 s of 168 s; frame production is several times
larger.

## The debug modes

- **"Stickers: renderer"** (`ExperimentalUISettings.stickerRendererMode`): CPU / GPU for large / GPU
  for all. Reopen open chats to apply: a node reads the mode when it is created.
  - *CPU*: today's behaviour.
  - *GPU for large*: nodes of at least 200x200 pixels (`animatedStickerLargePixelArea`) use the Metal
    renderer and the `-mtl` cache. Chat stickers are set up at 384 px on the long side and the
    full-screen preview at 400x400; panel and pack grids use 160x160 and emoji and reactions are
    smaller, so those stay on the CPU.
  - *GPU for all*: every `DefaultAnimatedStickerNodeImpl`.
  - The decision is `animatedStickerUsesMetalRenderer(mode:explicitlyRequested:width:height:)` and is
    made once per node: in `didLoad` when it does not depend on size, otherwise at the first `setup`
    (which gives the size), and the renderer is taken only then. The renderer and every frame source
    of the node read the same stored decision, so a Metal renderer never reads the CPU cache's
    frames or the reverse (the CPU renderer draws a DCT frame as nothing).
- **"Emoji: GPU renderer (YUVA)"** (`ExperimentalUISettings.compressedEmojiCache`, unchanged key).

## Fixes made to the dormant sticker path

- The `-mtl` cache passed `width * 4` as the row stride, but rendered frames are padded to the
  device row alignment; it now uses the frame's real stride.
- The DCT encoder needs whole 8x8 blocks of the half-size chroma planes, so 16-pixel multiples
  (it asserts 8 and would crash a debug build). With the Metal cache, the frame source now renders at
  the next multiple of 16 (the layer scales it), and the cache refuses other sizes.
- The Metal store now ignores out-of-range frame indices, as the CPU store does.

## The first device run crashed (build 202611012130), and what changed

`EXC_BAD_ACCESS` at `0xffffffff6dd50120` in `writeDCTBlocks`, on Metal's completion queue. The
faulting load was `ldr w20, [x9, w8, sxtw #2]` with `w8 = 0x80000000` and `x9` the coder's stack
`codewords` table: the DC difference was `INT_MIN`, so a plane read back from the GPU held a
coefficient that was not finite or beyond `Int32` (a float like that converts to `INT_MIN`). A DCT
kernel that ran cannot produce one (8-bit samples, quantizer at least 6.5: |value| < 160). Two
paths hand the coder planes the kernel did not write:

- **One texture set per compressor, rewritten while in flight.** Frames are queued on the main queue
  and issued back to back after a busy stretch (scrolling); frame N's completion handler read its
  planes while frame N+1's kernel wrote the same textures. Reproduced on a Mac: read-backs that mix
  two frames (decoded error 7.9/255 mean back to back against 1.2 spaced out). On the Mac the torn
  values stay finite; that a torn or unwritten read-back on the phone held garbage floats is the
  inference from the fault, not reproduced.
- **The command buffer's status was never checked**, so planes of a command buffer that failed (GPU
  use in the background, a timeout or reset) were read back and coded too.

The fix:

- `AnimationCompressor`: per-frame texture sets from a pool, returned after the read-back (at most
  4 in flight, extra frames are not cached); the command buffer's status is checked;
  `canCompress(width:height:)` (whole 16x16 blocks, at most 4096) is the one size rule, used by the
  sticker cache too. `compress` completes with nil when a frame is not compressed, and the cache
  then frees the index so a later pass retries; the frame is shown from the CPU render meanwhile.
- `writeDCTBlocks` refuses partial blocks and any coefficient that is not finite or beyond ±1023
  (returns nil) instead of indexing with it; `readDCTBlocks` ignores sizes it cannot fill.
- The coder lost the last block of every plane (the writer never flushed its last bits, the reader
  stopped one byte early, and `readDCTBlocks` then zeroed that block): a half-transparent grey 8x8
  square in the corner of every cached frame. Fixed both ends; the cache file is now `-mtl2`, and the
  old `-mtl` file is deleted, since its frames may also hold torn planes.
- `CompressedImageRenderer`: a cached frame's header is validated (`CompressedImageLayout`: plane
  sizes, strides and lengths must match the format) before anything is decoded into a texture;
  uploads happen on one serial queue into per-frame textures returned when the command buffer
  completes (they were rewritten from a global queue, by several frames at once, while the GPU read
  them); drawables are taken on the main queue only, and `MetalImageLayer`'s storage pool is locked
  (contents come back from a `CGImage` deallocator on any thread).
- The IDCT and ARGB shaders multiplied premultiplied input by alpha again (soft edges darkened:
  2.6% of channel values more than 16/255 off, 0.6% without). ARGB frames from video stickers are
  not premultiplied, so `renderRgb` takes `multiplyAlpha` from the frame.

Checked with a scratch macOS harness (not checked in: a SwiftPM package compiling
`AnimationCompression`'s sources and `DCT.metal` for the Mac's GPU, rendering `Slot_M_Berries.tgs`
with the watch app's RLottieKit) that drives the compressor as the cache does and decodes as the
renderer does. After the fix, under Address
Sanitizer: every frame at 384x384, 384x160, 160x160 and 400x400 at 60 fps round-trips within a mean
of 1.42/255 and 1.8% outliers; back-to-back bursts and 8 compressors at once do not crash (frames
beyond 4 in flight are skipped, not torn); an injected `-inf`, `NaN` or `3e9` coefficient is refused
instead of crashing. `DctCodecTests` pins the coder, the size rules and the frame-format checks
without a Metal device.

**Not verified at run time.** `StickerMetalRenderingTests` renders a real sticker through the `-mtl`
cache and `CompressedAnimationRenderer` and compares it with the CPU frame (ARGB within 2/255; DCT and
YUVA within a mean of 3/255). The Bazel runner runs the bundle as a logic test, where the simulator
gives the process no Metal device, so those two tests skip; a hosted variant stalled in xcodebuild
before the first test. They run wherever a Metal device exists. The first real check is the phone.

## Video stickers vanished under "GPU for large" (fixed 2026-11-02)

On the phone a video sticker in a chat showed and then disappeared; with the CPU renderer it played.
A video sticker's first loop is decoded (BGRA frames, drawn by `renderRgb`) and stored in its frame
cache; every later loop, and every loop after the chat is reopened, is read back from that cache as
YUVA. YUVA frames (also everything a `.cached` source plays) were drawn fully transparent.

The cause was the YUVA upload, rewritten in e6203b5d: it read the alpha plane from
`2wh - w/2·h` (= 1.5·w·h, the end of the chroma plane) instead of `2wh`, where `encodeRGBAToYUVA`
writes it. The caches allocate `2wh + w/2·h` bytes and zero them, and nothing writes the gap between
the chroma plane and alpha, so every alpha read was 0. `YuvaFrameLayout` (AnimationCompression) is now
the one description of the format; `YuvaFrameLayoutTests` checks it against the encoder, against
`decodeYUVAToRGBA` and against a real VP9 sticker's cached frames (red before, green after). The cached
data was right, so no cache version changed.

Also changed: the YUVA shader converted with BT.601 coefficients while the CPU caches encode and decode
full-range BT.709; it now uses BT.709. Odd sizes (a non-square sticker fitted to 384 can be 384x255),
which the shader's half-size textures cannot describe, are decoded on the CPU as
`SoftwareAnimationRenderer` does and drawn as BGRA (`compressedAnimationYuvaDrawing`); before, they
were dropped, so such a sticker vanished too.

Measured with a scratch macOS harness (DCT.metal from the repo compiled for the Mac's GPU, the
textures uploaded as `CompressedImageRenderer` uploads them) on all 24 frames of `sticker_vp9.webm`,
decoded and cached by `VideoStickerDirectFrameSource` in the simulator, against what the CPU renderer
draws:

| size | before: covered pixels (CPU) | after: mean / max difference |
|---|---|---|
| 384x384 | 0 (39,500) | 0.12 / 8 of 255 |
| 400x400 | 0 (42,860) | 0.12 / 9 |
| 384x256 | 0 (26,359) | 0.13 / 8 |
| 384x255 | dropped | 0 / 0 (CPU decode) |

The first loop (BGRA, `multiplyAlpha`) was already within 1/255. BT.601 instead of BT.709 alone was
0.21 mean on this low-saturation sticker. The remaining differences are chroma upsampling (linear in
the shader).

## Measurement protocol

1. Same build, same account, same chat (one with many stickers, scrolled the same way), same
   duration, phone unplugged, brightness fixed.
2. For each mode (CPU, GPU for large, GPU for all, and emoji YUVA on/off): set it, kill and relaunch
   the app, open the chat once to warm the caches, then record.
3. Instruments on the phone: Power Profiler, Time Profiler and Metal System Trace.
4. Compare total energy impact, CPU time (app and main thread), GPU time, and memory footprint.
5. Keep a GPU mode only if total energy drops. Lower CPU with higher GPU energy is not a win.
