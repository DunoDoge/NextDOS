// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: internal declarations shared across the OHOS embed layer.

#pragma once

#include <cstdint>
#include <vector>

// Frame snapshot accessor implemented by the render backend.
bool video_snapshot(uint8_t* dst, int dst_capacity, int* width_out,
                    int* height_out, uint32_t* seq_out);
