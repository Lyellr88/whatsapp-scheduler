# run_queue.ps1
# Invoked by Windows Task Scheduler. Writes a timestamped log, then runs the queue sender.

param(
    [string]$QueueFile = ""
)

$ErrorActionPreference = "Continue"

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ProjectDir "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$StartedAt = Get-Date
$Stamp = $StartedAt.ToString("yyyyMMdd-HHmmss")
$LogFile = Join-Path $LogDir "whatsapp-queue-$Stamp.log"
$LockDir = Join-Path $ProjectDir ".run.lock"
$LockMaxAgeMinutes = 30
$ScriptPath = Join-Path $ProjectDir "send_whatsapp.js"
if ([string]::IsNullOrWhiteSpace($QueueFile)) {
    $QueuePath = Join-Path $ProjectDir "queue.json"
} else {
    $QueuePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($QueueFile)
}

function Write-Log {
    param([string]$Message)
    $Line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogFile -Value $Line
}

function Resolve-NodePath {
    $Candidates = @()

    try {
        $Command = Get-Command node.exe -ErrorAction Stop
        if ($Command -and $Command.Source) {
            $Candidates += $Command.Source
        }
    } catch {}

    $Candidates += @(
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe"),
        "C:\Program Files\nodejs\node.exe"
    )

    foreach ($Candidate in ($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $Candidate) {
            return $Candidate
        }
    }

    return $null
}

function Get-LockStartedAt {
    param([string]$OwnerPath)

    if (-not (Test-Path -LiteralPath $OwnerPath)) {
        return $null
    }

    $StartedLine = Get-Content -LiteralPath $OwnerPath |
        Where-Object { $_ -like "StartedAt=*" } |
        Select-Object -First 1

    if (-not $StartedLine) {
        return $null
    }

    $RawValue = $StartedLine.Substring("StartedAt=".Length)
    try {
        return [datetime]::Parse($RawValue, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

$LockAcquired = $false

try {
    $NodePath = Resolve-NodePath

    Write-Log "Starting WhatsApp scheduled queue run."
    Write-Log "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "ProjectDir: $ProjectDir"
    Write-Log "NodePath: $NodePath"
    Write-Log "ScriptPath: $ScriptPath"
    Write-Log "QueuePath: $QueuePath"

    try {
        New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
        $LockAcquired = $true
        $LockInfo = @(
            "StartedAt=$($StartedAt.ToString("o"))"
            "User=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
            "QueuePath=$QueuePath"
            "LogFile=$LogFile"
            "ProcessId=$PID"
        )
        Set-Content -LiteralPath (Join-Path $LockDir "owner.txt") -Value $LockInfo
        Write-Log "Run lock acquired: $LockDir"
    } catch {
        $OwnerPath = Join-Path $LockDir "owner.txt"
        $LockStartedAt = Get-LockStartedAt $OwnerPath
        $IsStale = $false

        if ($null -ne $LockStartedAt) {
            $LockAgeMinutes = ((Get-Date) - $LockStartedAt).TotalMinutes
            $IsStale = $LockAgeMinutes -gt $LockMaxAgeMinutes
        }

        if ($IsStale) {
            Write-Log "Stale run lock detected. Removing lock older than $LockMaxAgeMinutes minutes."
            if (Test-Path -LiteralPath $OwnerPath) {
                Get-Content -LiteralPath $OwnerPath | ForEach-Object { Write-Log "Stale lock owner: $_" }
            }
            Remove-Item -LiteralPath $LockDir -Recurse -Force
            New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
            $LockAcquired = $true
            $LockInfo = @(
                "StartedAt=$($StartedAt.ToString("o"))"
                "User=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
                "QueuePath=$QueuePath"
                "LogFile=$LogFile"
                "ProcessId=$PID"
            )
            Set-Content -LiteralPath (Join-Path $LockDir "owner.txt") -Value $LockInfo
            Write-Log "Run lock acquired after stale lock cleanup: $LockDir"
        } else {
            if ($null -eq $LockStartedAt) {
                Write-Log "Existing run lock has no readable StartedAt value. Treating it as active."
            }
            Write-Log "Another WhatsApp queue run is already active. Skipping this run."
            if (Test-Path -LiteralPath $OwnerPath) {
                Get-Content -LiteralPath $OwnerPath | ForEach-Object { Write-Log "Lock owner: $_" }
            }
            Write-Log "Queue was not modified: $QueuePath"
            exit 0
        }
    }

    if (-not (Test-Path -LiteralPath $NodePath)) {
        Write-Log "ERROR: node.exe not found at $NodePath"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Log "ERROR: send_whatsapp.js not found at $ScriptPath"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $QueuePath)) {
        Write-Log "ERROR: queue.json not found at $QueuePath"
        exit 1
    }

    try {
        $Queue = Get-Content -LiteralPath $QueuePath -Raw | ConvertFrom-Json
        $QueueItems = @($Queue)
        $FirstItem = if ($QueueItems.Count -gt 0) { $QueueItems[0] } else { $null }
        $MessageLength = if ($null -ne $FirstItem -and $null -ne $FirstItem.message) { $FirstItem.message.Length } else { 0 }
        $AttachmentCount = if ($null -ne $FirstItem -and $null -ne $FirstItem.attachments) { @($FirstItem.attachments).Count } else { 0 }
        Write-Log "Queue item count: $($QueueItems.Count)"
        Write-Log "First recipient: $($FirstItem.recipient)"
        Write-Log "First message length: $MessageLength"
        Write-Log "First attachment count: $AttachmentCount"
        Write-Log "First shutdown: $($FirstItem.shutdown)"
    } catch {
        Write-Log "ERROR: queue.json could not be parsed: $($_.Exception.Message)"
        exit 1
    }

    $StdOutFile = Join-Path $LogDir "whatsapp-queue-$Stamp.stdout.tmp"
    $StdErrFile = Join-Path $LogDir "whatsapp-queue-$Stamp.stderr.tmp"

    Push-Location $ProjectDir
    try {
        $env:PATH = "C:\Program Files\nodejs;$env:PATH"
        $Process = Start-Process `
            -FilePath $NodePath `
            -ArgumentList "`"$ScriptPath`" --from-queue --queue-file `"$QueuePath`"" `
            -WorkingDirectory $ProjectDir `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $StdOutFile `
            -RedirectStandardError $StdErrFile
        $ExitCode = $Process.ExitCode
    } finally {
        Pop-Location
    }

    if (Test-Path -LiteralPath $StdOutFile) {
        Get-Content -LiteralPath $StdOutFile | ForEach-Object { Write-Log "stdout: $_" }
    }

    if (Test-Path -LiteralPath $StdErrFile) {
        Get-Content -LiteralPath $StdErrFile | ForEach-Object { Write-Log "stderr: $_" }
    }

    foreach ($TempFile in @($StdOutFile, $StdErrFile)) {
        if ((Test-Path -LiteralPath $TempFile) -and ($TempFile.StartsWith($LogDir))) {
            Remove-Item -LiteralPath $TempFile -Force
        }
    }

    Write-Log "Node process exited with code $ExitCode."
    exit $ExitCode
} catch {
    Write-Log "ERROR: Unhandled runner failure: $($_.Exception.Message)"
    exit 1
} finally {
    if ($LockAcquired -and (Test-Path -LiteralPath $LockDir)) {
        Remove-Item -LiteralPath $LockDir -Recurse -Force
        Write-Log "Run lock released."
    }
}
