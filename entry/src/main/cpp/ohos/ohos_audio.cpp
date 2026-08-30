// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: HarmonyOS audio output for the DOSBox Staging embed build.
//
// Bridges the engine mixer to OHAudio: the device callback pulls already
// mixed stereo F32 frames from the mixer's final_output queue via
// MIXER_OhosDequeueOutput() (see the fork's audio/mixer.cpp embed hook).

#include <atomic>

#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>

#include "audio/mixer.h"

static OH_AudioRenderer* g_renderer = nullptr;
static std::atomic<bool> g_started(false);
static std::atomic<int> g_underruns(0);

static OH_AudioData_Callback_Result onWriteData(OH_AudioRenderer* renderer,
                                                void* userData,
                                                void* audioData,
                                                int32_t audioDataSize)
{
	(void)renderer;
	(void)userData;

	constexpr int BytesPerFrame = 2 * static_cast<int>(sizeof(float));

	if (audioData == nullptr || audioDataSize < BytesPerFrame) {
		return AUDIO_DATA_CALLBACK_RESULT_INVALID;
	}

	const int32_t max_frames = audioDataSize / BytesPerFrame;
	const size_t frames =
	        MIXER_OhosDequeueOutput(static_cast<float*>(audioData),
	                                static_cast<size_t>(max_frames));

	if (frames < static_cast<size_t>(max_frames)) {
		// Underrun (mixer queue dry): the dequeue helper already wrote
		// silence for the shortfall, so the buffer stays valid.
		g_underruns.fetch_add(1, std::memory_order_relaxed);
	}
	return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

bool ohos_audio_start(int sample_rate_hz, int blocksize_in_frames)
{
	(void)blocksize_in_frames;

	if (g_started.load(std::memory_order_acquire)) {
		return true;
	}

	OH_AudioStreamBuilder* builder = nullptr;
	OH_AudioStream_Result ret =
	        OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
	if (ret != AUDIOSTREAM_SUCCESS || builder == nullptr) {
		LOG_ERR("OHOS: Failed to create audio stream builder: %d", ret);
		return false;
	}

	OH_AudioStreamBuilder_SetSamplingRate(builder, sample_rate_hz);
	OH_AudioStreamBuilder_SetChannelCount(builder, 2);
	OH_AudioStreamBuilder_SetSampleFormat(builder,
	                                      AUDIOSTREAM_SAMPLE_F32LE);
	OH_AudioStreamBuilder_SetEncodingType(builder,
	                                      AUDIOSTREAM_ENCODING_TYPE_RAW);
	OH_AudioStreamBuilder_SetLatencyMode(builder,
	                                     AUDIOSTREAM_LATENCY_MODE_NORMAL);
	OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_GAME);
	OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, onWriteData,
	                                                   nullptr);

	ret = OH_AudioStreamBuilder_GenerateRenderer(builder, &g_renderer);
	OH_AudioStreamBuilder_Destroy(builder);
	if (ret != AUDIOSTREAM_SUCCESS || g_renderer == nullptr) {
		LOG_ERR("OHOS: Failed to generate audio renderer: %d", ret);
		g_renderer = nullptr;
		return false;
	}

	ret = OH_AudioRenderer_Start(g_renderer);
	if (ret != AUDIOSTREAM_SUCCESS) {
		LOG_ERR("OHOS: Failed to start audio renderer: %d", ret);
		OH_AudioRenderer_Release(g_renderer);
		g_renderer = nullptr;
		return false;
	}

	g_underruns.store(0, std::memory_order_relaxed);
	g_started.store(true, std::memory_order_release);
	LOG_MSG("OHOS: Audio started (%d Hz stereo F32)", sample_rate_hz);
	return true;
}

void ohos_audio_stop()
{
	if (!g_started.load(std::memory_order_acquire)) {
		return;
	}
	if (g_renderer != nullptr) {
		OH_AudioRenderer_Stop(g_renderer);
		OH_AudioRenderer_Release(g_renderer);
		g_renderer = nullptr;
	}
	g_started.store(false, std::memory_order_release);
}
