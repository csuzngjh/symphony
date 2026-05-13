param(
  [switch]$NoWait
)

$SymphonyDir = "D:\Code\symphony\elixir"
$AckFlag = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Symphony Agent Orchestrator         ║" -ForegroundColor Cyan
Write-Host "║  轮询 Linear → 自动派发 Issue → 等结果  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Set-Location -LiteralPath $SymphonyDir

if ($NoWait) {
  Start-Process -WindowStyle Hidden -FilePath "mise" -ArgumentList "x -- mix run -- $AckFlag"
  Write-Host "Symphony 已在后台启动，查看日志：$SymphonyDir\log\symphony.log" -ForegroundColor Green
} else {
  Write-Host "启动中... 按 Ctrl+C 停止" -ForegroundColor Yellow
  mise x -- mix run -- $AckFlag
}
