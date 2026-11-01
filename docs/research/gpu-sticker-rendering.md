# GPU rendering of animated stickers and emoji (research note, 2026-11-01)

Status: both GPU paths are **off by default**. Two Debug Settings rows, side by side in Experiments,
turn them on so they can be measured on a phone.

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
  between nodes, and `mulAlpha` is ignored (video frames with straight alpha). These matter in
  "GPU for all"; "GPU for large" mostly avoids them.

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

**Not verified at run time.** `StickerMetalRenderingTests` renders a real sticker through the `-mtl`
cache and `CompressedAnimationRenderer` and compares it with the CPU frame (ARGB within 2/255; DCT and
YUVA within a mean of 3/255). The Bazel runner runs the bundle as a logic test, where the simulator
gives the process no Metal device, so those two tests skip; a hosted variant stalled in xcodebuild
before the first test. They run wherever a Metal device exists. The first real check is the phone.

## Measurement protocol

1. Same build, same account, same chat (one with many stickers, scrolled the same way), same
   duration, phone unplugged, brightness fixed.
2. For each mode (CPU, GPU for large, GPU for all, and emoji YUVA on/off): set it, kill and relaunch
   the app, open the chat once to warm the caches, then record.
3. Instruments on the phone: Power Profiler, Time Profiler and Metal System Trace.
4. Compare total energy impact, CPU time (app and main thread), GPU time, and memory footprint.
5. Keep a GPU mode only if total energy drops. Lower CPU with higher GPU energy is not a win.
