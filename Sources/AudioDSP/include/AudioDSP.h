#ifndef DBDECK_AUDIO_DSP_H
#define DBDECK_AUDIO_DSP_H

#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

void * _Nullable DBDGainContextCreate(Float32 initialGain);
void DBDGainContextDestroy(void * _Nullable context);
void DBDGainContextSetGain(void * _Nullable context, Float32 gain);

OSStatus DBDGainAudioIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);

#ifdef __cplusplus
}
#endif

#endif
