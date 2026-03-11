param(
  [string]$SourceFile = "",
  [switch]$PullFromDevice,
  [string]$DeviceLogDir = "/data/storage/el2/base/files/logs",
  [string]$DeviceSerial = ""
)

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$targetDir = Join-Path $workspaceRoot "logs"
$targetFile = Join-Path $targetDir "full.log"
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

$tempSourceFile = ""
$resolvedSourceFile = ""
$sourceLabel = ""
$syncFromDevice = $PullFromDevice.IsPresent -or [string]::IsNullOrWhiteSpace($SourceFile)

if ($syncFromDevice) {
  $hdcCommand = Get-Command "hdc" -ErrorAction SilentlyContinue
  if ($null -eq $hdcCommand) {
    throw "hdc command not found. Please install and configure HarmonyOS hdc."
  }

  $deviceArgs = @()
  if (-not [string]::IsNullOrWhiteSpace($DeviceSerial)) {
    $deviceArgs += @("-t", $DeviceSerial)
  }

  $deviceListCommand = "ls -1t $DeviceLogDir/run_*.log"
  $deviceListOutput = (& hdc @deviceArgs shell $deviceListCommand 2>&1) | ForEach-Object { "$_".Trim() }
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read device log directory: $($deviceListOutput -join '; ')"
  }

  $deviceLogFile = $deviceListOutput | Where-Object { $_ -and ($_ -like "$DeviceLogDir/*") } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($deviceLogFile)) {
    throw "No run_*.log found under device directory $DeviceLogDir."
  }

  $tempSourceFile = Join-Path $env:TEMP ("smartdrive_run_" + [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + ".log")
  $deviceRecvOutput = (& hdc @deviceArgs file recv $deviceLogFile $tempSourceFile 2>&1) | ForEach-Object { "$_".Trim() }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempSourceFile -PathType Leaf)) {
    throw "Failed to pull log from device: $($deviceRecvOutput -join '; ')"
  }

  $resolvedSourceFile = $tempSourceFile
  $sourceLabel = "device file $deviceLogFile"
} else {
  $resolvedSourceFile = $SourceFile
  if (-not (Test-Path -LiteralPath $resolvedSourceFile -PathType Leaf)) {
    throw "Source file does not exist: $resolvedSourceFile"
  }
  $sourceLabel = "local file $resolvedSourceFile"
}

try {
  $timeText = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  $sourceContent = Get-Content -LiteralPath $resolvedSourceFile -Raw
  if ($null -eq $sourceContent) {
    $sourceContent = ""
  }
  $sectionText = "===== [$timeText] sync source: $sourceLabel =====`r`n$sourceContent`r`n"
  Add-Content -LiteralPath $targetFile -Value $sectionText -Encoding UTF8
  Write-Output "Log sync finished: $targetFile"
} finally {
  if (-not [string]::IsNullOrWhiteSpace($tempSourceFile) -and (Test-Path -LiteralPath $tempSourceFile -PathType Leaf)) {
    Remove-Item -LiteralPath $tempSourceFile -Force
  }
}
