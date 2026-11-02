#ifndef VoiceRecorderInput_h
#define VoiceRecorderInput_h

#include <stdbool.h>
#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

// The voice recorder's RemoteIO input, made safe for the real-time IO thread: the render callback
// takes no lock, allocates nothing and does not dispatch. It renders into a preallocated buffer and
// appends the samples to a single-producer, single-consumer ring; the recorder queue drains the ring
// on a timer. All memory is allocated by VoiceRecorderInputCreate.
typedef struct VoiceRecorderInput VoiceRecorderInput;

// `capacityBytes` is rounded up to a power of two. `maxFramesPerRender` bounds one IO cycle; a larger
// cycle is dropped (and counted) rather than rendered.
VoiceRecorderInput * _Nullable VoiceRecorderInputCreate(uint32_t capacityBytes, uint32_t maxFramesPerRender);
// Only after the audio unit that calls the callback has been stopped (or never started).
void VoiceRecorderInputDestroy(VoiceRecorderInput * _Nullable input);

// The unit the callback renders from. Set it after AudioUnitInitialize; clear it after
// AudioOutputUnitStop and before the unit is disposed.
void VoiceRecorderInputSetAudioUnit(VoiceRecorderInput * _Nonnull input, AudioUnit _Nullable audioUnit);

// The kAudioOutputUnitProperty_SetInputCallback callback; its refCon is the VoiceRecorderInput.
// Renders 16-bit mono samples, `inNumberFrames * 2` bytes per cycle.
OSStatus VoiceRecorderInputRenderCallback(void * _Nonnull inRefCon, AudioUnitRenderActionFlags * _Nonnull ioActionFlags, const AudioTimeStamp * _Nonnull inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList * _Nullable ioData);

// Producer side, used by the callback (and by tests as a synthetic producer). Appends all of
// `length` bytes, or nothing when they do not fit (the bytes are then counted as dropped).
bool VoiceRecorderInputWrite(VoiceRecorderInput * _Nonnull input, const void * _Nonnull bytes, uint32_t length);

// Consumer side, on one queue. Copies exactly `length` bytes when at least that many are buffered.
bool VoiceRecorderInputReadExactly(VoiceRecorderInput * _Nonnull input, void * _Nonnull bytes, uint32_t length);
uint32_t VoiceRecorderInputAvailableBytes(VoiceRecorderInput * _Nonnull input);
// Drops everything buffered so far.
void VoiceRecorderInputDiscardAll(VoiceRecorderInput * _Nonnull input);

// Counters the callback cannot log itself; the consumer reads and logs them.
uint32_t VoiceRecorderInputRenderErrorCount(VoiceRecorderInput * _Nonnull input);
OSStatus VoiceRecorderInputLastRenderError(VoiceRecorderInput * _Nonnull input);
uint32_t VoiceRecorderInputDroppedBytes(VoiceRecorderInput * _Nonnull input);

#ifdef __cplusplus
}
#endif

#endif
