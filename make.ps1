<#
.SYNOPSIS
  PowerShell equivalent of the Makefile, for machines without GNU make.

  flash / upload / monitor find the board themselves when -Port is left out: the one
  ESP board plugged in, or a numbered list to choose from when there are several.

.EXAMPLE
  .\make.ps1 flash
  .\make.ps1 flash -Serial 5C84325830   # pick a board by its USB serial number
  .\make.ps1 flash -AutoName            # webcam named "ESP32-S3 UVC Camera 8050" (MAC-based)
  .\make.ps1 flash -Name "Desk Cam" -AutoName
  .\make.ps1 monitor -Port COM9
  .\make.ps1 preview -Res 1280x720
  .\make.ps1 preview -Res 640x480 -Fps 30
  .\make.ps1 ports          # ESP-related USB devices, with serial numbers
  .\make.ps1 ports -All     # every COM port
#>
param(
  [ValidateSet('help', 'setup', 'build', 'flash', 'upload', 'monitor', 'preview', 'modes', 'snapshot', 'size', 'clean', 'ports', 'port', 'camera')]
  [string]$Target = 'help',
  [string]$Port = '',
  [string]$Serial = '',
  [int]$Baud = 115200,
  [string]$Res = '640x480',
  [string]$Fps = '',
  [string]$Camera = '',
  [string]$Name = '',
  [switch]$AutoName,
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

# ESP boards that have a COM port, optionally narrowed to one USB serial number.
function Get-EspPorts {
  $rows = @(Get-UsbDeviceRows -ComOnly $false -EspOnly $true | Where-Object { $_.Port -ne '-' })
  if ($Serial) { $rows = @($rows | Where-Object { $_.Serial -eq $Serial }) }
  return $rows
}

function Format-PortChoice($r) { "$($r.Port)  $($r.Chip)  ($($r.Side), serial $($r.Serial))" }

# -Port if given; otherwise the only ESP board, or ask which one when there are several.
function Resolve-Port([bool]$Interactive) {
  if ($Port) { return $Port }
  $rows = @(Get-EspPorts)
  $what = if ($Serial) { "ESP board with serial $Serial" } else { 'ESP board' }
  if ($rows.Count -eq 0) {
    $otg = @(Get-UsbDeviceRows -ComOnly $false -EspOnly $true | Where-Object { $_.Port -eq '-' })
    $hint = if ($otg.Count) {
      " An ESP32-S3 is connected by its OTG port only ($($otg[0].Name), serial $($otg[0].Serial)); that port can't flash, so plug in the UART port too."
    } else { '' }
    throw "No $what with a COM port found.$hint Or give the port yourself: -Port COMx (make: PORT=COMx). .\make.ps1 ports -All lists every port."
  }
  if ($rows.Count -eq 1) {
    [Console]::Error.WriteLine("Using $(Format-PortChoice $rows[0])")
    return $rows[0].Port
  }
  $list = ($rows | ForEach-Object -Begin { $i = 0 } -Process { $i++; "  [$i] $(Format-PortChoice $_)" }) -join "`n"
  if (-not $Interactive -or [Console]::IsInputRedirected) {
    throw "Several ESP boards found; choose one with -Port COMx or -Serial <serial> (make: PORT=... or SERIAL=...):`n$list"
  }
  [Console]::Error.WriteLine("Several ESP boards found:`n$list")
  while ($true) {
    $pick = Read-Host "Which one? (1-$($rows.Count))"
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $rows.Count) {
      return $rows[[int]$pick - 1].Port
    }
  }
}

# Firmware options for the next build, as a header the sketch includes (see UsbWebcam.ino).
# Rewritten on every build so options never carry over from an earlier one; left alone
# when unchanged so arduino-cli doesn't recompile needlessly.
function Write-BuildOpts {
  $lines = @('// Generated by make.ps1 / make build - do not edit, not in source control.')
  if ($Name) {
    if ($Name.Length -gt 42) { throw "-Name is too long ($($Name.Length) chars, max 42)." }
    $lines += '#define UVC_DEVICE_NAME "' + ($Name -replace '\\', '\\' -replace '"', '\"') + '"'
  }
  if ($AutoName) { $lines += '#define UVC_NAME_FROM_MAC 1' }
  $text = ($lines -join "`n") + "`n"
  $file = Join-Path $PSScriptRoot "$Sketch/build_opts.h"
  if (-not (Test-Path $file) -or [IO.File]::ReadAllText($file) -ne $text) {
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $false))
  }
  $shown = if ($Name) { $Name } else { 'ESP32-S3 UVC Camera' }
  if ($AutoName) { $shown += ' <last 4 MAC digits>' }
  [Console]::Error.WriteLine("Webcam name: $shown")
}

