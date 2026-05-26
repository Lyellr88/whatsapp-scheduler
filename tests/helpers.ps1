$global:WhatsAppSchedulerTestProjectDir = Split-Path -Parent $PSScriptRoot
$global:WhatsAppSchedulerTestTaskPrefix = "WhatsAppQueueSend-Test-"
$global:WhatsAppSchedulerTestLockDir = Join-Path $global:WhatsAppSchedulerTestProjectDir ".run.lock"

function Invoke-RepoPowerShell {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptPath,

        [string[]]$Arguments = @()
    )

    Push-Location $global:WhatsAppSchedulerTestProjectDir
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
    } finally {
        Pop-Location
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $text
        StdErr = ""
        Output = $text
    }
}

function New-TestQueueFile {
    param(
        [string]$Name = "test-$([guid]::NewGuid().ToString('N')).json",
        [object[]]$Items = @()
    )

    $queueDir = Join-Path $global:WhatsAppSchedulerTestProjectDir "queues"
    New-Item -ItemType Directory -Force -Path $queueDir | Out-Null
    $path = Join-Path $queueDir $Name
    $json = ConvertTo-Json -InputObject @($Items) -Depth 5
    [System.IO.File]::WriteAllText($path, "$json`r`n", [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Remove-TestQueueFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $queueRoot = [System.IO.Path]::GetFullPath((Join-Path $global:WhatsAppSchedulerTestProjectDir "queues"))
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $leaf = Split-Path -Leaf $fullPath
    if ($fullPath.StartsWith($queueRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        ($leaf -like "test-*.json" -or $leaf -like "queue-*.json") -and
        (Test-Path -LiteralPath $fullPath)) {
        Remove-Item -LiteralPath $fullPath -Force
    }
}

function New-TestLock {
    param(
        [datetime]$StartedAt = (Get-Date),
        [string[]]$ExtraLines = @()
    )

    if (Test-Path -LiteralPath $global:WhatsAppSchedulerTestLockDir) {
        throw "Refusing to create test lock because .run.lock already exists."
    }

    New-Item -ItemType Directory -Path $global:WhatsAppSchedulerTestLockDir | Out-Null
    $lines = @(
        "StartedAt=$($StartedAt.ToString('o'))",
        "User=$env:USERNAME",
        "TestOwner=WhatsAppQueueSend-Test",
        "ProcessId=$PID"
    ) + $ExtraLines
    Set-Content -LiteralPath (Join-Path $global:WhatsAppSchedulerTestLockDir "owner.txt") -Value $lines
}

function Remove-TestLock {
    if (-not (Test-Path -LiteralPath $global:WhatsAppSchedulerTestLockDir)) {
        return
    }

    $ownerPath = Join-Path $global:WhatsAppSchedulerTestLockDir "owner.txt"
    $ownerText = if (Test-Path -LiteralPath $ownerPath) {
        Get-Content -LiteralPath $ownerPath -Raw
    } else {
        ""
    }

    if ($ownerText -like "*WhatsAppQueueSend-Test*" -or $ownerText -like "*TestOwner=*") {
        Remove-Item -LiteralPath $global:WhatsAppSchedulerTestLockDir -Recurse -Force
    }
}

function Remove-TestTask {
    param([string]$TaskName)

    if ([string]::IsNullOrWhiteSpace($TaskName) -or $TaskName -notlike "$global:WhatsAppSchedulerTestTaskPrefix*") {
        return
    }

    schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
}

function Get-ScheduledTaskDetails {
    param([string]$TaskName)

    $output = schtasks /query /tn $TaskName /fo LIST /v 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}
