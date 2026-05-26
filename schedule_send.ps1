# schedule_send.ps1
# Usage: .\schedule_send.ps1 09:00
# Registers a one-time Windows Task to send your queued WhatsApp message at the given time.
# Run this before bed after filling out queue.json.

param(
    [Parameter(Mandatory=$true)]
    [string]$Time,

    [string]$QueueFile = "",

    [string]$TaskName = ""
)

$ErrorActionPreference = "Continue"

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunnerPath = Join-Path $ProjectDir "run_queue.ps1"
$PowerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Validate time format
if ($Time -notmatch '^\d{2}:\d{2}$') {
    Write-Host "Invalid time format. Use HH:MM, e.g. 09:00" -ForegroundColor Red
    exit 1
}

# Figure out the correct date (if time has already passed today, schedule for tomorrow)
$Now         = Get-Date
$ScheduledDT = [datetime]::ParseExact((Get-Date -Format "yyyy-MM-dd") + " $Time", "yyyy-MM-dd HH:mm", $null)
if ($ScheduledDT -le $Now) {
    $ScheduledDT = $ScheduledDT.AddDays(1)
}

$DateStr = $ScheduledDT.ToString("MM/dd/yyyy")
$TimeStr = $ScheduledDT.ToString("HH:mm")

if ([string]::IsNullOrWhiteSpace($QueueFile)) {
    $QueueFile = Join-Path $ProjectDir "queue.json"
}

$ResolvedQueueFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($QueueFile)
if (-not (Test-Path -LiteralPath $ResolvedQueueFile)) {
    Write-Host "Queue file not found: $ResolvedQueueFile" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName = "WhatsAppQueueSend-$($ScheduledDT.ToString('yyyyMMdd-HHmmss'))-$((Get-Random -Maximum 9999).ToString('0000'))"
}

if (-not (Test-Path -LiteralPath $RunnerPath)) {
    Write-Host "Runner script not found: $RunnerPath" -ForegroundColor Red
    exit 1
}

# Create the task
$TaskCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -QueueFile "{2}"' -f $PowerShellPath, $RunnerPath, $ResolvedQueueFile
$Result = schtasks /create `
    /tn $TaskName `
    /tr $TaskCommand `
    /sc once `
    /sd $DateStr `
    /st $TimeStr `
    /ru $CurrentUser `
    /it `
    /f

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Scheduled!" -ForegroundColor Green
    Write-Host "  Task    : $TaskName"
    Write-Host "  Sends at: $($ScheduledDT.ToString('dddd, MMM d') ) at $TimeStr"
    Write-Host "  Queue   : $ResolvedQueueFile"
    Write-Host "  Runner  : $RunnerPath"
    Write-Host "  Logs    : $ProjectDir\logs"
    Write-Host ""
    Write-Host "To cancel before it runs:" -ForegroundColor Yellow
    Write-Host "  schtasks /delete /tn $TaskName /f"
} else {
    Write-Host "Failed to create task. Try running PowerShell as Administrator." -ForegroundColor Red
}
