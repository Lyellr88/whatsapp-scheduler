$ErrorActionPreference = "Stop"

Describe "run_queue.ps1 lock behavior" {
    BeforeAll {
        . "$PSScriptRoot\helpers.ps1"
        $script:ProjectDir = $global:WhatsAppSchedulerTestProjectDir
        $script:LockDir = $global:WhatsAppSchedulerTestLockDir
        $script:Runner = Join-Path $script:ProjectDir "run_queue.ps1"
    }

    AfterEach {
        Remove-TestLock
        if ($script:QueueUnderTest) {
            Remove-TestQueueFile $script:QueueUnderTest
            $script:QueueUnderTest = $null
        }
    }

    It "acquires and releases the lock for an empty queue without touching auth state" {
        if (Test-Path -LiteralPath $script:LockDir) {
            Set-ItResult -Skipped -Because ".run.lock already exists"
            return
        }

        $script:QueueUnderTest = New-TestQueueFile -Items @()
        $beforeAuth = if (Test-Path -LiteralPath (Join-Path $script:ProjectDir ".wwebjs_auth")) {
            (Get-Item -LiteralPath (Join-Path $script:ProjectDir ".wwebjs_auth")).LastWriteTimeUtc
        } else {
            $null
        }

        $result = Invoke-RepoPowerShell -ScriptPath $script:Runner -Arguments @("-QueueFile", $script:QueueUnderTest)

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:LockDir | Should -BeFalse
        (Get-Content -LiteralPath $script:QueueUnderTest -Raw | ConvertFrom-Json).Count | Should -Be 0
        if ($null -ne $beforeAuth) {
            (Get-Item -LiteralPath (Join-Path $script:ProjectDir ".wwebjs_auth")).LastWriteTimeUtc | Should -Be $beforeAuth
        }
    }

    It "skips when a fresh lock exists and preserves the queue file" {
        if (Test-Path -LiteralPath $script:LockDir) {
            Set-ItResult -Skipped -Because ".run.lock already exists"
            return
        }

        $item = [pscustomobject]@{ recipient = "Test Recipient"; message = "Do not send"; attachments = @(); shutdown = $false }
        $script:QueueUnderTest = New-TestQueueFile -Items @($item)
        $before = Get-Content -LiteralPath $script:QueueUnderTest -Raw
        New-TestLock

        $result = Invoke-RepoPowerShell -ScriptPath $script:Runner -Arguments @("-QueueFile", $script:QueueUnderTest)

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $script:QueueUnderTest -Raw) | Should -Be $before
        Test-Path -LiteralPath $script:LockDir | Should -BeTrue
    }

    It "treats malformed owner files as active and preserves the queue file" {
        if (Test-Path -LiteralPath $script:LockDir) {
            Set-ItResult -Skipped -Because ".run.lock already exists"
            return
        }

        $item = [pscustomobject]@{ recipient = "Test Recipient"; message = "Do not send"; attachments = @(); shutdown = $false }
        $script:QueueUnderTest = New-TestQueueFile -Items @($item)
        $before = Get-Content -LiteralPath $script:QueueUnderTest -Raw
        New-Item -ItemType Directory -Path $script:LockDir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:LockDir "owner.txt") -Value @("StartedAt=not-a-date", "TestOwner=WhatsAppQueueSend-Test")

        $result = Invoke-RepoPowerShell -ScriptPath $script:Runner -Arguments @("-QueueFile", $script:QueueUnderTest)

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $script:QueueUnderTest -Raw) | Should -Be $before
        Test-Path -LiteralPath $script:LockDir | Should -BeTrue
    }

    It "removes stale locks, runs, and releases the lock" {
        if (Test-Path -LiteralPath $script:LockDir) {
            Set-ItResult -Skipped -Because ".run.lock already exists"
            return
        }

        $script:QueueUnderTest = New-TestQueueFile -Items @()
        New-TestLock -StartedAt (Get-Date).AddMinutes(-31)

        $result = Invoke-RepoPowerShell -ScriptPath $script:Runner -Arguments @("-QueueFile", $script:QueueUnderTest)

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:LockDir | Should -BeFalse
    }

    It "releases the lock when the queue file is missing" {
        if (Test-Path -LiteralPath $script:LockDir) {
            Set-ItResult -Skipped -Because ".run.lock already exists"
            return
        }

        $missingQueue = Join-Path (Join-Path $script:ProjectDir "queues") "test-missing-$([guid]::NewGuid().ToString('N')).json"

        $result = Invoke-RepoPowerShell -ScriptPath $script:Runner -Arguments @("-QueueFile", $missingQueue)

        $result.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $script:LockDir | Should -BeFalse
    }
}
