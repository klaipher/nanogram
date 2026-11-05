# Media decode, animation caches and the voice recorder input

## Media decode, animation caches and the voice recorder input (2026-11)

- **FFmpeg `get_format`** (`FFMpegAVCodecContext.m`) must return VideoToolbox only when it is in the
  offered list, else the last (software) entry: FFmpeg calls it again without VideoToolbox when the
  hwaccel setup fails, and any format not in the list fails the decoder. The iOS 27.2 simulator has
  no working VideoToolbox hwaccel, so hardware readers there run FFmpeg's software fallback and the
  VideoToolbox-only tests skip (`FFMpegHardwareFallbackTests` forces the failure on purpose).
- **GIF tiles** (`BatchVideoRenderingContext`) use the hwaccel for clips whose longer side is
  >= 320 px and hold one of 16 `HardwareDecoderBudget` slots per hardware reader; every path that
  drops a reader must go through `releaseReader()` or the slot leaks. The tiles detect a loop by pts
  going backwards, so they need presentation-order frames: never feed them passthrough samples.
- **Video-sticker `.cached` files** (`makeVideoStickerFrameCache`, AnimatedStickerNode) stay LZFSE:
  on their XOR deltas LZ4 decodes slower and every displayed frame is decoded again. The hardware
  VP9 path must produce byte-identical files to libvpx (`VideoStickerFrameCacheTests` keeps the
  previous writer as the golden reference).
- **DCT animation cache format 8**: the codec byte follows the version; blocks end only at frame
  boundaries (`BlockCompressedFileWriter.endFrame`). The writer uses LZBITMAP (LZMESH is read on
  iOS 27+ but decodes no faster). First-frame adaptation lists each shard directory once per process
  (`AdaptationSizeIndex`) and then only stats sizes this process has seen; every place that stores
  an item must call `adaptationSizeIndex.noteSize`. Its lock guards only its two sets: listing and
  stat run outside it, because `getFirstFrameSynchronously` runs on the main thread and must not wait
  for a fetch queue's listing. A finished conversion is moved into place, and its missing `-f` file
  made, on a dedicated serial store queue (`DCTAnimationCacheImpl.storeQueue`; then reported from the
  cache queue), while the item context stays registered. Not on its fetch queue, where it waited
  behind every conversion queued meanwhile (a new reaction icon or emoji stayed empty for seconds),
  and not on the cache queue, whose hits must not wait for file work (`DCTAnimationCacheStoreQueueTests`).
- **Reaction hand-off**: a reaction sent from the picker lands in the message's button as the
  picker's node, which stays until the button's `InlineStickerItemLayer` has drawn a frame
  (`hasDisplayedContent`; the silhouette placeholder does not count), with no timeout: a timeout
  could only reveal an empty layer, and a button reset removes the stand-in while a switch to another
  reaction hands off at once (`ReactionIconContentGate`, `ReactionButtonListComponentTests`). When the reaction's effect file
  is not downloaded the hand-off is immediate (`reactionSwitchesToInlineImmediately`,
  `ReactionSelectionNodeTests`) and one log line says so; upstream already prefetches every
  available reaction's effects, so do not add another prefetch.
- **Voice recorder input** (`submodules/VoiceRecorderInput`, C): RemoteIO's input callback is
  `VoiceRecorderInputRenderCallback` with the `VoiceRecorderInput` as refCon; nothing Swift runs on
  the IO thread. `ManagedAudioRecorderContext` sets the unit after `AudioUnitInitialize`, clears it
  right after `AudioOutputUnitStop` and before disposing, destroys the input only in deinit (after
  `stop()`), and drains whole 20 ms packets on a 1/40 s timer and once in `stop()`. The recording
  state goes out at most every 1/30 s (`VoiceRecordingStateThrottle`, TelegramAudio); with the
  1/40 s drain that is every other tick, so the time label updates at ~20 Hz (it was ~47 Hz). Tests:
  `//submodules/VoiceRecorderInput:VoiceRecorderInputTests` (Opus output identical to the old
  packetizer for a synthetic producer).
- **Voice message progress on a first play.** `MediaPlayer` reports `.playing` before the audio
  renderer's clock runs (audio session still activating, `reportRate` 0) with the position frozen;
  such a status carries `generationTimestamp` 0 (`mediaPlayerStatusGenerationTimestamp`), which every
  consumer reads as "show the timestamp, do not extrapolate". Stamped with `now` (upstream), the
  waveform ran ahead of the silent player and drew itself fully played. An unlistened incoming voice
  message passes its highlight as `AudioWaveformComponent.unplayedColor`, which the waveform drops as
  soon as it sees its message play (`AudioWaveformUnplayedHighlight`); the bubble otherwise keeps the
  all-active waveform, hiding the progress, until it lays out again after the message is marked
  listened. A generation of 0 is also what the loop at the end reports. **No consumer may count ahead
  from a 0 generation**: the view-once voice ring (`SemanticStatusNodeSecretTimeoutContext`) did, and
  drew itself used up (device uptime ahead) on every first play and resume. Tests:
  `UniversalMediaPlayerTests` (`MediaPlayerStatusGenerationTests`),
  `//submodules/TelegramUI/Components/AudioWaveformComponent:AudioWaveformComponentTests`,
  `//submodules/SemanticStatusNode:SemanticStatusNodeTests`.
