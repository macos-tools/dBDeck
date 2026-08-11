#include "AudioDSP.h"

#include <math.h>
#include <stdio.h>

static int nearlyEqual(Float32 lhs, Float32 rhs) {
    return fabsf(lhs - rhs) < 0.0001f;
}

int main(void) {
    Float32 inputSamples[] = {1.0f, -0.5f, 0.25f, -1.0f};
    Float32 outputSamples[] = {9.0f, 9.0f, 9.0f, 9.0f};
    AudioBufferList input = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 2,
            .mDataByteSize = sizeof(inputSamples),
            .mData = inputSamples
        }}
    };
    AudioBufferList output = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 2,
            .mDataByteSize = sizeof(outputSamples),
            .mData = outputSamples
        }}
    };
    AudioTimeStamp timestamp = {0};
    void *context = DBDGainContextCreate(0.5f);
    if (context == NULL) {
        fprintf(stderr, "Could not create gain context\n");
        return 1;
    }

    DBDGainAudioIOProc(0, &timestamp, &input, &timestamp, &output, &timestamp, context);
    if (!nearlyEqual(outputSamples[0], 0.5f) ||
        !nearlyEqual(outputSamples[1], -0.25f) ||
        !nearlyEqual(outputSamples[2], 0.125f) ||
        !nearlyEqual(outputSamples[3], -0.5f)) {
        fprintf(stderr, "Gain processing produced unexpected samples\n");
        DBDGainContextDestroy(context);
        return 1;
    }

    DBDGainContextSetGain(context, 0.0f);
    DBDGainAudioIOProc(0, &timestamp, &input, &timestamp, &output, &timestamp, context);
    for (size_t index = 0; index < 4; ++index) {
        if (!nearlyEqual(outputSamples[index], 0.0f)) {
            fprintf(stderr, "Mute processing did not produce silence\n");
            DBDGainContextDestroy(context);
            return 1;
        }
    }

    DBDGainContextDestroy(context);
    puts("AudioDSP gain and mute verification passed");
    return 0;
}
