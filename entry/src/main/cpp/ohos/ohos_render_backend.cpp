// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: RenderBackend implementation for HarmonyOS.

#include "ohos_render_backend.h"

#include <cstring>

#include "dosbox.h"
#include "misc/logging.h"
#include "misc/rendered_image.h"
#include "misc/video.h"
#include "gui/render/private/shader_common.h"
#include "utils/math_utils.h"
#include "utils/rect.h"

std::mutex OhosRenderBackend::snapshot_mutex_          = {};
std::vector<uint8_t> OhosRenderBackend::snapshot_      = {};
int OhosRenderBackend::snapshot_width_                 = 0;
int OhosRenderBackend::snapshot_height_                = 0;
uint32_t OhosRenderBackend::snapshot_seq_              = 0;
int OhosRenderBackend::host_canvas_width_              = 1600;
int OhosRenderBackend::host_canvas_height_             = 1200;

OhosRenderBackend::OhosRenderBackend()
{
	render_buffer_.resize(static_cast<size_t>(MaxWidth) * MaxHeight);
}

OhosRenderBackend::~OhosRenderBackend()
{
	if (window_) {
		SDL_DestroyWindow(window_);
		window_ = nullptr;
	}
}

void OhosRenderBackend::SetHostCanvasSize(int width, int height)
{
	std::lock_guard<std::mutex> lock(snapshot_mutex_);
	if (width > 0) {
		host_canvas_width_ = width;
	}
	if (height > 0) {
		host_canvas_height_ = height;
	}
}

SDL_Window* OhosRenderBackend::GetWindow()
{
	return window_;
}

DosBox::Rect OhosRenderBackend::GetCanvasSizeInPixels()
{
	std::lock_guard<std::mutex> lock(snapshot_mutex_);
	return {0, 0, host_canvas_width_, host_canvas_height_};
}

void OhosRenderBackend::NotifyViewportSizeChanged(
        [[maybe_unused]] const DosBox::Rect draw_rect_px)
{
	// The ArkTS layer does its own aspect-fit centering.
}

void OhosRenderBackend::NotifyRenderSizeChanged(const int new_render_width_px,
                                                const int new_render_height_px)
{
	if (new_render_width_px > MaxWidth || new_render_height_px > MaxHeight) {
		LOG_WARNING("DISPLAY: render size %dx%d exceeds the %dx%d host limit",
		            new_render_width_px,
		            new_render_height_px,
		            MaxWidth,
		            MaxHeight);
	}
	render_width_  = std::min(new_render_width_px, MaxWidth);
	render_height_ = std::min(new_render_height_px, MaxHeight);
}

void OhosRenderBackend::NotifyVideoModeChanged(
        [[maybe_unused]] const VideoMode& video_mode) {}

RenderBackend::SetShaderResult OhosRenderBackend::SetShader(
        [[maybe_unused]] const std::string& symbolic_shader_descriptor)
{
	// No shader support; report success so the render pipeline keeps using
	// the default (shader-less) path.
	return SetShaderResult::Ok;
}

void OhosRenderBackend::ForceReloadCurrentShader() {}

ShaderInfo OhosRenderBackend::GetCurrentShaderInfo()
{
	// Sizes for a shader-less pipeline; render.cpp uses these for
	// integer-scaling decisions.
	ShaderInfo info = {};
	info.name = "none";
	info.output_size = ShaderOutputSize::Previous;
	return info;
}

ShaderPreset OhosRenderBackend::GetCurrentShaderPreset()
{
	ShaderPreset preset = {};
	return preset;
}

std::string OhosRenderBackend::GetCurrentSymbolicShaderDescriptor()
{
	return "none";
}

ShaderDescriptor OhosRenderBackend::GetCurrentShaderDescriptor()
{
	ShaderDescriptor descriptor = {};
	return descriptor;
}

void OhosRenderBackend::StartFrame(uint32_t*& pixels_out, int& pitch_out)
{
	pixels_out = render_buffer_.data();
	pitch_out  = MaxWidth * static_cast<int>(sizeof(uint32_t));
}

void OhosRenderBackend::EndFrame()
{
	frame_pending_ = true;
}

