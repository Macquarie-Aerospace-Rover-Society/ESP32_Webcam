# ESP32-S3 + OV5640 USB (UVC) webcam - build / flash / test helpers.
#
#   make build                  compile the firmware
#   make flash                  compile + upload over the UART (CH343) port
#   make monitor                serial log from the board (Ctrl+C to quit)
#   make preview RES=1280x720   live view of the webcam in an ffplay window
#   make ports [ALL=1]          find boards: COM port + USB serial number
#
# Override any variable on the command line, e.g. `make flash PORT=COM9`.
# Needs GNU make with a POSIX shell (Git Bash's sh is picked up automatically on
# Windows). No make? Use the equivalent PowerShell script: .\make.ps1 <target>

SKETCH      := UsbWebcam
BUILD_DIR   := $(SKETCH)/build
PORT        ?= COM7
BAUD        ?= 115200
CAMERA      ?= ESP32-S3 UVC Camera
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

.DEFAULT_GOAL := help
.PHONY: help setup build flash upload monitor preview modes snapshot size clean ports

help:
	@echo "Targets:"
	@echo "  setup     install the ESP32 Arduino core ($(CORE))"
	@echo "  build     compile the firmware into $(BUILD_DIR)"
	@echo "  flash     build, then upload over $(PORT)"
	@echo "  upload    upload the last build without recompiling"
	@echo "  monitor   open the serial log on $(PORT) at $(BAUD) baud"
	@echo "  preview   live view: RES=320x240|640x480|1280x720|1920x1080 [FPS=30|15|10|5]"
	@echo "  modes     list the resolutions/frame rates the webcam advertises"
	@echo "  snapshot  save one frame to snapshot.jpg (uses RES)"
	@echo "  size      show firmware size"
	@echo "  clean     delete build output"
	@echo "  ports     list ESP-related USB devices with serial numbers (ALL=1: every COM port)"

setup:
	"$(ARDUINO_CLI)" core update-index --additional-urls "$(CORE_URL)"
	"$(ARDUINO_CLI)" core install "$(CORE)" --additional-urls "$(CORE_URL)"

build:
	"$(ARDUINO_CLI)" compile --fqbn "$(FQBN)" --output-dir "$(BUILD_DIR)" "$(SKETCH)"

flash: build upload

upload:
	"$(ARDUINO_CLI)" upload --fqbn "$(FQBN)" -p "$(PORT)" --input-dir "$(BUILD_DIR)" "$(SKETCH)"

monitor:
	"$(ARDUINO_CLI)" monitor -p "$(PORT)" --config baudrate=$(BAUD),dtr=off,rts=off

preview:
	"$(FFPLAY)" -hide_banner -loglevel warning -f dshow -vcodec mjpeg -video_size $(RES) $(DSHOW_FPS) \
		-rtbufsize 100M -window_title "$(CAMERA) $(RES)" -i "video=$(CAMERA)"

modes:
	"$(FFMPEG)" -hide_banner -f dshow -list_options true -i "video=$(CAMERA)" 2>&1 | grep vcodec | sort -u

snapshot:
	"$(FFMPEG)" -hide_banner -loglevel error -y -f dshow -vcodec mjpeg -video_size $(RES) \
		-i "video=$(CAMERA)" -frames:v 1 -c copy snapshot.jpg
	@echo "saved snapshot.jpg ($(RES))"

size: build
	@ls -l "$(BUILD_DIR)/$(SKETCH).ino.bin"

clean:
	rm -rf "$(BUILD_DIR)"

# Windows: make.ps1 reads the device list (COM port, USB chip, serial number).
# Linux: /dev/serial/by-id names contain the vendor, product and serial number.
# macOS: /dev/cu.* names usually end in the serial number.
ESP_USB_IDS := 1a86|wch|10c4|silicon_labs|cp210|0403|ftdi|303a|espressif
ports:
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -ExecutionPolicy Bypass -File make.ps1 ports $(if $(ALL),-All,)
else
	@if [ -d /dev/serial/by-id ]; then \
		ls -l /dev/serial/by-id | awk 'NR>1 {print $$NF " <- " $$(NF-2)}' | sed 's|../../|/dev/|' \
			$(if $(ALL),,| grep -iE '$(ESP_USB_IDS)'); \
	else \
		ls /dev/cu.* 2>/dev/null $(if $(ALL),,| grep -iE 'usbserial|usbmodem|wchusb|SLAB'); \
	fi || echo "No matching serial devices."
endif
