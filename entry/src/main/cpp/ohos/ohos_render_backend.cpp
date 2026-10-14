// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: RenderBackend implementation for HarmonyOS.

#include "ohos_render_backend.h"

#include <atomic>
#include <cstring>

#include "dosbox.h"
#include "misc/logging.h"
#include "misc/rendered_image.h"
#include "misc/video.h"
#include "gui/render/private/shader_common.h"
#include "utils/math_utils.h"
#include "utils/rect.h"

std::mutex OhosRenderBackend::published_mutex_ = {};
std::shared_ptr<const OhosRenderBackend::FrameData> OhosRenderBackend::published_ = {};
std::atomic<uint32_t> OhosRenderBackend::snapshot_seq_ = 0;
std::mutex OhosRenderBackend::pool_mutex_ = {};
std::vector<std::shared_ptr<OhosRenderBackend::FrameData>> OhosRenderBackend::frame_pool_ = {};
std::atomic<int> OhosRenderBackend::host_canvas_width_  = 1600;
std::atomic<int> OhosRenderBackend::host_canvas_height_ = 1200;

// shared_ptr deleter: when the published slot and every in-flight consumer
// reference are gone, park the buffer for the next publish instead of
// freeing it — steady-state publishing performs zero allocations.
void OhosRenderBackend::recycle_frame(FrameData* frame)
{
	{
		std::lock_guard<std::mutex> lock(pool_mutex_);
		if (frame_pool_.size() < FramePoolMax) {
			frame_pool_.emplace_back(frame, &OhosRenderBackend::recycle_frame);
			return;
		}
	}
	delete frame;
}

std::shared_ptr<OhosRenderBackend::FrameData> OhosRenderBackend::acquire_frame()
{
	{
		std::lock_guard<std::mutex> lock(pool_mutex_);
		if (!frame_pool_.empty()) {
			std::shared_ptr<FrameData> frame = std::move(frame_pool_.back());
			frame_pool_.pop_back();
			return frame;
		}
	}
	return std::shared_ptr<FrameData>(new FrameData(),
	                                  &OhosRenderBackend::recycle_frame);
}

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
	// Atomics instead of the snapshot mutex: the canvas size is read on
	// the engine thread's viewport hot path, and a w/h pair torn by a
	// concurrent resize is harmless — the canvas-changed update that
	// follows the resize recomputes the draw rect again.
	if (width > 0) {
		host_canvas_width_.store(width, std::memory_order_relaxed);
	}
	if (height > 0) {
		host_canvas_height_.store(height, std::memory_order_relaxed);
	}
}

SDL_Window* OhosRenderBackend::GetWindow()
{
	return window_;
}

DosBox::Rect OhosRenderBackend::GetCanvasSizeInPixels()
{
	return {0, 0, host_canvas_width_.load(std::memory_order_relaxed),
	        host_canvas_height_.load(std::memory_order_relaxed)};
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
	// The buffer comes from the pool (or is fresh when the pool ran dry),
	// so no consumer holds it: the pixel loop runs entirely lock-free.
	std::shared_ptr<FrameData> frame = acquire_frame();

	const size_t row_bytes = static_cast<size_t>(render_width_) *
	                         sizeof(uint32_t);
	frame->pixels.resize(row_bytes * render_height_);

	// The engine leaves the alpha byte at 0 for text-mode background pixels;
	// force full opacity so the ArkTS Canvas doesn't treat them as
	// transparent (drawImage would show the black canvas underneath).
	for (int y = 0; y < render_height_; ++y) {
		auto* dst = reinterpret_cast<uint32_t*>(frame->pixels.data() +
		                                        row_bytes * y);
		const auto* src_row = render_buffer_.data() +
		                      static_cast<size_t>(MaxWidth) * y;
		for (int x = 0; x < render_width_; ++x) {
			dst[x] = src_row[x] | 0xFF000000u;
		}
	}
	frame->width  = render_width_;
	frame->height = render_height_;
	frame->seq    = snapshot_seq_.load(std::memory_order_relaxed) + 1;

	{
		// Held only for the pointer swap: the retired frame stays alive
		// through the shared_ptr and returns to the pool once the last
		// consumer reference drops.
		std::lock_guard<std::mutex> lock(published_mutex_);
		published_ = std::move(frame);
	}
	snapshot_seq_.store(published_->seq, std::memory_order_relaxed);
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
	image.image_data            = new uint8_t[image_size_bytes]();
	image.is_flipped_vertically = false;

	std::shared_ptr<const FrameData> frame;
	{
		std::lock_guard<std::mutex> lock(published_mutex_);
		frame = published_;
	}
	if (!frame) {
		return image;
	}

	for (int y = 0; y < image.params.height; ++y) {
		const int src_y = output_rect_px.y + y;
		if (src_y < 0 || src_y >= frame->height) {
			continue;
		}
		auto* dst_row = image.image_data + static_cast<size_t>(y) *
		                                        image.pitch;
		for (int x = 0; x < image.params.width; ++x) {
			const int src_x = output_rect_px.x + x;
			if (src_x < 0 || src_x >= frame->width) {
				continue;
			}
			uint32_t pixel = 0;
			memcpy(&pixel,
			       frame->pixels.data() +
			               (static_cast<size_t>(src_y) *
			                frame->width + src_x) *
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
	std::shared_ptr<const FrameData> frame;
	{
		// Held only while taking the reference: the memcpy below runs
		// against a buffer the engine cannot touch (it only ever fills
		// buffers the pool owns exclusively).
		std::lock_guard<std::mutex> lock(published_mutex_);
		frame = published_;
	}
	if (!frame || frame->pixels.empty()) {
		return false;
	}
	if (static_cast<size_t>(dst_capacity) < frame->pixels.size()) {
		return false;
	}
	memcpy(dst, frame->pixels.data(), frame->pixels.size());
	seq_out    = frame->seq;
	width_out  = frame->width;
	height_out = frame->height;
	return true;
}

bool OhosRenderBackend::GetFrameInfo(int& width_out, int& height_out,
                                     uint32_t& seq_out)
{
	std::lock_guard<std::mutex> lock(published_mutex_);
	if (!published_ || published_->pixels.empty()) {
		return false;
	}
	width_out  = published_->width;
	height_out = published_->height;
	seq_out    = published_->seq;
	return true;
}

uint32_t OhosRenderBackend::GetFrameSeq()
{
	return snapshot_seq_.load(std::memory_order_relaxed);
}
