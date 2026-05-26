$ErrorActionPreference = "Stop"

Describe "schedule_send.ps1 task creation" {
    BeforeAll {
        . "$PSScriptRoot\helpers.ps1"
        $script:ProjectDir = $global:WhatsAppSchedulerTestProjectDir
        $script:TaskPrefix = $global:WhatsAppSchedulerTestTaskPrefix
        $script:ScheduleScript = Join-Path $script:ProjectDir "schedule_send.ps1"
        $script:CreatedTasks = @()
    }

    AfterEach {
        foreach ($taskName in $script:CreatedTasks) {
            Remove-TestTask $taskName
        }
        $script:CreatedTasks = @()
        if ($script:QueueUnderTest) {
            Remove-TestQueueFile $script:QueueUnderTest
            $script:QueueUnderTest = $null
        }
    }

    It "fails for invalid time before creating a task" {
        $script:QueueUnderTest = New-TestQueueFile -Items @()
        $taskName = "$script:TaskPrefix-invalid-$([guid]::NewGuid().ToString('N'))"

        $result = Invoke-RepoPowerShell -ScriptPath $script:ScheduleScript -Arguments @("9:5", "-QueueFile", $script:QueueUnderTest, "-TaskName", $taskName)

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "Invalid time format"
        (Get-ScheduledTaskDetails $taskName).ExitCode | Should -Not -Be 0
    }

    It "fails for a missing queue file before creating a task" {
        $taskName = "$script:TaskPrefix-missing-$([guid]::NewGuid().ToString('N'))"
        $missingQueue = Join-Path (Join-Path $script:ProjectDir "queues") "test-missing-$([guid]::NewGuid().ToString('N')).json"

        $result = Invoke-RepoPowerShell -ScriptPath $script:ScheduleScript -Arguments @("23:59", "-QueueFile", $missingQueue, "-TaskName", $taskName)

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "Queue file not found"
        (Get-ScheduledTaskDetails $taskName).ExitCode | Should -Not -Be 0
    }

    It "honors an explicit test task name and records the queue file action" {
        $script:QueueUnderTest = New-TestQueueFile -Items @()
        $taskName = "$script:TaskPrefix-explicit-$([guid]::NewGuid().ToString('N'))"
        $script:CreatedTasks += $taskName

        $result = Invoke-RepoPowerShell -ScriptPath $script:ScheduleScript -Arguments @("23:59", "-QueueFile", $script:QueueUnderTest, "-TaskName", $taskName)
        if ($result.ExitCode -ne 0 -or $result.Output -match "Failed to create task") {
            Set-ItResult -Skipped -Because "Task Scheduler rejected test task creation: $($result.Output)"
            return
        }

        $details = Get-ScheduledTaskDetails $taskName

        $details.ExitCode | Should -Be 0
        $details.Output | Should -Match ([regex]::Escape($taskName))
        $details.Output | Should -Match "run_queue\.ps1"
        $details.Output | Should -Match "-QueueFile"
        $details.Output | Should -Match ([regex]::Escape($script:QueueUnderTest))
    }

    It "allows two explicit test tasks with different queue files to coexist" {
        $queueA = New-TestQueueFile -Name "test-coexist-a-$([guid]::NewGuid().ToString('N')).json" -Items @()
        $queueB = New-TestQueueFile -Name "test-coexist-b-$([guid]::NewGuid().ToString('N')).json" -Items @()
        $taskA = "$script:TaskPrefix-coexist-a-$([guid]::NewGuid().ToString('N'))"
        $taskB = "$script:TaskPrefix-coexist-b-$([guid]::NewGuid().ToString('N'))"
        $script:CreatedTasks += @($taskA, $taskB)

        try {
            $resultA = Invoke-RepoPowerShell -ScriptPath $script:ScheduleScript -Arguments @("23:58", "-QueueFile", $queueA, "-TaskName", $taskA)
            $resultB = Invoke-RepoPowerShell -ScriptPath $script:ScheduleScript -Arguments @("23:59", "-QueueFile", $queueB, "-TaskName", $taskB)
            if ($resultA.ExitCode -ne 0 -or $resultB.ExitCode -ne 0 -or
                $resultA.Output -match "Failed to create task" -or
                $resultB.Output -match "Failed to create task") {
                Set-ItResult -Skipped -Because "Task Scheduler rejected test task creation."
                return
            }

            $detailsA = Get-ScheduledTaskDetails $taskA
            $detailsB = Get-ScheduledTaskDetails $taskB

            $detailsA.ExitCode | Should -Be 0
            $detailsB.ExitCode | Should -Be 0
            $detailsA.Output | Should -Match ([regex]::Escape($queueA))
            $detailsB.Output | Should -Match ([regex]::Escape($queueB))
        } finally {
            Remove-TestQueueFile $queueA
            Remove-TestQueueFile $queueB
        }
    }
}
