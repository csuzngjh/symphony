param(
  [string]$WorkflowPath = "",
  [int]$Port = 4000,
  [string]$LogsRoot = "",
  [switch]$NoWait,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$SymphonyDir = "D:\Code\symphony\elixir"
$AckFlag = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

function Write-Banner {
  Write-Host "+========================================+"
  Write-Host "|     Symphony Agent Orchestrator        |"
  Write-Host "|  Poll Linear -> Dispatch -> Collect    |"
  Write-Host "+========================================+"
  Write-Host ""
}

function Test-Prerequisite {
  param([string]$Label, [string]$Command)

  $found = Get-Command $Command -ErrorAction SilentlyContinue
  if ($found) {
    Write-Host "  [OK] $Label : $($found.Source)" -ForegroundColor Green
    return $true
  } else {
    Write-Host "  [MISSING] $Label : $Command not found in PATH" -ForegroundColor Red
    return $false
  }
}

function Test-PortFree {
  param([int]$Port)

  $listener = $null
  try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    return $true
  } catch {
    Write-Host "  [IN USE] Port $Port is already in use" -ForegroundColor Red
    return $false
  } finally {
    if ($listener) { $listener.Stop() }
  }
}

if ($DryRun) {
  Write-Banner
  Write-Host "Dry-run checks:" -ForegroundColor Cyan
  Write-Host ""

  $symphonyExe = Join-Path $SymphonyDir "bin\symphony"
  $symphonyExeExe = Join-Path $SymphonyDir "bin\symphony.exe"
  $symphonyBin = if (Test-Path $symphonyExeExe) { $symphonyExeExe } elseif (Test-Path $symphonyExe) { $symphonyExe } else { $null }

  if ($symphonyBin) {
    Write-Host "  [OK] bin/symphony : $symphonyBin" -ForegroundColor Green
  } else {
    Write-Host "  [MISSING] bin/symphony not found. Run: cd $SymphonyDir; mix escript.build" -ForegroundColor Red
  }

  if ($WorkflowPath -and (Test-Path $WorkflowPath)) {
    Write-Host "  [OK] Workflow : $WorkflowPath" -ForegroundColor Green
  } elseif ($WorkflowPath) {
    Write-Host "  [MISSING] Workflow not found: $WorkflowPath" -ForegroundColor Red
  } else {
    Write-Host "  [MISSING] No WorkflowPath specified. Pass -WorkflowPath <path>" -ForegroundColor Red
  }

  if ($env:LINEAR_API_KEY) {
    Write-Host "  [OK] LINEAR_API_KEY is set" -ForegroundColor Green
  } else {
    Write-Host "  [MISSING] LINEAR_API_KEY environment variable is not set" -ForegroundColor Red
  }

  Test-Prerequisite "acpx" "acpx"
  Test-Prerequisite "claude" "claude"
  Test-PortFree $Port

  Write-Host ""
  Write-Host "Dry-run complete." -ForegroundColor Cyan
  exit 0
}

Write-Banner

if (-not $WorkflowPath) {
  Write-Host "ERROR: -WorkflowPath is required. No default workflow will be used." -ForegroundColor Red
  Write-Host "Usage: start-symphony.ps1 -WorkflowPath <path> [-Port <port>] [-LogsRoot <path>] [-NoWait] [-DryRun]"
  exit 1
}

if (-not (Test-Path $WorkflowPath)) {
  Write-Host "ERROR: Workflow file not found: $WorkflowPath" -ForegroundColor Red
  exit 1
}

Set-Location -LiteralPath $SymphonyDir

$symphonyExe = Join-Path $SymphonyDir "bin\symphony.exe"
if (-not (Test-Path $symphonyExe)) {
  $symphonyExe = Join-Path $SymphonyDir "bin\symphony"
}

if (-not (Test-Path $symphonyExe)) {
  Write-Host "ERROR: bin/symphony not found at $symphonyExe" -ForegroundColor Red
  Write-Host "Run: cd $SymphonyDir; mix escript.build" -ForegroundColor Yellow
  exit 1
}

$escriptCmd = Get-Command escript -ErrorAction SilentlyContinue
if (-not $escriptCmd) {
  $escriptCmd = Get-Command mise -ErrorAction SilentlyContinue
}

