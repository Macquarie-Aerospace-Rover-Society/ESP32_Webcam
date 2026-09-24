#pragma once
// Streaming API of the bundled UVC driver (uvc_driver.c)

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool uvc_video_n_streaming(uint_fast8_t ctl_idx, uint_fast8_t stm_idx);
bool uvc_video_n_frame_xfer(uint_fast8_t ctl_idx, uint_fast8_t stm_idx, void *buffer, size_t bufsize);

#ifdef __cplusplus
}
#endif
