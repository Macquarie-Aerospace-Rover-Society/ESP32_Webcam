# ESP32-S3 USB Webcam (OV5640)

Turns an **ESP32-S3 N16R8 CAM** board with an **OV5640** sensor into a plug-and-play
USB webcam (UVC, MJPEG), built with the Arduino framework. It works with the stock
drivers on Windows, macOS and Linux: Camera app, OBS, Zoom, Teams, browsers, ffmpeg, OpenCV.

| USB-C port | Chip | Used for |
|---|---|---|
| **UART** | CH343 USB-serial bridge (UART0) | flashing, serial debug log (115200 baud) |
| **OTG** | ESP32-S3 native USB (GPIO19/20) | the webcam, shown to the PC as **"ESP32-S3 UVC Camera"** |

Plug in both while developing. Once the board is flashed, only the OTG port is needed
to use the webcam.

---

## Quick start

1. **Install the tools** (one-time)
   - [Arduino IDE 2.x](https://www.arduino.cc/en/software). Its bundled `arduino-cli` is found automatically.
   - ESP32 Arduino core **3.3.8**: `.\make.ps1 setup` (or install it from Boards Manager).
   - Optional, for preview/snapshot targets: [ffmpeg](https://ffmpeg.org/) (`winget install Gyan.FFmpeg`).
   - Optional: GNU make (`scoop install make`). Otherwise use `make.ps1`, which has the same targets.
2. **Flash** over the UART port:
   ```powershell
   .\make.ps1 flash            # or: make flash
   ```
3. **Use it**: open any camera app and pick *ESP32-S3 UVC Camera*, or:
   ```powershell
   .\make.ps1 preview -Res 1280x720
   ```

### Choosing the board

`flash`, `upload` and `monitor` find the board themselves, so you don't need to know its
COM port:

- **One ESP board plugged in**: it's used, and the port is printed (`Using COM10  WCH CH343 ...`).
- **Several boards**: `make.ps1` shows a numbered list and asks which one. `make` can't
  ask, so it lists them and stops. Re-run it with one of the options below.
- **None**: it stops with a message. If the board is only connected by its OTG port, it
  says so, because that port can't be used for flashing.

To choose a board yourself:

| | PowerShell | make |
|---|---|---|
| by COM port | `.\make.ps1 flash -Port COM10` | `make flash PORT=COM10` |
| by USB serial | `.\make.ps1 flash -Serial 5C84325830` | `make flash SERIAL=5C84325830` |

The serial number is the more reliable choice, because it doesn't change if you move the
cable to a different USB socket.

### Naming the webcam

By default every board shows up as **"ESP32-S3 UVC Camera"**. Options when building or
flashing:

| | PowerShell | make | Webcam name |
|---|---|---|---|
| default | `.\make.ps1 flash` | `make flash` | `ESP32-S3 UVC Camera` |
| name from MAC | `.\make.ps1 flash -AutoName` | `make flash AUTONAME=1` | `ESP32-S3 UVC Camera 8050` |
| custom name | `.\make.ps1 flash -Name "Desk Cam"` | `make flash NAME="Desk Cam"` | `Desk Cam` |
| both | `.\make.ps1 flash -Name "Desk Cam" -AutoName` | `make flash NAME="Desk Cam" AUTONAME=1` | `Desk Cam 8050` |

- With **AutoName**, the firmware reads the chip's MAC address at boot and adds its last
  4 hex digits. One build therefore gives every board its own name. The digits match the
  end of the MAC in `ports` (OTG row) and in esptool's `MAC:` line.
- The boot log shows the result: `USB device name: ESP32-S3 UVC Camera 8050`.
- Names can be up to 42 characters.
- The options are written to `UsbWebcam/build_opts.h`, which the sketch includes. It's
  generated and git-ignored, and rewritten on every build, so options don't carry over
  from one build to the next. The Arduino IDE also uses this file if it exists, so an IDE
  build gets whatever options the last `make` build used. Delete the file to go back to
  the defaults in the sketch.
- If Windows keeps showing an old name after a reflash, uninstall the camera in Device
  Manager (Cameras → right-click → Uninstall device) and replug the OTG cable.

`preview`, `snapshot` and `modes` find the webcam themselves, whatever it's called. With
several ESP webcams plugged in, `make.ps1` asks which one to use. Or choose it yourself
with `-Camera "<name>"` / `CAMERA="<name>"`, or with `-Serial <MAC>` / `SERIAL=<MAC>`,
using the OTG row's serial from `ports`.

### Finding the right board

`ports` shows which COM port and serial number belong to which board:

```
Port  Name                      Chip      Side        VID:PID   Serial
----  ----                      ----      ----        -------   ------
COM10 USB-Enhanced-SERIAL CH343 WCH CH343 UART bridge 1A86:55D3 5C84325830
```

- **UART bridge** rows are the boards' **UART** ports. Use that COM number for
  flash/upload/monitor. The serial number belongs to the board's CH343 chip, so it stays
  the same whichever USB socket you use, and Windows gives each chip its own COM number.
- **OTG / native USB** rows are the ESP32-S3 itself (the webcam has no COM port, shown as
  `-`). With this firmware its serial number is the chip's MAC address, the same value
  esptool prints as `MAC:`.
- The list matches by USB chip (WCH, Silicon Labs, FTDI, Espressif), so another gadget
  using one of those chips would also appear. `-All` / `ALL=1` shows every COM port.

To see which board is which, unplug one: its rows disappear.

---

## Build / flash / test commands

`make.ps1` (PowerShell) and `Makefile` (GNU make) provide the same targets:

| Target | PowerShell | make | What it does |
|---|---|---|---|
| help | `.\make.ps1` | `make` | list targets |
| setup | `.\make.ps1 setup` | `make setup` | install ESP32 core 3.3.8 |
| build | `.\make.ps1 build` | `make build` | compile into `UsbWebcam/build/` |
| flash | `.\make.ps1 flash` | `make flash` | build + upload over the UART port |
| upload | `.\make.ps1 upload` | `make upload` | upload the last build only |
| monitor | `.\make.ps1 monitor` | `make monitor` | serial log (does not reset the board) |
| preview | `.\make.ps1 preview -Res 1920x1080` | `make preview RES=1920x1080` | live ffplay window |
| modes | `.\make.ps1 modes` | `make modes` | list advertised resolutions / fps |
| snapshot | `.\make.ps1 snapshot -Res 1280x720` | `make snapshot RES=1280x720` | save one frame to `snapshot.jpg` |
| size | `.\make.ps1 size` | `make size` | firmware binary size |
| clean | `.\make.ps1 clean` | `make clean` | delete build output |
| ports | `.\make.ps1 ports` | `make ports` | ESP-related USB devices: COM port, USB chip, serial number |
| ports (all) | `.\make.ps1 ports -All` | `make ports ALL=1` | every COM port, including Bluetooth and other devices |

`preview` and `snapshot` also accept a frame rate: `-Fps 15` / `FPS=15`.

If PowerShell refuses to run the script, use
`powershell -ExecutionPolicy Bypass -File .\make.ps1 flash`.

`UsbWebcam/sketch.yaml` stores the board options, so plain `arduino-cli compile UsbWebcam`
works. It has no default port (each board has its own), so give one when uploading
directly: `arduino-cli upload -p COM10 UsbWebcam`.

### Arduino IDE instead

Open `UsbWebcam/UsbWebcam.ino` and set **Tools** to:

| Setting | Value |
|---|---|
| Board | ESP32S3 Dev Module |
| USB Mode | **USB-OTG (TinyUSB)** |
| USB CDC On Boot | **Disabled** (keeps `Serial` on the UART port) |
| Upload Mode | UART0 / Hardware CDC |
| Flash Size | 16MB (128Mb) |
| Flash Mode | QIO 80MHz |
| PSRAM | **OPI PSRAM** |
| Partition Scheme | Huge APP (3MB No OTA/1MB SPIFFS) |
| Port | the board's CH343 port (`.\make.ps1 ports` shows which one) |

---

## Resolutions and performance

The PC app chooses the resolution. The board switches the sensor to match; there is
nothing to configure on the device.

| Mode | Advertised fps | Measured fps | Avg frame size |
|---|---|---|---|
| 320×240 | 30 / 15 / 10 | not measured | small |
| 640×480 (default) | 30 / 15 / 10 | **~17–19** | ~16–23 KB |
| 1280×720 | 15 / 10 / 5 | **~9** | ~40 KB |
| 1920×1080 | 15 / 10 / 5 | ~2 (measured before double-buffering was added) | ~125 KB |

The bottleneck is the USB link. The ESP32-S3's OTG port is **USB Full-Speed (12 Mbit/s)**,
and this firmware currently gets about 300–400 KB/s through it. To get more fps at a given
resolution, raise `CAM_JPEG_QUALITY`, which makes frames smaller and lowers image quality.

Where to change the resolution in common apps:
- **Windows Camera**: Settings (gear) → Video quality
- **OBS**: Video Capture Device → Resolution/FPS Type: Custom → Resolution
- **ffplay/ffmpeg**: `-video_size 1280x720` (see `make preview`)

---

## Configuration

All settings are at the top of [`UsbWebcam/UsbWebcam.ino`](UsbWebcam/UsbWebcam.ino):

| Setting | Default | Meaning |
|---|---|---|
| `CAM_VFLIP`, `CAM_HMIRROR` | `0` | flip / mirror the image. The sensor can't rotate 90°, so mount the board the right way up. |
| `CAM_JPEG_QUALITY` | `12` | 0–63; lower = better quality but bigger frames and lower fps |
| `kModes[]` | 4 modes | resolutions offered to the PC (keep in sync with the `MJPEG_FRAME(...)` list) |
| `kDefaultMode` | `2` | 1-based index of the mode apps get if they don't ask for one (2 = 640×480) |
| `*_GPIO_NUM` | ESP32-S3-EYE / Freenove layout | camera pins; change these if your board is wired differently |
| `UVC_DEVICE_NAME` | `"ESP32-S3 UVC Camera"` | webcam name; normally set with `-Name` / `NAME=` (see *Naming the webcam*) |
| `UVC_NAME_FROM_MAC` | `0` | `1` appends the last 4 MAC digits; normally set with `-AutoName` / `AUTONAME=1` |
| `USB.VID/PID` | `0x303A:0x80C5` | USB IDs (a development PID) |

---

## How it works

```
OV5640 --DVP 8-bit--> ESP32-S3 camera DMA --> JPEG frame in PSRAM (2 buffers)
                                                   |
                          streamTask (core 1)      |  paces to host fps, drops stale-size frames
                                                   v
                 uvc_driver.c (TinyUSB UVC class) --> 8 KB bulk payloads --> OTG port --> PC
```

- **Camera**: `esp32-camera` in JPEG mode. It is initialised at 1080p so the frame
  buffers fit every mode, then switched to the mode the host commits
  (`tud_video_commit_cb` → `set_framesize`).
- **USB**: Arduino's TinyUSB stack (`USB Mode: USB-OTG`). The sketch adds a custom
  interface: an IAD plus Video Control and Video Streaming interfaces, with one MJPEG
  format, four discrete frame sizes and a **bulk** IN endpoint. The device class is set
  to Misc/IAD so every OS binds its built-in UVC driver.
- **Frame hand-off**: each frame is started from the TinyUSB task (`usbd_defer_func`),
  so the first packet write never races the USB interrupt. The camera buffer is only
  returned after the transfer-complete callback.

### Why there is a bundled `uvc_driver.c`

The Arduino core ships TinyUSB's UVC driver prebuilt, with the streaming buffer fixed
at **64 bytes**. That means one packet per UVC payload, which gave only ~7 fps at 640×480.
`uvc_driver.c` is a copy of the same driver (espressif/tinyusb @ `eae25b531`, the commit
used by core 3.3.8) with these changes:

1. **Symbols renamed** (`uvc_*`) so it can sit next to the prebuilt copy.
2. **Payload size = 127 × 64 B = 8,128 B.** The ESP32-S3 USB controller's packet counter
   is only 7 bits (`OTG_PACKET_COUNT_WIDTH = 7`), so one transfer can hold at most 127
   packets. Going above that caused truncated frames and an interrupt-watchdog crash.
3. **Short-packet guarantee**: a payload that would end exactly on a 64 B boundary is
   shortened by one byte, so the host always sees where a payload ends.
4. **Registered with `usbd_app_driver_get_cb()`**, which TinyUSB checks before its
   built-in drivers, so this copy takes over the video interfaces.

The sketch also enables **bulk IN double-buffering**
(`tud_configure(... bm_double_buffered ...)`) so the next packet is already in the
FIFO when the host polls. That roughly doubled throughput.

The driver copy matches core **3.3.8**. If you upgrade the core, rebuild and re-test.
If TinyUSB's internal APIs changed, re-copy `src/class/video/video_device.c` from the
new core's TinyUSB commit (listed in `esp32s3-libs/<ver>/versions.txt`) and re-apply the
changes above.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No "ESP32-S3 UVC Camera" in Device Manager | Use the **OTG** port with a data cable; check `make monitor` for `Camera init failed`. |
| `Camera init failed: 0x...` | Check the ribbon cable and the pin map; PSRAM must be **OPI**. |
| `PSRAM not found` in the log | Tools → PSRAM → **OPI PSRAM** (N16R8 = 8 MB octal PSRAM). |
| Upload fails / no COM port | Use the **UART** port. If it won't connect, hold **BOOT**, tap **RST**, release BOOT, then retry. |
| `Could not set video options` from ffmpeg | The requested fps isn't one the camera offers for that size. Run `make modes`, or leave out `-framerate`. |
| `I/O error` / camera busy | Only one app can use a webcam at a time. Close the other app (OBS, Camera, an old ffplay window). |
| Picture upside down / mirrored | Set `CAM_VFLIP` / `CAM_HMIRROR` and reflash. |
| Choppy at 1080p | Expected at USB Full-Speed. Use 720p, or raise `CAM_JPEG_QUALITY`. |
| Build error about USB mode | Tools → USB Mode must be **USB-OTG (TinyUSB)**. |

The serial log (`make monitor`) prints the negotiated mode when a stream starts, then
every 5 s: `640x480: 19.4 fps, avg 16 KB/frame, 313 KB/s`.

---

## Known issues

- **The first frame after a stream restart is stale.** When an app stops the stream, the
  frame that was being sent stays queued in the USB controller. The next stream starts
  with the rest of it, so the first frame can have the previous resolution or be garbled.
  Every frame after that is correct, and most apps drop the bad one. The proper fix is to
  abort the transfer when the host sends CLEAR_FEATURE(ENDPOINT_HALT). A first attempt
  that disabled the endpoint from inside the USB task hung the device, so it was
  reverted.
- **Full-Speed only**: the ESP32-S3 has no High-Speed USB PHY, so ~400 KB/s is the
  practical limit with this approach.
- No UVC controls yet (brightness, exposure and so on are not exposed to the host).

---

## Files

```
ESPCam/
├── README.md             this file
├── Makefile              GNU make targets
├── make.ps1              same targets for PowerShell
└── UsbWebcam/
    ├── UsbWebcam.ino     camera setup, UVC descriptors, streaming task
    ├── uvc_driver.c      patched TinyUSB UVC class driver (see above)
    ├── uvc_driver.h      its streaming API
    ├── sketch.yaml       arduino-cli board options
    └── build_opts.h      generated by build (-Name / -AutoName); git-ignored
```

TinyUSB (and so `uvc_driver.c`) is MIT-licensed. Its original copyright header is kept
in the file.