if (-not $env:LINEAR_API_KEY) {
  Write-Host "WARNING: LINEAR_API_KEY environment variable is not set." -ForegroundColor Yellow
}

$argsList = @()

$argsList += $WorkflowPath
$argsList += $AckFlag
$argsList += "--port"
$argsList += $Port

if ($LogsRoot) {
  $argsList += "--logs-root"
  $argsList += $LogsRoot
}

$argString = ($argsList | ForEach-Object { "`"$_`"" }) -join " "

if ($NoWait) {
  Write-Host "Starting Symphony in background..." -ForegroundColor Yellow

  if ($escriptCmd -and $escriptCmd.Name -eq "mise") {
    Write-Host "  Command: mise exec -- escript $symphonyExe $argString" -ForegroundColor Gray
  } else {
    Write-Host "  Command: escript $symphonyExe $argString" -ForegroundColor Gray
  }

  Write-Host ""

  if ($escriptCmd -and $escriptCmd.Name -eq "mise") {
    $allArgs = @("exec", "--", "escript", $symphonyExe) + $argsList
    $proc = Start-Process -FilePath "mise" -ArgumentList $allArgs -WindowStyle Hidden -PassThru
  } elseif ($escriptCmd) {
    $allArgs = @($symphonyExe) + $argsList
    $proc = Start-Process -FilePath "escript" -ArgumentList $allArgs -WindowStyle Hidden -PassThru
  } else {
    $proc = Start-Process -FilePath $symphonyExe -ArgumentList $argsList -WindowStyle Hidden -PassThru
  }

  $procId = $proc.Id

  Start-Sleep -Milliseconds 500

  if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Process $procId exited immediately. The escript may have failed to start." -ForegroundColor Red
    Write-Host "Try running manually: escript $symphonyExe $argString" -ForegroundColor Yellow
    exit 1
  }

  Write-Host "Process started with PID: $procId" -ForegroundColor Green
  Write-Host "Waiting up to 15 seconds for service to become available..." -ForegroundColor Yellow

  $maxWait = 15
  $started = $false
  for ($i = 1; $i -le $maxWait; $i++) {
    Start-Sleep -Seconds 1
    try {
      $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/state" -TimeoutSec 2 -ErrorAction Stop
      $started = $true
      break
    } catch {
      Write-Host "  ... waiting ($i/$maxWait)" -ForegroundColor Gray
    }
  }

  if ($started) {
    Write-Host ""
    Write-Host "Symphony is running!" -ForegroundColor Green
    Write-Host "  PID:       $procId"
    Write-Host "  Dashboard: http://127.0.0.1:$Port/"
    Write-Host "  API state: http://127.0.0.1:$Port/api/v1/state"
    if ($LogsRoot) {
      Write-Host "  Logs:      $LogsRoot"
    }
    Write-Host ""
    Write-Host "Check status: Invoke-RestMethod http://127.0.0.1:$Port/api/v1/state"
    Write-Host "Stop:         Stop-Process -Id $procId"
  } else {
    Write-Host ""
    Write-Host "ERROR: Symphony did not become available within $maxWait seconds." -ForegroundColor Red
    Write-Host "The process may have failed to start. Check logs if available." -ForegroundColor Yellow

    if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
      Write-Host "Process $procId has already exited." -ForegroundColor Red
    }

    exit 1
  }
} else {
  Write-Host "Starting in foreground... Press Ctrl+C to stop." -ForegroundColor Yellow

  if ($escriptCmd -and $escriptCmd.Name -eq "mise") {
    Write-Host "  Command: mise exec -- escript $symphonyExe $argString" -ForegroundColor Gray
  } else {
    Write-Host "  Command: escript $symphonyExe $argString" -ForegroundColor Gray
  }

  Write-Host ""

  if ($escriptCmd -and $escriptCmd.Name -eq "mise") {
    & mise exec -- escript $symphonyExe $argsList
  } elseif ($escriptCmd) {
    & escript $symphonyExe $argsList
  } else {
    & $symphonyExe $argsList
  }

  $exitCode = $LASTEXITCODE
  Write-Host "Symphony exited with code: $exitCode" -ForegroundColor Yellow
  exit $exitCode
}