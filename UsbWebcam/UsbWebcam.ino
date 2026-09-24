/*
 * ESP32-S3 (N16R8) + OV5640  ->  USB UVC webcam (MJPEG over the native USB-OTG port)
 *
 * Ports on the board:
 *   - "UART" USB-C (CH343 bridge)  : flashing + Serial debug log (115200)
 *   - "OTG"  USB-C (native GPIO19/20): enumerates as a standard UVC webcam
 *
 * Arduino IDE board settings (Tools menu), ESP32 core 3.3.x:
 *   Board            : ESP32S3 Dev Module
 *   USB Mode         : USB-OTG (TinyUSB)
 *   USB CDC On Boot  : Disabled          (Serial -> UART0 -> CH343 port)
 *   Upload Mode      : UART0 / Hardware CDC
 *   Flash Size       : 16MB
 *   Flash Mode       : QIO 80MHz
 *   PSRAM            : OPI PSRAM
 *   Partition Scheme : Huge APP (or any)
 *
 * Streaming uses a full-speed (12 Mbit/s) bulk endpoint. The UVC class driver is a
 * patched copy bundled in uvc_driver.c (the core's prebuilt one caps payloads at 64 B,
 * which limited VGA to ~7 fps). Bandwidth is still full-speed USB, so higher
 * resolutions trade frame rate for size.
 */

#include "Arduino.h"
#include "USB.h"
#include "esp32-hal-tinyusb.h"
#include "esp_camera.h"
#include "uvc_driver.h"
#include "device/usbd_pvt.h"

#if !CONFIG_TINYUSB_VIDEO_ENABLED
#error "TinyUSB video class is not enabled in this core build"
#endif
#if ARDUINO_USB_MODE
#error "Set Tools > USB Mode to 'USB-OTG (TinyUSB)'"
#endif

// ---------------------------------------------------------------------------
// Camera pins (Freenove / ESP32-S3-EYE style layout used by most N16R8 CAM boards)
// ---------------------------------------------------------------------------
#define PWDN_GPIO_NUM  -1
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM  15
#define SIOD_GPIO_NUM  4
#define SIOC_GPIO_NUM  5
#define Y9_GPIO_NUM    16
#define Y8_GPIO_NUM    17
#define Y7_GPIO_NUM    18
#define Y6_GPIO_NUM    12
#define Y5_GPIO_NUM    10
#define Y4_GPIO_NUM    8
#define Y3_GPIO_NUM    9
#define Y2_GPIO_NUM    11
#define VSYNC_GPIO_NUM 6
#define HREF_GPIO_NUM  7
#define PCLK_GPIO_NUM  13

// Image tweaks - flip these if the picture comes out upside down / mirrored.
#define CAM_VFLIP        0
#define CAM_HMIRROR      0
#define CAM_JPEG_QUALITY 12  // 0-63, lower = better quality, bigger frames

// ---------------------------------------------------------------------------
// Advertised video modes (all MJPEG)
// ---------------------------------------------------------------------------
struct VideoMode {
  uint16_t width, height;
  framesize_t framesize;
};

static const VideoMode kModes[] = {
  {320, 240, FRAMESIZE_QVGA},
  {640, 480, FRAMESIZE_VGA},
  {1280, 720, FRAMESIZE_HD},
  {1920, 1080, FRAMESIZE_FHD},
};
static const uint8_t kNumModes = sizeof(kModes) / sizeof(kModes[0]);
static const uint8_t kDefaultMode = 2;  // 1-based frame index -> VGA

// Frame intervals in 100 ns units. Truncated, not rounded: DirectShow computes
// 10^7 / fps with integer division and rejects modes that don't match exactly.
#define FI_30FPS 333333
#define FI_15FPS 666666
#define FI_10FPS 1000000
#define FI_5FPS  2000000

// ---------------------------------------------------------------------------
// UVC descriptor
// ---------------------------------------------------------------------------
#define UVC_ENTITY_CAMERA_TERM 1
#define UVC_ENTITY_OUTPUT_TERM 2
#define UVC_EP_SIZE            64

