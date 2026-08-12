#include "AudioDSP.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    _Atomic(Float32) gain;
} DBDGainContext;

static Float32 DBDClampGain(Float32 gain) {
    if (gain < 0.0f) {
        return 0.0f;
    }
    if (gain > 2.0f) {
        return 2.0f;
    }
    return gain;
}

static Float32 DBDSoftLimit(Float32 sample) {
    const Float32 threshold = 0.95f;
    const Float32 magnitude = sample < 0.0f ? -sample : sample;
    if (magnitude <= threshold) {
        return sample;
    }

    const Float32 headroom = 1.0f - threshold;
    const Float32 excess = (magnitude - threshold) / headroom;
    const Float32 limitedMagnitude = threshold
        + headroom * excess / (1.0f + excess);
    return sample < 0.0f ? -limitedMagnitude : limitedMagnitude;
}

void *DBDGainContextCreate(Float32 initialGain) {
    DBDGainContext *context = calloc(1, sizeof(DBDGainContext));
    if (context != NULL) {
        atomic_init(&context->gain, DBDClampGain(initialGain));
    }
    return context;
}

void DBDGainContextDestroy(void *rawContext) {
    free(rawContext);
}

void DBDGainContextSetGain(void *rawContext, Float32 gain) {
    if (rawContext == NULL) {
        return;
    }
    DBDGainContext *context = rawContext;
    atomic_store_explicit(&context->gain, DBDClampGain(gain), memory_order_relaxed);
}

OSStatus DBDGainAudioIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)inOutputTime;

    if (outOutputData == NULL) {
        return noErr;
    }

    for (UInt32 index = 0; index < outOutputData->mNumberBuffers; ++index) {
        AudioBuffer *output = &outOutputData->mBuffers[index];
        if (output->mData != NULL) {
            memset(output->mData, 0, output->mDataByteSize);
        }
    }

    if (inInputData == NULL || inClientData == NULL) {
        return noErr;
    }

    DBDGainContext *context = inClientData;
    const Float32 gain = atomic_load_explicit(&context->gain, memory_order_relaxed);
    const UInt32 bufferCount = inInputData->mNumberBuffers < outOutputData->mNumberBuffers
        ? inInputData->mNumberBuffers
        : outOutputData->mNumberBuffers;

    for (UInt32 index = 0; index < bufferCount; ++index) {
        const AudioBuffer *input = &inInputData->mBuffers[index];
        AudioBuffer *output = &outOutputData->mBuffers[index];
        if (input->mData == NULL || output->mData == NULL) {
            continue;
        }

        const UInt32 byteCount = input->mDataByteSize < output->mDataByteSize
            ? input->mDataByteSize
            : output->mDataByteSize;
        const size_t sampleCount = byteCount / sizeof(Float32);
        const Float32 *source = input->mData;
        Float32 *destination = output->mData;

        for (size_t sample = 0; sample < sampleCount; ++sample) {
            const Float32 amplified = source[sample] * gain;
            destination[sample] = gain > 1.0f
                ? DBDSoftLimit(amplified)
                : amplified;
        }
    }

    return noErr;
}
