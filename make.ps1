<#
.SYNOPSIS
  PowerShell equivalent of the Makefile, for machines without GNU make.

.EXAMPLE
  .\make.ps1 flash
  .\make.ps1 monitor -Port COM9
  .\make.ps1 preview -Res 1280x720
  .\make.ps1 preview -Res 640x480 -Fps 30
  .\make.ps1 ports          # ESP-related USB devices, with serial numbers
  .\make.ps1 ports -All     # every COM port
#>
param(
  [ValidateSet('help', 'setup', 'build', 'flash', 'upload', 'monitor', 'preview', 'modes', 'snapshot', 'size', 'clean', 'ports')]
  [string]$Target = 'help',
  [string]$Port = 'COM7',
  [int]$Baud = 115200,
  [string]$Res = '640x480',
  [string]$Fps = '',
  [string]$Camera = 'ESP32-S3 UVC Camera',
  [switch]$All
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

# USB chips found on ESP32 boards: VID -> (VID:PID -> name). Matching is by USB chip, so
# a non-ESP gadget that uses one of these bridges will be listed too.
$UsbChips = @{
  '1A86' = @{ '_' = 'WCH USB-serial'; '55D3' = 'WCH CH343'; '7523' = 'WCH CH340'; '55D4' = 'WCH CH9102'; '7522' = 'WCH CH340K' }
  '10C4' = @{ '_' = 'Silicon Labs USB-serial'; 'EA60' = 'Silicon Labs CP210x' }
  '0403' = @{ '_' = 'FTDI USB-serial'; '6001' = 'FTDI FT232R'; '6010' = 'FTDI FT2232'; '6015' = 'FTDI FT231X' }
  '303A' = @{ '_' = 'Espressif native USB'; '1001' = 'Espressif USB Serial/JTAG' }
}

# One row per device function (COM port, camera, ...) with its USB serial number.
function Get-UsbDeviceRows([bool]$ComOnly, [bool]$EspOnly) {
  $devs = Get-PnpDevice -PresentOnly | Where-Object {
    if ($ComOnly) { $_.Class -eq 'Ports' } else { $_.InstanceId -match '^USB\\VID_' -and $_.Class -ne 'USB' }
  }
  foreach ($d in $devs) {
    $vid = $null; $pid_ = $null; $serial = ''
    if ($d.InstanceId -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
      $vid = $Matches[1]; $pid_ = $Matches[2]
      # The last part of the instance ID is the device's serial number. Windows makes one up
      # (it contains '&') when there is none, or for one function of a composite device,
      # in which case the real serial is on the parent composite device.
      $id = $d.InstanceId
      if (($id -split '\\')[-1] -match '&' -and $id -match '&MI_') {
        $id = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data
      }
      $last = if ($id) { ($id -split '\\')[-1] } else { '' }
      $serial = if ($last -and $last -notmatch '&') { $last } else { '(none)' }
    }
    if ($EspOnly -and -not ($vid -and $UsbChips.ContainsKey($vid))) { continue }

    $chip = if ($vid -and $UsbChips.ContainsKey($vid)) {
      if ($UsbChips[$vid].ContainsKey($pid_)) { $UsbChips[$vid][$pid_] } else { $UsbChips[$vid]['_'] }
    } elseif ($vid) { 'USB' } else { 'not USB' }
    $side = if (-not $vid -or -not $UsbChips.ContainsKey($vid)) { '' }
            elseif ($vid -eq '303A') { 'OTG / native USB' } else { 'UART bridge' }

    [pscustomobject]@{
      Port    = if ($d.FriendlyName -match '\((COM\d+)\)') { $Matches[1] } else { '-' }
      Name    = $d.FriendlyName -replace '\s*\(COM\d+\)', ''
      Chip    = $chip
      Side    = $side
      'VID:PID' = if ($vid) { "${vid}:${pid_}" } else { '' }
      Serial  = $serial
    }
  }
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
  ports     list ESP-related USB devices with serial numbers (-All: every COM port)
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
  'ports' {
    $rows = @(Get-UsbDeviceRows -ComOnly $All.IsPresent -EspOnly (-not $All.IsPresent) |
      Sort-Object @{ Expression = { if ($_.Port -match '\d+') { [int]$Matches[0] } else { [int]::MaxValue } } }, Name)
    if ($rows.Count -eq 0) {
      if ($All) { 'No COM ports found.' } else { 'No ESP-related USB devices found. Try: .\make.ps1 ports -All' }
    } else {
      $rows | Format-Table -AutoSize | Out-String -Width 200
      if (-not $All) {
        'UART bridge      = the "UART" USB-C port: use its COM number for flash/upload/monitor.'
        'OTG / native USB = the ESP32-S3 itself; with this firmware its serial is the chip MAC.'
      }
    }
  }
}
