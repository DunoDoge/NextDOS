// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: RenderBackend implementation for HarmonyOS.
//
// Frames are published as immutable pooled buffers with a monotonically
// increasing sequence number; the ArkTS side pulls them via the NAPI
// getFrame() call (pixel format XRGB8888 in host byte order, i.e. B,G,R,A
// bytes on little-endian, matching PixelMap BGRA_8888). The publisher fills
// a buffer no consumer references and swaps it in under a mutex held only
// for the pointer exchange, so publishing and consuming never hold one lock
// across a full-frame copy (see FrameData below).

#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "gui/render/render_backend.h"

class OhosRenderBackend final : public RenderBackend {
public:
	// Fixed upper bound for the render target (covers VESA 1280x1024 with
	// headroom). DOS-side output is typically 320x200..800x600.
	static constexpr int MaxWidth  = 1600;
	static constexpr int MaxHeight = 1200;

	OhosRenderBackend();
	~OhosRenderBackend() override;

	SDL_Window* GetWindow() override;

	DosBox::Rect GetCanvasSizeInPixels() override;
	void NotifyViewportSizeChanged(const DosBox::Rect draw_rect_px) override;
	void NotifyRenderSizeChanged(int new_render_width_px,
	                             int new_render_height_px) override;
	void NotifyVideoModeChanged(const VideoMode& video_mode) override;

	SetShaderResult SetShader(
	        const std::string& symbolic_shader_descriptor) override;
	void ForceReloadCurrentShader() override;
	ShaderInfo GetCurrentShaderInfo() override;
	ShaderPreset GetCurrentShaderPreset() override;
	std::string GetCurrentSymbolicShaderDescriptor() override;
	ShaderDescriptor GetCurrentShaderDescriptor() override;

	void StartFrame(uint32_t*& pixels_out, int& pitch_out) override;
	void EndFrame() override;
	void PrepareFrame() override;
	void PresentFrame() override;

	void SetVsync(bool is_enabled) override;
	void SetColorSpace(ColorSpace color_space) override;
	void EnableImageAdjustments(bool enable) override;
	void SetImageAdjustmentSettings(const ImageAdjustmentSettings& settings) override;
	void SetDeditheringStrength(float strength) override;

	RenderedImage ReadPixelsPostShader(const DosBox::Rect output_rect_px) override;

	uint32_t MakePixel(uint8_t red, uint8_t green, uint8_t blue) override;

	// Frame snapshot consumed by getFrame(); called from the NAPI thread.
	// Copies the latest published frame into `dst` (BGRA, row-major,
	// stride == width*4). The published shared_ptr is taken under a mutex
	// held only for the reference copy — the memcpy itself runs lock-free
	// against a buffer the engine cannot touch. Returns false when nothing
	// has been published yet or the buffer is too small.
	static bool GetFrameSnapshot(uint8_t* dst, int dst_capacity,
	                             int& width_out, int& height_out,
	                             uint32_t& seq_out);

	// Size and seq of the latest published frame without copying pixels;
	// lets the NAPI layer size its reusable frame buffer before fetching.
	static bool GetFrameInfo(int& width_out, int& height_out,
	                         uint32_t& seq_out);

	// Sequence number of the latest published frame (0 = nothing yet).
	// Zero-copy relaxed atomic read for the ArkTS frame loop: getFrame()
	// moves a full megabyte-class buffer through a memcpy on the UI thread,
	// so a static guest screen must not pay that on every 16 ms tick.
	static uint32_t GetFrameSeq();

	// --- consumer-side canvas info (set from the NAPI thread) ---
	static void SetHostCanvasSize(int width, int height);

private:
	// One immutable published frame. PublishFrame fills a pooled buffer no
	// consumer references, then swaps it into published_ under a mutex held
	// only for the pointer exchange; consumers (NAPI thread) copy the
	// shared_ptr and read the pixels without contending the publisher.
	struct FrameData {
		std::vector<uint8_t> pixels;
		int width    = 0;
		int height   = 0;
		uint32_t seq = 0;
	};

	// Upper bound on parked frame buffers: the published slot, one being
	// filled, one held by an in-flight consumer, plus slack. Beyond the cap
	// a retired buffer is really freed.
	static constexpr size_t FramePoolMax = 4;

	// shared_ptr deleter that parks a retired buffer back in the pool.
	static void recycle_frame(FrameData* frame);
	static std::shared_ptr<FrameData> acquire_frame();

	void PublishFrame();

	SDL_Window* window_ = nullptr;

	std::vector<uint32_t> render_buffer_  = {};
	int render_width_   = 0;
	int render_height_  = 0;
	bool frame_pending_ = false;

	static std::mutex published_mutex_;
	static std::shared_ptr<const FrameData> published_;
	// Latest published seq, mirrored for the lock-free GetFrameSeq poll
	// (relaxed: the data path goes through published_, never this counter).
	static std::atomic<uint32_t> snapshot_seq_;
	static std::mutex pool_mutex_;
	static std::vector<std::shared_ptr<FrameData>> frame_pool_;
	// std::atomic: written from the NAPI thread (SetHostCanvasSize) while
	// the engine thread reads them in GetCanvasSizeInPixels(); no mutex
	// may be taken on that hot read path.
	static std::atomic<int> host_canvas_width_;
	static std::atomic<int> host_canvas_height_;
};