// MJPEG discrete frame descriptor with 3 intervals, written out explicitly
#define MJPEG_FRAME_LEN (26 + 3 * 4)
#define MJPEG_FRAME(_idx, _w, _h, _fi0, _fi1, _fi2)                                      \
  MJPEG_FRAME_LEN, TUSB_DESC_CS_INTERFACE, VIDEO_CS_ITF_VS_FRAME_MJPEG, _idx, 0,         \
    U16_TO_U8S_LE(_w), U16_TO_U8S_LE(_h),                                                \
    U32_TO_U8S_LE((uint32_t)(_w) * (_h) * 16 * 5),  /* min bit rate */                  \
    U32_TO_U8S_LE((uint32_t)(_w) * (_h) * 16 * 30), /* max bit rate */                  \
    U32_TO_U8S_LE((uint32_t)(_w) * (_h) * 2),       /* max frame buffer */              \
    U32_TO_U8S_LE(_fi0), 3, U32_TO_U8S_LE(_fi0), U32_TO_U8S_LE(_fi1), U32_TO_U8S_LE(_fi2)

#define VC_TERMS_LEN (TUD_VIDEO_DESC_CAMERA_TERM_LEN + TUD_VIDEO_DESC_OUTPUT_TERM_LEN)
#define VS_BODY_LEN \
  (TUD_VIDEO_DESC_CS_VS_FMT_MJPEG_LEN + 4 * MJPEG_FRAME_LEN + TUD_VIDEO_DESC_CS_VS_COLOR_MATCHING_LEN)

#define UVC_DESC_LEN                                                                              \
  (TUD_VIDEO_DESC_IAD_LEN + TUD_VIDEO_DESC_STD_VC_LEN + (TUD_VIDEO_DESC_CS_VC_LEN + 1) + VC_TERMS_LEN \
   + TUD_VIDEO_DESC_STD_VS_LEN + (TUD_VIDEO_DESC_CS_VS_IN_LEN + 1) + VS_BODY_LEN + 7 /* bulk EP */)

static uint16_t uvc_load_descriptor(uint8_t *dst, uint8_t *itf) {
  uint8_t str_index = tinyusb_add_string_descriptor("ESP32-S3 UVC Camera");
  uint8_t ep_in = tinyusb_get_free_in_endpoint();
  TU_VERIFY(ep_in != 0);
  ep_in |= 0x80;
  uint8_t vc_itf = *itf, vs_itf = *itf + 1;

  uint8_t desc[UVC_DESC_LEN] = {
    TUD_VIDEO_DESC_IAD(vc_itf, 2, str_index),

    // Video Control
    TUD_VIDEO_DESC_STD_VC(vc_itf, 0, str_index),
    TUD_VIDEO_DESC_CS_VC(0x0150, VC_TERMS_LEN, 48000000, vs_itf),
    TUD_VIDEO_DESC_CAMERA_TERM(UVC_ENTITY_CAMERA_TERM, 0, 0, 0, 0, 0, 0),
    TUD_VIDEO_DESC_OUTPUT_TERM(UVC_ENTITY_OUTPUT_TERM, VIDEO_TT_STREAMING, 0, UVC_ENTITY_CAMERA_TERM, 0),

    // Video Streaming (bulk: the endpoint lives on alt setting 0)
    TUD_VIDEO_DESC_STD_VS(vs_itf, 0, 1, str_index),
    TUD_VIDEO_DESC_CS_VS_INPUT(1, VS_BODY_LEN, ep_in, 0, UVC_ENTITY_OUTPUT_TERM, 0, 0, 0, 0),
    TUD_VIDEO_DESC_CS_VS_FMT_MJPEG(1, kNumModes, 0, kDefaultMode, 0, 0, 0, 0),
    MJPEG_FRAME(1, 320, 240, FI_30FPS, FI_15FPS, FI_10FPS),
    MJPEG_FRAME(2, 640, 480, FI_30FPS, FI_15FPS, FI_10FPS),
    MJPEG_FRAME(3, 1280, 720, FI_15FPS, FI_10FPS, FI_5FPS),
    MJPEG_FRAME(4, 1920, 1080, FI_15FPS, FI_10FPS, FI_5FPS),
    TUD_VIDEO_DESC_CS_VS_COLOR_MATCHING(VIDEO_COLOR_PRIMARIES_BT709, VIDEO_COLOR_XFER_CH_BT709, VIDEO_COLOR_COEF_SMPTE170M),
    TUD_VIDEO_DESC_EP_BULK(ep_in, UVC_EP_SIZE, 1),
  };
  static_assert(sizeof(kModes) / sizeof(kModes[0]) == 4, "update the MJPEG_FRAME list to match kModes");

  *itf += 2;
  memcpy(dst, desc, sizeof(desc));
  return sizeof(desc);
}

