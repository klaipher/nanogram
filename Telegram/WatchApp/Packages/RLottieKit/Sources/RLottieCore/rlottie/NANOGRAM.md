# Vendored rlottie

Base: Samsung/rlottie **v0.2** (`bf3d272df3916a0c34575ac8286cb0fe672fd0d4`, the latest release),
`src/` and `inc/` only, CMake/meson files removed, `src/config.h` hand-written (all optional
features off).

On top of it, the upstream security fixes from Samsung/rlottie master (2025-2026), cherry-picked
in this order (conflicts were context only, resolved to the upstream side):

    507ea02 346c9b6 9e4f354 1cda060 b4f5101 5def9f4 ffe6094 729e5d0 bf689b7 f487eff
    25648ae 2cab35d 27f2f23 8de0d9e 480a2ad ea06d2f

One local change: `kMaxModelTreeDepth` (`src/lottie/lottiemodel.h`) is 65, not upstream's 32,
as the iOS app's rlottie had (`submodules/rlottie`, removed 2026-11-11), so nothing tlottie accepts is cut.

Deliberately NOT taken, because they change how valid Telegram stickers render:

- `34465a9` (shape-content budget): charges 1024 points per animated path, so ordinary
  stickers run out of budget and lose shapes (bisected with `StickerRenderRegressionTests`).
- `12facb8` (#529, 2022): adds one frame to every animation's `totalFrame` and makes layers
  visible at their out-point. Telegram (and the iOS app) treat `op` as exclusive.

Upstream master is therefore not a drop-in update. Verified 2026-11-01: the 355 animations
bundled with the iOS app render byte-identically to v0.2 (frames 0, mid, last at 128 px).
