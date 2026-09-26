# ESP32-S3 + OV5640 USB (UVC) webcam - build / flash / test helpers.
#
#   make build                  compile the firmware
#   make flash                  compile + upload over the UART (CH343) port
#   make monitor                serial log from the board (Ctrl+C to quit)
#   make preview RES=1280x720   live view of the webcam in an ffplay window
#   make ports [ALL=1]          find boards: COM port + USB serial number
#
# flash / upload / monitor find the board themselves: the one ESP board plugged in.
# With several boards, choose one with PORT=COM9 or SERIAL=<usb serial> (see `make ports`).
#
# Webcam name: `make flash AUTONAME=1` names it after the chip MAC ("ESP32-S3 UVC Camera 8050"),
# NAME="Desk Cam" sets the base name. preview/snapshot/modes find the webcam themselves.
#
# Override any variable on the command line, e.g. `make monitor BAUD=921600`.
# Needs GNU make with a POSIX shell (Git Bash's sh is picked up automatically on
# Windows). No make? Use the equivalent PowerShell script: .\make.ps1 <target>

SKETCH      := UsbWebcam
BUILD_DIR   := $(SKETCH)/build
PORT        ?=
SERIAL      ?=
BAUD        ?= 115200
CAMERA      ?=
NAME        ?=
AUTONAME    ?=
RES         ?= 640x480
FPS         ?=
ALL         ?=
CORE        := esp32:esp32@3.3.8
CORE_URL    := https://espressif.github.io/arduino-esp32/package_esp32_index.json
FQBN        := esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,UploadMode=default,FlashSize=16M,FlashMode=qio,PSRAM=opi,PartitionScheme=huge_app

# arduino-cli: use one on PATH, otherwise the copy bundled with Arduino IDE 2.x.
ARDUINO_CLI ?= $(or $(shell command -v arduino-cli 2>/dev/null),$(LOCALAPPDATA)/Programs/Arduino IDE/resources/app/lib/backend/resources/arduino-cli.exe)
FFPLAY      ?= ffplay
FFMPEG      ?= ffmpeg

DSHOW_FPS   := $(if $(FPS),-framerate $(FPS),)
PS1         := powershell -NoProfile -ExecutionPolicy Bypass -File make.ps1

# USB chips found on ESP32 boards (WCH, Silicon Labs, FTDI, Espressif).
ESP_USB_IDS := 1a86|wch|10c4|silicon_labs|cp210|0403|ftdi|303a|espressif

# FIND_PORT prints the serial port of the one ESP board plugged in (narrowed by SERIAL if
# set), or explains on stderr and fails when there are none or several.
#   Windows: make.ps1 reads the device list (COM port, USB chip, serial number).
#   Linux:   /dev/serial/by-id names contain the vendor, product and serial number.
#   macOS:   /dev/cu.* names usually end in the serial number.
ifeq ($(OS),Windows_NT)
FIND_PORT = $(PS1) port $(if $(SERIAL),-Serial $(SERIAL),) | tr -d '\r'
else
FIND_PORT = sh -c 'set -- $$( (ls -d /dev/serial/by-id/* || ls -d /dev/cu.*) 2>/dev/null \
	| grep -iE "$(ESP_USB_IDS)|usbserial|usbmodem|wchusb|SLAB" $(if $(SERIAL),| grep -i "$(SERIAL)",)); \
	if [ $$\# -eq 1 ]; then readlink -f "$$1" 2>/dev/null || echo "$$1"; \
	elif [ $$\# -eq 0 ]; then echo "No ESP board found$(if $(SERIAL), with serial $(SERIAL),). Plug in the UART port or pass PORT=..." >&2; exit 1; \
	else echo "Several ESP boards found; pass PORT=... or SERIAL=...:" >&2; printf "  %s\n" "$$@" >&2; exit 1; fi'
endif

# Shell snippet: $port = PORT if given, else the detected board.
GET_PORT = port="$(PORT)"; [ -n "$$port" ] || port=$$($(FIND_PORT)) && [ -n "$$port" ] || exit 1

# Shell snippet: $cam = CAMERA if given, else the detected ESP32-S3 webcam, narrowed by
# SERIAL (the board's MAC) if set. Windows only, like the dshow capture that uses it.
GET_CAMERA = cam="$(CAMERA)"; [ -n "$$cam" ] || cam=$$($(PS1) camera $(if $(SERIAL),-Serial $(SERIAL),) | tr -d '\r') \
	&& [ -n "$$cam" ] || exit 1

# Firmware options for the build, as the header UsbWebcam.ino includes. Rewritten every
# build so options never carry over; only replaced when changed, to avoid rebuilds.
OPTS_H := $(SKETCH)/build_opts.h