// ---------------------------------------------------------------------------
// UVC callbacks (run in the TinyUSB task)
// ---------------------------------------------------------------------------
static SemaphoreHandle_t xferDone;
static volatile uint8_t requestedMode = kDefaultMode;  // 1-based
static volatile uint32_t requestedInterval = FI_30FPS;
static volatile bool commitPending = false;

extern "C" int tud_video_commit_cb(uint_fast8_t ctl_idx, uint_fast8_t stm_idx, video_probe_and_commit_control_t const *p) {
  (void)ctl_idx;
  (void)stm_idx;
  if (p->bFrameIndex >= 1 && p->bFrameIndex <= kNumModes) {
    requestedMode = p->bFrameIndex;
  }
  if (p->dwFrameInterval) {
    requestedInterval = p->dwFrameInterval;
  }
  commitPending = true;
  return VIDEO_ERROR_NONE;
}

extern "C" void tud_video_frame_xfer_complete_cb(uint_fast8_t ctl_idx, uint_fast8_t stm_idx) {
  (void)ctl_idx;
  (void)stm_idx;
  xSemaphoreGive(xferDone);
}

// Frames are started from the TinyUSB task (via usbd_defer_func) so the first packet
// write never races the USB ISR filling the TX FIFO for the rest of the transfer.
static struct {
  void *buf;
  size_t len;
  volatile bool ok;
} pendingXfer;

static void startFrameXfer(void *) {
  pendingXfer.ok = uvc_video_n_frame_xfer(0, 0, pendingXfer.buf, pendingXfer.len);
  if (!pendingXfer.ok) {
    xSemaphoreGive(xferDone);
  }
}

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------
static bool cameraInit() {
  camera_config_t config = {};
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.ledc_timer = LEDC_TIMER_0;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.pixel_format = PIXFORMAT_JPEG;
  // Init at the largest mode so the JPEG buffers are big enough for every mode.
  config.frame_size = kModes[kNumModes - 1].framesize;
  config.jpeg_quality = CAM_JPEG_QUALITY;
  config.fb_count = 2;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.grab_mode = CAMERA_GRAB_LATEST;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed: 0x%x\n", err);
    return false;
  }

  sensor_t *s = esp_camera_sensor_get();
  Serial.printf("Camera sensor PID: 0x%04x%s\n", s->id.PID, s->id.PID == OV5640_PID ? " (OV5640)" : "");
  s->set_vflip(s, CAM_VFLIP);
  s->set_hmirror(s, CAM_HMIRROR);
  s->set_framesize(s, kModes[kDefaultMode - 1].framesize);
  return true;
}

