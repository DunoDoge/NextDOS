/*
 * audio_output.cpp
 *
 * PC speaker output via OHAudio NDK (OH_AudioRenderer). The emulated speaker
 * is a PIT channel-2 square wave; the renderer callback pulls samples from
 * host_speaker_sample() and feeds a 44.1kHz mono S16LE stream.
 */
#include "host_interface.h"

#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>

#include <atomic>

#define SAMPLE_RATE 44100
#define AMPLITUDE 12000

static OH_AudioRenderer *g_renderer = nullptr;
static std::atomic<bool> g_started(false);

static OH_AudioData_Callback_Result onWriteData(OH_AudioRenderer *renderer,
                                                void *userData,
                                                void *audioData,
                                                int32_t audioDataSize)
{
    (void)renderer;
    (void)userData;
    int16_t *out = (int16_t *)audioData;
    int sampleCount = audioDataSize / (int32_t)sizeof(int16_t);
    for (int i = 0; i < sampleCount; i++) {
        int s = host_speaker_sample();
        out[i] = (int16_t)(s * AMPLITUDE);
    }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

extern "C" int audio_start(void)
{
    if (g_started.load(std::memory_order_acquire))
        return 0;

    OH_AudioStreamBuilder *builder = nullptr;
    OH_AudioStream_Result ret = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
    if (ret != AUDIOSTREAM_SUCCESS || builder == nullptr)
        return -1;

    OH_AudioStreamBuilder_SetSamplingRate(builder, SAMPLE_RATE);
    OH_AudioStreamBuilder_SetChannelCount(builder, 1);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_GAME);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, onWriteData, nullptr);

    ret = OH_AudioStreamBuilder_GenerateRenderer(builder, &g_renderer);
    OH_AudioStreamBuilder_Destroy(builder);
    if (ret != AUDIOSTREAM_SUCCESS || g_renderer == nullptr) {
        g_renderer = nullptr;
        return -1;
    }

    ret = OH_AudioRenderer_Start(g_renderer);
    if (ret != AUDIOSTREAM_SUCCESS) {
        OH_AudioRenderer_Release(g_renderer);
        g_renderer = nullptr;
        return -1;
    }

    g_started.store(true, std::memory_order_release);
    return 0;
}

extern "C" void audio_stop(void)
{
    if (!g_started.load(std::memory_order_acquire))
        return;
    if (g_renderer != nullptr) {
        OH_AudioRenderer_Stop(g_renderer);
        OH_AudioRenderer_Release(g_renderer);
        g_renderer = nullptr;
    }
    g_started.store(false, std::memory_order_release);
}