.DEFAULT_GOAL := help
.PHONY: help setup build flash upload monitor preview modes snapshot size clean ports

help:
	@echo "Targets:"
	@echo "  setup     install the ESP32 Arduino core ($(CORE))"
	@echo "  build     compile the firmware into $(BUILD_DIR)   [NAME=\"<webcam name>\"] [AUTONAME=1: add MAC digits]"
	@echo "  flash     build, then upload   (board found automatically, or PORT=COMx / SERIAL=<serial>)"
	@echo "            takes the same NAME / AUTONAME options as build"
	@echo "  upload    upload the last build without recompiling (same port options)"
	@echo "  monitor   open the serial log at $(BAUD) baud          (same port options)"
	@echo "  preview   live view: RES=320x240|640x480|1280x720|1920x1080 [FPS=30|15|10|5]"
	@echo "            (webcam found automatically, or CAMERA=\"<name>\" / SERIAL=<MAC>; same for modes, snapshot)"
	@echo "  modes     list the resolutions/frame rates the webcam advertises"
	@echo "  snapshot  save one frame to snapshot.jpg (uses RES)"
	@echo "  size      show firmware size"
	@echo "  clean     delete build output"
	@echo "  ports     list ESP-related USB devices with serial numbers (ALL=1: every COM port)"

setup:
	"$(ARDUINO_CLI)" core update-index --additional-urls "$(CORE_URL)"
	"$(ARDUINO_CLI)" core install "$(CORE)" --additional-urls "$(CORE_URL)"

build:
	@{ echo '// Generated by make.ps1 / make build - do not edit, not in source control.'; \
	  $(if $(NAME),echo '#define UVC_DEVICE_NAME "$(subst ",\",$(NAME))"';) \
	  $(if $(AUTONAME),echo '#define UVC_NAME_FROM_MAC 1';) } > "$(OPTS_H).tmp"; \
	if cmp -s "$(OPTS_H).tmp" "$(OPTS_H)"; then rm -f "$(OPTS_H).tmp"; else mv -f "$(OPTS_H).tmp" "$(OPTS_H)"; fi; \
	echo "Webcam name: $(or $(NAME),ESP32-S3 UVC Camera)$(if $(AUTONAME), <last 4 MAC digits>,)"
	"$(ARDUINO_CLI)" compile --fqbn "$(FQBN)" --output-dir "$(BUILD_DIR)" "$(SKETCH)"

# Pick the board before the (slow) build so a missing or ambiguous board fails fast.
# NAME / AUTONAME reach the sub-make's build automatically (command-line variables).
flash:
	@$(GET_PORT); \
	$(MAKE) --no-print-directory build && $(MAKE) --no-print-directory upload PORT="$$port"

upload:
	@$(GET_PORT); echo "Uploading to $$port"; \
	"$(ARDUINO_CLI)" upload --fqbn "$(FQBN)" -p "$$port" --input-dir "$(BUILD_DIR)" "$(SKETCH)"

monitor:
	@$(GET_PORT); echo "Monitoring $$port"; \
	"$(ARDUINO_CLI)" monitor -p "$$port" --config baudrate=$(BAUD),dtr=off,rts=off

preview:
	@$(GET_CAMERA); \
	"$(FFPLAY)" -hide_banner -loglevel warning -f dshow -vcodec mjpeg -video_size $(RES) $(DSHOW_FPS) \
		-rtbufsize 100M -window_title "$$cam $(RES)" -i "video=$$cam"

modes:
	@$(GET_CAMERA); \
	"$(FFMPEG)" -hide_banner -f dshow -list_options true -i "video=$$cam" 2>&1 | grep vcodec | sort -u

snapshot:
	@$(GET_CAMERA); \
	"$(FFMPEG)" -hide_banner -loglevel error -y -f dshow -vcodec mjpeg -video_size $(RES) $(DSHOW_FPS) \
		-i "video=$$cam" -frames:v 1 -c copy snapshot.jpg && echo "saved snapshot.jpg ($(RES), from $$cam)"

size: build
	@ls -l "$(BUILD_DIR)/$(SKETCH).ino.bin"

clean:
	rm -rf "$(BUILD_DIR)"

ports:
ifeq ($(OS),Windows_NT)
	@$(PS1) ports $(if $(ALL),-All,)
else
	@if [ -d /dev/serial/by-id ]; then \
		ls -l /dev/serial/by-id | awk 'NR>1 {print $$NF " <- " $$(NF-2)}' | sed 's|../../|/dev/|' \
			$(if $(ALL),,| grep -iE '$(ESP_USB_IDS)'); \
	else \
		ls /dev/cu.* 2>/dev/null $(if $(ALL),,| grep -iE 'usbserial|usbmodem|wchusb|SLAB'); \
	fi || echo "No matching serial devices."
endif