void OhosRenderBackend::PublishFrame()
{
	std::lock_guard<std::mutex> lock(snapshot_mutex_);

	const size_t row_bytes = static_cast<size_t>(render_width_) *
	                         sizeof(uint32_t);
	snapshot_.resize(row_bytes * render_height_);

	// The engine leaves the alpha byte at 0 for text-mode background pixels;
	// force full opacity so the ArkTS Canvas doesn't treat them as
	// transparent (drawImage would show the black canvas underneath).
	for (int y = 0; y < render_height_; ++y) {
		auto* dst = reinterpret_cast<uint32_t*>(snapshot_.data() +
		                                        row_bytes * y);
		const auto* src_row = render_buffer_.data() +
		                      static_cast<size_t>(MaxWidth) * y;
		for (int x = 0; x < render_width_; ++x) {
			dst[x] = src_row[x] | 0xFF000000u;
		}
	}
	snapshot_width_  = render_width_;
	snapshot_height_ = render_height_;
	++snapshot_seq_;
}

void OhosRenderBackend::PrepareFrame()
{
	if (!frame_pending_) {
		return;
	}
	frame_pending_ = false;
	PublishFrame();
}

void OhosRenderBackend::PresentFrame() {}

void OhosRenderBackend::SetVsync([[maybe_unused]] bool is_enabled) {}

void OhosRenderBackend::SetColorSpace(
        [[maybe_unused]] ColorSpace color_space) {}

void OhosRenderBackend::EnableImageAdjustments(
        [[maybe_unused]] bool enable) {}

void OhosRenderBackend::SetImageAdjustmentSettings(
        [[maybe_unused]] const ImageAdjustmentSettings& settings) {}

void OhosRenderBackend::SetDeditheringStrength(
        [[maybe_unused]] float strength) {}

RenderedImage OhosRenderBackend::ReadPixelsPostShader(
        const DosBox::Rect output_rect_px)
{
	// Same contract as the SDL texture backend: the caller owns the
	// returned buffer (BGR24 byte array, tightly packed).
	RenderedImage image = {};

	image.params.width              = iroundf(output_rect_px.w);
	image.params.height             = iroundf(output_rect_px.h);
	image.params.double_width       = false;
	image.params.double_height      = false;
	image.params.pixel_aspect_ratio = {1};
	image.params.pixel_format       = PixelFormat::BGR24_ByteArray;

	image.pitch = image.params.width * 3;

	const auto image_size_bytes = static_cast<uint32_t>(image.params.height *
	                                                    image.pitch);
	image.image_data            = new uint8_t[image_size_bytes];
	image.is_flipped_vertically = false;

	std::lock_guard<std::mutex> lock(snapshot_mutex_);

	for (int y = 0; y < image.params.height; ++y) {
		const int src_y = output_rect_px.y + y;
		if (src_y < 0 || src_y >= snapshot_height_) {
			continue;
		}
		auto* dst_row = image.image_data + static_cast<size_t>(y) *
		                                        image.pitch;
		for (int x = 0; x < image.params.width; ++x) {
			const int src_x = output_rect_px.x + x;
			if (src_x < 0 || src_x >= snapshot_width_) {
				continue;
			}
			uint32_t pixel = 0;
			memcpy(&pixel,
			       snapshot_.data() +
			               (static_cast<size_t>(src_y) *
			                snapshot_width_ + src_x) *
			                       sizeof(uint32_t),
			       sizeof(pixel));
			// XRGB8888 -> B,G,R bytes
			dst_row[static_cast<size_t>(x) * 3 + 0] =
			        static_cast<uint8_t>(pixel & 0xffu);
			dst_row[static_cast<size_t>(x) * 3 + 1] =
			        static_cast<uint8_t>((pixel >> 8) & 0xffu);
			dst_row[static_cast<size_t>(x) * 3 + 2] =
			        static_cast<uint8_t>((pixel >> 16) & 0xffu);
		}
	}
	return image;
}

uint32_t OhosRenderBackend::MakePixel(uint8_t red, uint8_t green, uint8_t blue)
{
	// XRGB8888 like the SDL texture backend; little-endian memory layout
	// is B,G,R,A which matches ArkUI PixelMap BGRA_8888.
	return (static_cast<uint32_t>(blue) << 0) |
	       (static_cast<uint32_t>(green) << 8) |
	       (static_cast<uint32_t>(red) << 16) | (255u << 24);
}

bool OhosRenderBackend::GetFrameSnapshot(uint8_t* dst, int dst_capacity,
                                         int& width_out, int& height_out,
                                         uint32_t& seq_out)
{
	std::lock_guard<std::mutex> lock(snapshot_mutex_);
	if (snapshot_seq_ == 0 || snapshot_.empty()) {
		return false;
	}
	if (static_cast<size_t>(dst_capacity) < snapshot_.size()) {
		return false;
	}
	memcpy(dst, snapshot_.data(), snapshot_.size());
	seq_out    = snapshot_seq_;
	width_out  = snapshot_width_;
	height_out = snapshot_height_;
	return true;
}
