<#
.SYNOPSIS
  PowerShell equivalent of the Makefile, for machines without GNU make.

.EXAMPLE
  .\make.ps1 flash
  .\make.ps1 monitor -Port COM9
  .\make.ps1 preview -Res 1280x720
  .\make.ps1 preview -Res 640x480 -Fps 30
#>
param(
  [ValidateSet('help', 'setup', 'build', 'flash', 'upload', 'monitor', 'preview', 'modes', 'snapshot', 'size', 'clean')]
  [string]$Target = 'help',
  [string]$Port = 'COM7',
  [int]$Baud = 115200,
  [string]$Res = '640x480',
  [string]$Fps = '',
  [string]$Camera = 'ESP32-S3 UVC Camera'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Sketch   = 'UsbWebcam'
$BuildDir = "$Sketch/build"
$Core     = 'esp32:esp32@3.3.8'
$CoreUrl  = 'https://espressif.github.io/arduino-esp32/package_esp32_index.json'
$Fqbn     = 'esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,UploadMode=default,FlashSize=16M,FlashMode=qio,PSRAM=opi,PartitionScheme=huge_app'

# arduino-cli: use one on PATH, otherwise the copy bundled with Arduino IDE 2.x.
$Cli = (Get-Command arduino-cli -ErrorAction SilentlyContinue).Source
if (-not $Cli) {
  $Cli = Join-Path $env:LOCALAPPDATA 'Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe'
}

function Invoke-Checked([string]$Exe, [string[]]$ArgList) {
  & $Exe @ArgList
  if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Exe)) failed with exit code $LASTEXITCODE" }
}

function Get-DshowArgs {
  $a = @('-f', 'dshow', '-vcodec', 'mjpeg', '-video_size', $Res)
  if ($Fps) { $a += @('-framerate', $Fps) }
  return $a
}

switch ($Target) {
  'help' {
    @"
Targets:
  setup     install the ESP32 Arduino core ($Core)
  build     compile the firmware into $BuildDir
  flash     build, then upload over $Port
  upload    upload the last build without recompiling
  monitor   open the serial log on $Port at $Baud baud
  preview   live view: -Res 320x240|640x480|1280x720|1920x1080 [-Fps 30|15|10|5]
  modes     list the resolutions/frame rates the webcam advertises
  snapshot  save one frame to snapshot.jpg (uses -Res)
  size      show firmware size
  clean     delete build output
"@
  }
  'setup' {
    Invoke-Checked $Cli @('core', 'update-index', '--additional-urls', $CoreUrl)
    Invoke-Checked $Cli @('core', 'install', $Core, '--additional-urls', $CoreUrl)
  }
  'build' {
    Invoke-Checked $Cli @('compile', '--fqbn', $Fqbn, '--output-dir', $BuildDir, $Sketch)
  }
  'upload' {
    Invoke-Checked $Cli @('upload', '--fqbn', $Fqbn, '-p', $Port, '--input-dir', $BuildDir, $Sketch)
  }
  'flash' {
    & $PSCommandPath build
    & $PSCommandPath upload -Port $Port
  }
  'monitor' {
    Invoke-Checked $Cli @('monitor', '-p', $Port, '--config', "baudrate=$Baud,dtr=off,rts=off")
  }
  'preview' {
    $a = @('-hide_banner', '-loglevel', 'warning') + (Get-DshowArgs) +
         @('-rtbufsize', '100M', '-window_title', "$Camera $Res", '-i', "video=$Camera")
    & ffplay @a
  }
  'modes' {
    # ffmpeg prints the device's mode list on stderr and then exits with an error; that's expected.
    $ErrorActionPreference = 'Continue'
    ffmpeg -hide_banner -f dshow -list_options true -i "video=$Camera" 2>&1 |
      ForEach-Object { "$_" } | Where-Object { $_ -match 'vcodec' } | Sort-Object -Unique
  }
  'snapshot' {
    $a = @('-hide_banner', '-loglevel', 'error', '-y') + (Get-DshowArgs) +
         @('-i', "video=$Camera", '-frames:v', '1', '-c', 'copy', 'snapshot.jpg')
    Invoke-Checked 'ffmpeg' $a
    "saved snapshot.jpg ($Res)"
  }
  'size' {
    & $PSCommandPath build
    Get-Item "$BuildDir/$Sketch.ino.bin" | Select-Object Name, Length
  }
  'clean' {
    if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
  }
}
