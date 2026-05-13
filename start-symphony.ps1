param(
  [string]$WorkflowPath = "",
  [int]$Port = 4000,
  [string]$LogsRoot = "",
  [switch]$NoWait
)

$SymphonyDir = "D:\Code\symphony\elixir"
$AckFlag = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

Write-Host "+========================================+"
Write-Host "|     Symphony Agent Orchestrator        |"
Write-Host "|  Poll Linear -> Dispatch -> Collect    |"
Write-Host "+========================================+"
Write-Host ""

Set-Location -LiteralPath $SymphonyDir

$symphonyExe = Join-Path $SymphonyDir "bin\symphony.exe"
if (-not (Test-Path $symphonyExe)) {
  $symphonyExe = Join-Path $SymphonyDir "bin\symphony"
}

$argsList = @()

if ($WorkflowPath -and (Test-Path $WorkflowPath)) {
  $argsList += "`"$WorkflowPath`""
} elseif ($WorkflowPath) {
  $argsList += "`"$WorkflowPath`""
} else {
  $defaultWorkflow = Join-Path $SymphonyDir "WORKFLOW.md"
  if (Test-Path $defaultWorkflow) {
    $argsList += "`"$defaultWorkflow`""
  }
}

$argsList += $AckFlag
$argsList += "--port"
$argsList += $Port

if ($LogsRoot) {
  $argsList += "--logs-root"
  $argsList += "`"$LogsRoot`""
}

$fullArgs = $argsList -join " "

if ($NoWait) {
  Start-Process -WindowStyle Hidden -FilePath $symphonyExe -ArgumentList $fullArgs
  Write-Host "Symphony starting in background (PID hidden)" -ForegroundColor Green
  Write-Host "  Workflow: $WorkflowPath" -ForegroundColor Gray
  Write-Host "  Port:     $Port" -ForegroundColor Gray
  if ($LogsRoot) { Write-Host "  Logs:     $LogsRoot" -ForegroundColor Gray }
  Write-Host ""
  Write-Host "Check status: Invoke-RestMethod http://localhost:$Port/api/v1/state"
  Write-Host "Stop:         taskkill /F /IM symphony.exe"
} else {
  Write-Host "Starting... Press Ctrl+C to stop." -ForegroundColor Yellow
  Write-Host "  Command: $symphonyExe $fullArgs" -ForegroundColor Gray
  Write-Host ""

  if (Test-Path $symphonyExe) {
    & $symphonyExe $argsList
  } else {
    Write-Host "Escript not found at $symphonyExe, falling back to mix run..." -ForegroundColor Yellow
    mise x -- mix run -- $AckFlag
  }
}
