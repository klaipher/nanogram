# W4.2 and W5.3 (iOS stage C): what was compared before the iOS copies were deleted

Nothing here was built or run; every comparison is a `cmp`, `diff` or blob comparison made at the parent commit of each commit.

## W4.2: tgcalls bridge and wasm script move into the fork

- Fork: klaipher/tgcalls `nanogram-shared` (local `nanogram-shared-next` 2a5daa0f14f89def3fd15179e30baca95b891c43).
- `cmp` of every moved file between the iOS tree (`submodules/TgVoipWebrtc/...`) and the fork's `ios/...`: identical for
  `Sources/OngoingCallThreadLocalContext.mm`, `Sources/MediaStreaming.mm`, `Sources/MediaUtils.h`, `tests/TestNegotiation.mm`,
  `PublicHeaders/TgVoipWebrtc/MediaStreaming.h`, `PublicHeaders/TgVoipWebrtc/OngoingCallThreadLocalContext.h`.
- `cmp submodules/TgVoipWebrtc/tools/wasm_to_source.py tgcalls/tools/wasm_to_source.py`: identical.
- A pure-Python check over the fork tree (`git ls-files`) found one `.cpp` under `tgcalls/` that the iOS BUILD does not
  name: `tgcalls/v2_4_0_0/Signaling_4_0_0.cpp` (not in the iOS BUILD before the merge either; not compiled, as before).
