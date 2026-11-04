# JPEG library (MozjpegBinding)

## JPEG library (`MozjpegBinding`)

`MozjpegBinding` keeps its name but links **libjpeg-turbo 3.2.1** (`//third-party/libjpeg-turbo`, built from the
official release archive pinned by checksum in `MODULE.bazel`), not mozjpeg 4.1.5 (unmaintained, libjpeg-turbo 2.1.x
decoder). The app only ever ran mozjpeg in its `JCP_FASTEST` profile, which is plain libjpeg-turbo: the encoders are
byte-identical and the decoder pixel-identical (`MozjpegBindingTests` pins goldens recorded from mozjpeg). Non-obvious:

- **`compressMiniThumbnail`'s output is protocol.** The stripped thumbnail is matched against a fixed JPEG header that
  every Telegram client re-attaches, so the encoder's tables must not change: no encoder settings, no other library.
- **ImageIO is not a substitute** (measured on the Mac, 2026-11-02): at equal luma SSIM its files are +16% for photos
  at upload sizes (+7% to +60%) and +21% for 40 px thumbnails, and it cannot produce the fixed header. As a decoder
  it was 2-9x slower on cache-sized JPEGs and differs by up to 122 levels from what is shown today.
- **`decompressImage` decodes untrusted data** (tiny thumbnails from chats, the media cache) for DirectMediaImageCache:
  any failure returns nil so the caller falls back to `UIImage(data:)`; sides over 8192 are refused.
- The JPEG XL functions compile to stubs returning nil: `USE_JPEGXL` is undefined and libjxl is not linked.