# The webcam to open: -Camera if given, otherwise the one ESP32-S3 webcam plugged in
# (narrowed by -Serial, which for the webcam is the board's MAC), or ask when there are several.
function Resolve-Camera([bool]$Interactive = $true) {
  if ($Camera) { return $Camera }
  $cams = @(Get-UsbDeviceRows -ComOnly $false -EspOnly $true | Where-Object { $_.'VID:PID' -eq '303A:80C5' })
  if ($Serial) { $cams = @($cams | Where-Object { $_.Serial -eq $Serial }) }
  if ($cams.Count -eq 0) {
    $what = if ($Serial) { " with serial $Serial" } else { '' }
    throw "No ESP32-S3 webcam$what found. Plug in the board's OTG port, or pass -Camera `"<name>`"."
  }
  if ($cams.Count -eq 1) { return $cams[0].Name }
  $list = ($cams | ForEach-Object -Begin { $i = 0 } -Process { $i++; "  [$i] $($_.Name)  (serial $($_.Serial))" }) -join "`n"
  if (-not $Interactive -or [Console]::IsInputRedirected) { throw "Several ESP32-S3 webcams found; pass -Camera `"<name>`" or -Serial <MAC>:`n$list" }
  [Console]::Error.WriteLine("Several ESP32-S3 webcams found:`n$list")
  while ($true) {
    $pick = Read-Host "Which one? (1-$($cams.Count))"
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $cams.Count) { return $cams[[int]$pick - 1].Name }
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
  build     compile the firmware into $BuildDir   [-Name "<webcam name>"] [-AutoName: add MAC digits]
  flash     build, then upload   (board found automatically, or -Port COMx / -Serial <serial>)
            takes the same -Name / -AutoName options as build
  upload    upload the last build without recompiling (same port options)
  monitor   open the serial log at $Baud baud          (same port options)
  preview   live view: -Res 320x240|640x480|1280x720|1920x1080 [-Fps 30|15|10|5]
            (webcam found automatically, or -Camera "<name>" / -Serial <MAC>; same for modes, snapshot)
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
    Write-BuildOpts
    Invoke-Checked $Cli @('compile', '--fqbn', $Fqbn, '--output-dir', $BuildDir, $Sketch)
  }
  'upload' {
    $p = Resolve-Port -Interactive $true
    Invoke-Checked $Cli @('upload', '--fqbn', $Fqbn, '-p', $p, '--input-dir', $BuildDir, $Sketch)
  }
  'flash' {
    $p = Resolve-Port -Interactive $true  # pick the board before the (slow) build
    & $PSCommandPath build -Name $Name -AutoName:$AutoName
    & $PSCommandPath upload -Port $p
  }
  'monitor' {
    $p = Resolve-Port -Interactive $true
    Invoke-Checked $Cli @('monitor', '-p', $p, '--config', "baudrate=$Baud,dtr=off,rts=off")
  }
  'camera' {
    # Prints just the webcam's name (used by the Makefile). Never prompts.
    try { Resolve-Camera -Interactive $false }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
  }
  'port' {
    # Prints just the COM port (used by the Makefile). Never prompts; on failure prints
    # only the message, without PowerShell's error decoration.
    try { Resolve-Port -Interactive $false }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
  }
  'preview' {
    $Camera = Resolve-Camera
    $a = @('-hide_banner', '-loglevel', 'warning') + (Get-DshowArgs) +
         @('-rtbufsize', '100M', '-window_title', "$Camera $Res", '-i', "video=$Camera")
    & ffplay @a
  }
  'modes' {
    # ffmpeg prints the device's mode list on stderr and then exits with an error; that's expected.
    $Camera = Resolve-Camera
    $ErrorActionPreference = 'Continue'
    ffmpeg -hide_banner -f dshow -list_options true -i "video=$Camera" 2>&1 |
      ForEach-Object { "$_" } | Where-Object { $_ -match 'vcodec' } | Sort-Object -Unique
  }
  'snapshot' {
    $Camera = Resolve-Camera
    $a = @('-hide_banner', '-loglevel', 'error', '-y') + (Get-DshowArgs) +
         @('-i', "video=$Camera", '-frames:v', '1', '-c', 'copy', 'snapshot.jpg')
    Invoke-Checked 'ffmpeg' $a
    "saved snapshot.jpg ($Res, from $Camera)"
  }
  'size' {
    & $PSCommandPath build -Name $Name -AutoName:$AutoName
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