// ---------------------------------------------------------------------------
// Streaming task
// ---------------------------------------------------------------------------
static void streamTask(void *) {
  uint8_t activeMode = kDefaultMode;
  uint32_t lastFrameUs = 0;
  uint32_t statFrames = 0, statBytes = 0, statStartMs = millis();

  for (;;) {
    if (!uvc_video_n_streaming(0, 0)) {
      vTaskDelay(pdMS_TO_TICKS(10));
      continue;
    }

    if (commitPending) {
      commitPending = false;
      uint8_t mode = requestedMode;
      if (mode != activeMode) {
        esp_camera_sensor_get()->set_framesize(esp_camera_sensor_get(), kModes[mode - 1].framesize);
        activeMode = mode;
      }
      Serial.printf("Host started stream: %ux%u @ %.1f fps\n", kModes[mode - 1].width, kModes[mode - 1].height,
                    10000000.0f / requestedInterval);
    }

    // Pace to the frame interval the host asked for.
    uint32_t intervalUs = requestedInterval / 10;
    uint32_t sinceLast = micros() - lastFrameUs;
    if (sinceLast < intervalUs) {
      vTaskDelay(pdMS_TO_TICKS((intervalUs - sinceLast) / 1000 + 1));
      continue;
    }

    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }
    // Drop stale frames captured before a resolution change.
    const VideoMode &m = kModes[activeMode - 1];
    if (fb->format != PIXFORMAT_JPEG || fb->width != m.width || fb->height != m.height) {
      esp_camera_fb_return(fb);
      continue;
    }

    xSemaphoreTake(xferDone, 0);  // clear any stale completion
    pendingXfer.buf = fb->buf;
    pendingXfer.len = fb->len;
    pendingXfer.ok = false;
    usbd_defer_func(startFrameXfer, nullptr, false);
    bool sent = xSemaphoreTake(xferDone, pdMS_TO_TICKS(2000)) == pdTRUE;
    size_t len = fb->len;
    if (!pendingXfer.ok) {
      // Endpoint still busy (e.g. host paused the stream); try again shortly.
      esp_camera_fb_return(fb);
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }
    lastFrameUs = micros();
    esp_camera_fb_return(fb);

    if (sent) {
      statFrames++;
      statBytes += len;
    }
    uint32_t now = millis();
    if (now - statStartMs >= 5000) {
      if (statFrames) {
        Serial.printf("%ux%u: %.1f fps, avg %u KB/frame, %u KB/s\n", m.width, m.height, statFrames * 1000.0f / (now - statStartMs),
                      statBytes / statFrames / 1024, statBytes / (now - statStartMs) * 1000 / 1024);
      }
      statFrames = statBytes = 0;
      statStartMs = now;
    }
  }
}

// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.println("\nESP32-S3 UVC webcam");

  if (!psramFound()) {
    Serial.println("PSRAM not found - set Tools > PSRAM to 'OPI PSRAM'");
  }
  if (!cameraInit()) {
    Serial.println("Halting.");
    for (;;) delay(1000);
  }

  xferDone = xSemaphoreCreateBinary();

  // Composite device with an IAD, so Windows/macOS/Linux bind their stock UVC drivers.
  USB.VID(0x303A);
  USB.PID(0x80C5);  // arbitrary dev PID, distinct from Arduino's CDC default to avoid stale Windows driver caches
  USB.usbClass(TUSB_CLASS_MISC);
  USB.usbSubClass(MISC_SUBCLASS_COMMON);
  USB.usbProtocol(MISC_PROTOCOL_IAD);
  USB.manufacturerName("Espressif");
  USB.productName("ESP32-S3 UVC Camera");
  tinyusb_enable_interface(USB_INTERFACE_CUSTOM, UVC_DESC_LEN, uvc_load_descriptor);
  // Double-buffer bulk IN FIFOs so the next packet is already queued when the host
  // polls; with a single 64 B FIFO the host gets NAKed and throughput collapses.
  tud_configure_param_t dwc2_cfg = {.dwc2 = CFG_TUD_CONFIGURE_DWC2_DEFAULT};
  dwc2_cfg.dwc2.bm_double_buffered = 0xFFFE;
  tud_configure(0, TUD_CFGID_DWC2, &dwc2_cfg);
  USB.begin();

  xTaskCreatePinnedToCore(streamTask, "uvc_stream", 4096, nullptr, 5, nullptr, 1);
  Serial.println("USB started - plug the OTG port into the PC and open any camera app.");
}

void loop() {
  vTaskDelay(portMAX_DELAY);
}
