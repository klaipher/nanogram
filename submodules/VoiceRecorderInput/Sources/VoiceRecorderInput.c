#include <VoiceRecorderInput/VoiceRecorderInput.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Free-running 32-bit indices: `writeIndex - readIndex` is the fill level (wrap-around is fine as
// long as the capacity is a power of two below 2^31). Only the IO thread moves `writeIndex` and
// only the consumer moves `readIndex`; release/acquire on them publishes the bytes in between.
struct VoiceRecorderInput {
    _Atomic(AudioUnit) audioUnit;
    uint8_t *ring;
    uint32_t capacity;
    uint8_t *renderBuffer;
    uint32_t maxFramesPerRender;
    _Atomic uint32_t writeIndex;
    _Atomic uint32_t readIndex;
    _Atomic uint32_t renderErrorCount;
    _Atomic int32_t lastRenderError;
    _Atomic uint32_t droppedBytes;
};

VoiceRecorderInput *VoiceRecorderInputCreate(uint32_t capacityBytes, uint32_t maxFramesPerRender) {
    if (capacityBytes == 0 || capacityBytes > (1u << 30) || maxFramesPerRender == 0 || maxFramesPerRender > (1u << 20)) {
        return NULL;
    }
    uint32_t capacity = 1;
    while (capacity < capacityBytes) {
        capacity <<= 1;
    }
    VoiceRecorderInput *input = calloc(1, sizeof(VoiceRecorderInput));
    if (input == NULL) {
        return NULL;
    }
    input->ring = malloc(capacity);
    input->renderBuffer = malloc((size_t)maxFramesPerRender * 2);
    if (input->ring == NULL || input->renderBuffer == NULL) {
        free(input->ring);
        free(input->renderBuffer);
        free(input);
        return NULL;
    }
    input->capacity = capacity;
    input->maxFramesPerRender = maxFramesPerRender;
    atomic_init(&input->audioUnit, NULL);
    atomic_init(&input->writeIndex, 0);
    atomic_init(&input->readIndex, 0);
    atomic_init(&input->renderErrorCount, 0);
    atomic_init(&input->lastRenderError, 0);
    atomic_init(&input->droppedBytes, 0);
    return input;
}

void VoiceRecorderInputDestroy(VoiceRecorderInput *input) {
    if (input == NULL) {
        return;
    }
    free(input->ring);
    free(input->renderBuffer);
    free(input);
}

void VoiceRecorderInputSetAudioUnit(VoiceRecorderInput *input, AudioUnit audioUnit) {
    atomic_store_explicit(&input->audioUnit, audioUnit, memory_order_release);
}

bool VoiceRecorderInputWrite(VoiceRecorderInput *input, const void *bytes, uint32_t length) {
    uint32_t writeIndex = atomic_load_explicit(&input->writeIndex, memory_order_relaxed);
    uint32_t readIndex = atomic_load_explicit(&input->readIndex, memory_order_acquire);
    uint32_t used = writeIndex - readIndex;
    if (length > input->capacity - used) {
        atomic_fetch_add_explicit(&input->droppedBytes, length, memory_order_relaxed);
        return false;
    }
    uint32_t offset = writeIndex & (input->capacity - 1);
    uint32_t first = input->capacity - offset;
    if (first > length) {
        first = length;
    }
    memcpy(input->ring + offset, bytes, first);
    if (first < length) {
        memcpy(input->ring, (const uint8_t *)bytes + first, length - first);
    }
    atomic_store_explicit(&input->writeIndex, writeIndex + length, memory_order_release);
    return true;
}

bool VoiceRecorderInputReadExactly(VoiceRecorderInput *input, void *bytes, uint32_t length) {
    uint32_t readIndex = atomic_load_explicit(&input->readIndex, memory_order_relaxed);
    uint32_t writeIndex = atomic_load_explicit(&input->writeIndex, memory_order_acquire);
    if (writeIndex - readIndex < length) {
        return false;
    }
    uint32_t offset = readIndex & (input->capacity - 1);
    uint32_t first = input->capacity - offset;
    if (first > length) {
        first = length;
    }
    memcpy(bytes, input->ring + offset, first);
    if (first < length) {
        memcpy((uint8_t *)bytes + first, input->ring, length - first);
    }
    atomic_store_explicit(&input->readIndex, readIndex + length, memory_order_release);
    return true;
}

uint32_t VoiceRecorderInputAvailableBytes(VoiceRecorderInput *input) {
    uint32_t readIndex = atomic_load_explicit(&input->readIndex, memory_order_relaxed);
    uint32_t writeIndex = atomic_load_explicit(&input->writeIndex, memory_order_acquire);
    return writeIndex - readIndex;
}

void VoiceRecorderInputDiscardAll(VoiceRecorderInput *input) {
    uint32_t writeIndex = atomic_load_explicit(&input->writeIndex, memory_order_acquire);
    atomic_store_explicit(&input->readIndex, writeIndex, memory_order_release);
}

OSStatus VoiceRecorderInputRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    (void)ioData;
    VoiceRecorderInput *input = (VoiceRecorderInput *)inRefCon;
    AudioUnit audioUnit = atomic_load_explicit(&input->audioUnit, memory_order_acquire);
    if (audioUnit == NULL) {
        return noErr;
    }
    if (inNumberFrames > input->maxFramesPerRender) {
        atomic_fetch_add_explicit(&input->droppedBytes, inNumberFrames * 2, memory_order_relaxed);
        return noErr;
    }
    uint32_t length = inNumberFrames * 2;
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = 1;
    bufferList.mBuffers[0].mDataByteSize = length;
    bufferList.mBuffers[0].mData = input->renderBuffer;
    OSStatus status = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList);
    if (status != noErr) {
        atomic_store_explicit(&input->lastRenderError, status, memory_order_relaxed);
        atomic_fetch_add_explicit(&input->renderErrorCount, 1, memory_order_relaxed);
        return noErr;
    }
    // The recorder always took `inNumberFrames * 2` bytes per cycle.
    VoiceRecorderInputWrite(input, input->renderBuffer, length);
    return noErr;
}

uint32_t VoiceRecorderInputRenderErrorCount(VoiceRecorderInput *input) {
    return atomic_load_explicit(&input->renderErrorCount, memory_order_relaxed);
}

OSStatus VoiceRecorderInputLastRenderError(VoiceRecorderInput *input) {
    return atomic_load_explicit(&input->lastRenderError, memory_order_relaxed);
}

uint32_t VoiceRecorderInputDroppedBytes(VoiceRecorderInput *input) {
    return atomic_load_explicit(&input->droppedBytes, memory_order_relaxed);
}
