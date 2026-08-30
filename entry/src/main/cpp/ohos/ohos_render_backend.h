// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: RenderBackend implementation for HarmonyOS.
//
// Frames are published into a fixed-size BGRA staging buffer with a
// monotonically increasing sequence number; the ArkTS side pulls them via
// the NAPI getFrame() call (pixel format XRGB8888 in host byte order,
// i.e. B,G,R,A bytes on little-endian, matching PixelMap BGRA_8888).

#pragma once

#include <cstdint>
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
	// stride == width*4). Returns false when nothing has been published
	// yet or the buffer is too small.
	static bool GetFrameSnapshot(uint8_t* dst, int dst_capacity,
	                             int& width_out, int& height_out,
	                             uint32_t& seq_out);

	// --- consumer-side canvas info (set from the NAPI thread) ---
	static void SetHostCanvasSize(int width, int height);

private:
	void PublishFrame();

	SDL_Window* window_ = nullptr;

	std::vector<uint32_t> render_buffer_  = {};
	int render_width_   = 0;
	int render_height_  = 0;
	bool frame_pending_ = false;

	static std::mutex snapshot_mutex_;
	static std::vector<uint8_t> snapshot_;
	static int snapshot_width_;
	static int snapshot_height_;
	static uint32_t snapshot_seq_;
	static int host_canvas_width_;
	static int host_canvas_height_;
};
