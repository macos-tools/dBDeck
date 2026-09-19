#ifndef DBDECK_AUDIO_DSP_H
#define DBDECK_AUDIO_DSP_H

#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Realtime gain stage for a per-application audio route.
 *
 * The context holds one atomic gain value. The UI thread stores into it while
 * the audio thread loads from it every cycle, so changing a volume never
 * allocates, locks or blocks the realtime callback.
 *
 * Gain runs from 0 (silent) to 2 (+6 dB). Above unity the output is soft-limited
 * towards full scale instead of clipping, so boosting a quiet app stays clean.
 */

/* Returns NULL if the context cannot be allocated. */
void * _Nullable DBDGainContextCreate(Float32 initialGain);
void DBDGainContextDestroy(void * _Nullable context);
void DBDGainContextSetGain(void * _Nullable context, Float32 gain);

/*
 * AudioDeviceIOProc for the aggregate device. Reads `inClientData` as a context
 * from DBDGainContextCreate, scales the tapped input into the device output, and
 * silences any output buffer it has no input for.
 */
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
