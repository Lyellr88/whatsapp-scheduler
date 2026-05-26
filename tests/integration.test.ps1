$ErrorActionPreference = "Stop"

Describe "WhatsApp scheduler integration smoke tests" {
    BeforeAll {
        . "$PSScriptRoot\helpers.ps1"
        $script:ProjectDir = $global:WhatsAppSchedulerTestProjectDir
        $script:LockDir = $global:WhatsAppSchedulerTestLockDir
        $script:TaskPrefix = $global:WhatsAppSchedulerTestTaskPrefix
        $script:NodeCli = Join-Path $script:ProjectDir "whatsapp-sched.js"
        $script:Runner = Join-Path $script:ProjectDir "run_queue.ps1"
        $script:ScheduleScript = Join-Path $script:ProjectDir "schedule_send.ps1"
        $script:CreatedTasks = @()
        $script:CreatedQueues = @()
    }

    AfterEach {
        foreach ($taskName in $script:CreatedTasks) {
            Remove-TestTask $taskName
        }
        $script:CreatedTasks = @()

        foreach ($queue in $script:CreatedQueues) {
            Remove-TestQueueFile $queue
        }
        $script:CreatedQueues = @()
        Remove-TestLock
    }

    It "CLI --no-schedule writes a queue file without creating a scheduled task" {
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

        $result = & node $script:NodeCli "23:59" "WhatsAppQueueSend Test Recipient" "Hello **test**" "--no-schedule" 2>&1
        $exitCode = $LASTEXITCODE
        $output = $result -join "`n"

        $exitCode | Should -Be 0
        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName
        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        @($queue).Count | Should -Be 1
        $queue[0].recipient | Should -Be "WhatsAppQueueSend Test Recipient"
        $queue[0].message | Should -Be "Hello *test*"
        $output | Should -Match "NoSchedule enabled"
    }

    It "CLI missing attachment fails before queue file creation" {
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $missingAttachment = Join-Path $script:ProjectDir "tests\missing-attachment-$([guid]::NewGuid().ToString('N')).txt"

        $result = & node $script:NodeCli "23:59" "WhatsAppQueueSend Test Recipient" "Hello" "--file" $missingAttachment "--no-schedule" 2>&1
        $exitCode = $LASTEXITCODE
        $after = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

        $exitCode | Should -Not -Be 0
        ($result -join "`n") | Should -Match "Attachment validation failed"
        @($after | Where-Object { $before -notcontains $_ }).Count | Should -Be 0
    }

    It "TUI reports a missing attachment and requires a corrected or blank attachment entry" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $missingAttachment = Join-Path $script:ProjectDir "tests\missing-tui-attachment-$([guid]::NewGuid().ToString('N')).txt"
        $answers = @(
            "1",
            "n",
            "WhatsAppQueueSend Test Recipient",
            "Hello from TUI",
            $missingAttachment,
            "",
            "23:59",
            "n"
        )

        $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should -Be 0
        $text | Should -Match "These files do not exist right now"
        $text | Should -Match ([regex]::Escape($missingAttachment))

        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        @($queue).Count | Should -Be 1
        $queue[0].recipient | Should -Be "WhatsAppQueueSend Test Recipient"
        $queue[0].attachments.Count | Should -Be 0
    }

    It "TUI accepts normalized phone mappings for recipient names" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "1",
            "y",
            "mike-smith=+1 (555) 123-4567",
            "Mike   Smith",
            "Hello",
            "n",
            "23:59",
            "n"
        )

        $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should -Be 0
        $text | Should -Not -Match "not in the recipient list"

        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        $queue[0].recipient | Should -Be "Mike   Smith"
        $queue[0].phone | Should -Be "+1 (555) 123-4567"
    }

    It "TUI supports mixed chat-name and phone-number recipients" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "2",
            "y",
            "jane-doe=15551234567",
            "Mike Smith, Jane Doe",
            "Hello mixed recipients",
            "n",
            "23:59",
            "n"
        )

        $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should -Be 0
        $text | Should -Match "This tool first looks for recipients in your existing WhatsApp chats"

        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        @($queue).Count | Should -Be 2
        @($queue)[0].recipient | Should -Be "Mike Smith"
        @($queue)[0].PSObject.Properties.Name | Should -Not -Contain "phone"
        @($queue)[1].recipient | Should -Be "Jane Doe"
        @($queue)[1].phone | Should -Be "15551234567"
    }

    It "TUI accepts quoted attachment paths pasted with a leading cd command" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $attachment = Join-Path $script:ProjectDir "tests\fixture attachment $([guid]::NewGuid().ToString('N')).txt"
        Set-Content -LiteralPath $attachment -Value "fixture"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "1",
            "n",
            "WhatsAppQueueSend Test Recipient",
            "Hello",
            "cd `"$attachment`"",
            "23:59",
            "n"
        )

        try {
            $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
            $exitCode = $LASTEXITCODE
            $text = $output -join "`n"

            $exitCode | Should -Be 0
            $text | Should -Not -Match "These files do not exist right now"

            $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
                Where-Object { $before -notcontains $_.FullName } |
                Sort-Object LastWriteTimeUtc -Descending)
            $created.Count | Should -Be 1
            $script:CreatedQueues += $created[0].FullName

            $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
            $queue[0].attachments[0] | Should -Be $attachment
        } finally {
            Remove-Item -LiteralPath $attachment -Force -ErrorAction SilentlyContinue
        }
    }

    It "TUI supports multi-line messages using sentinel input" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "1",
            "n",
            "WhatsAppQueueSend Test Recipient",
            "<<<",
            "Line one with **bold**",
            "Line two with __italic__",
            ">>>",
            "n",
            "23:59",
            "n"
        )

        $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        $queue[0].message | Should -Be "Line one with *bold*`nLine two with _italic_"
    }

    It "TUI strips inline sentinel markers from a one-line pasted message" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "1",
            "n",
            "WhatsAppQueueSend Test Recipient",
            "<<<hello **there**>>>",
            "n",
            "23:59",
            "n"
        )

        $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        $queue[0].message | Should -Be "hello *there*"
    }

    It "TUI keeps pasted text after an opening sentinel on the same line" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "1",
            "n",
            "WhatsAppQueueSend Test Recipient",
            "<<<first pasted line",
            "second pasted line",
            ">>>",
            "n",
            "23:59",
            "n"
        )

        $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        $queue[0].message | Should -Be "first pasted line`nsecond pasted line"
    }

    It "TUI can read message text from clipboard mode" {
        $setupScript = Join-Path $script:ProjectDir "setup_send.ps1"
        $before = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $answers = @(
            "1",
            "n",
            "WhatsAppQueueSend Test Recipient",
            "clip",
            "n",
            "23:59",
            "n"
        )

        try {
            $env:WHATSAPP_SCHED_TEST_CLIPBOARD = "Clipboard **bold**`nSecond __line__"
            $output = $answers | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoSchedule 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Remove-Item Env:\WHATSAPP_SCHED_TEST_CLIPBOARD -ErrorAction SilentlyContinue
        }

        $exitCode | Should -Be 0
        $created = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "queues") -Filter "queue-*.json" |
            Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $created.Count | Should -Be 1
        $script:CreatedQueues += $created[0].FullName

        $queue = Get-Content -LiteralPath $created[0].FullName -Raw | ConvertFrom-Json
        $queue[0].message | Should -Be "Clipboard *bold*`nSecond _line_"
    }

    It "run_queue.ps1 with an empty test queue writes a log and exits successfully" {
        if (Test-Path -LiteralPath $script:LockDir) {
            Set-ItResult -Skipped -Because ".run.lock already exists"
            return
        }

        $queue = New-TestQueueFile -Items @()
        $script:CreatedQueues += $queue
        $beforeLogs = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "logs") -Filter "whatsapp-queue-*.log" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

        $result = Invoke-RepoPowerShell -ScriptPath $script:Runner -Arguments @("-QueueFile", $queue)

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:LockDir | Should -BeFalse
        $newLogs = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir "logs") -Filter "whatsapp-queue-*.log" |
            Where-Object { $beforeLogs -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
        $newLogs.Count | Should -BeGreaterOrEqual 1
        (Get-Content -LiteralPath $newLogs[0].FullName -Raw) | Should -Match "Queue item count: 0"
    }

    It "status command lists a test queue file without sending anything" {
        $queue = New-TestQueueFile -Name "test-status-$([guid]::NewGuid().ToString('N')).json" -Items @(
            [pscustomobject]@{ recipient = "WhatsAppQueueSend Test Recipient"; message = "Pending"; attachments = @(); shutdown = $false }
        )
        $script:CreatedQueues += $queue

        $result = & node $script:NodeCli "--status" 2>&1
        $exitCode = $LASTEXITCODE
        $output = $result -join "`n"

        $exitCode | Should -Be 0
        $output | Should -Match ([regex]::Escape((Split-Path -Leaf $queue)))
        $output | Should -Match "WhatsAppQueueSend Test Recipient"
    }

    It "schedule_send.ps1 creates and deletes an explicit test task" {
        $queue = New-TestQueueFile -Items @()
        $script:CreatedQueues += $queue
        $taskName = "$script:TaskPrefix-smoke-$([guid]::NewGuid().ToString('N'))"
        $script:CreatedTasks += $taskName

        $result = Invoke-RepoPowerShell -ScriptPath $script:ScheduleScript -Arguments @("23:59", "-QueueFile", $queue, "-TaskName", $taskName)
        if ($result.ExitCode -ne 0 -or $result.Output -match "Failed to create task") {
            Set-ItResult -Skipped -Because "Task Scheduler rejected test task creation: $($result.Output)"
            return
        }

        $details = Get-ScheduledTaskDetails $taskName
        $details.ExitCode | Should -Be 0
        $details.Output | Should -Match "-QueueFile"
        $details.Output | Should -Match ([regex]::Escape($queue))
    }
}
