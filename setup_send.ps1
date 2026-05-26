# setup_send.ps1
# Interactive helper for building queue.json and scheduling a WhatsApp send.

param(
    [switch]$NoSchedule
)

$ErrorActionPreference = "Stop"

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$QueueDir = Join-Path $ProjectDir "queues"
$ScheduleScript = Join-Path $ProjectDir "schedule_send.ps1"
New-Item -ItemType Directory -Force -Path $QueueDir | Out-Null

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Read-Required {
    param(
        [string]$Prompt,
        [string]$ErrorMessage = "This cannot be blank."
    )

    while ($true) {
        $Value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return $Value.Trim()
        }

        Write-Host $ErrorMessage -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )

    $Suffix = if ($Default) { "Y/n" } else { "y/N" }
    while ($true) {
        $Value = Read-Host "$Prompt ($Suffix)"
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $Default
        }

        switch -Regex ($Value.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Host "Enter y or n." -ForegroundColor Yellow }
        }
    }
}

function Split-CommaList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split ',' |
            ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
            Where-Object { $_ -ne "" }
    )
}

function Normalize-NameKey {
    param([string]$Value)

    return (($Value -replace '[^A-Za-z0-9]+', ' ').Trim().ToLowerInvariant() -replace '\s+', ' ')
}

function Normalize-AttachmentPath {
    param([string]$Value)

    $PathValue = $Value.Trim()
    if ($PathValue -match '^(?i:cd)\s+(.+)$') {
        $PathValue = $Matches[1].Trim()
    }

    return $PathValue.Trim('"').Trim("'").Trim()
}

function Convert-ToWhatsAppText {
    param([string]$Text)

    $Converted = $Text
    $Converted = [regex]::Replace($Converted, '\*\*(.+?)\*\*', '*$1*')
    $Converted = [regex]::Replace($Converted, '__(.+?)__', '_$1_')
    return $Converted
}

function Read-ClipboardText {
    if ($env:WHATSAPP_SCHED_TEST_CLIPBOARD) {
        return $env:WHATSAPP_SCHED_TEST_CLIPBOARD
    }

    $ClipboardValue = $null

    try {
        $ClipboardValue = Get-Clipboard -Raw -ErrorAction Stop
    } catch {
        $ClipboardValue = $null
    }

    if ($null -eq $ClipboardValue) {
        try {
            $ClipboardLines = @(Get-Clipboard -ErrorAction Stop)
            if ($ClipboardLines.Count -gt 0) {
                $ClipboardValue = $ClipboardLines -join "`n"
            }
        } catch {
            $ClipboardValue = $null
        }
    }

    if ($null -eq $ClipboardValue) {
        try {
            Add-Type -AssemblyName PresentationCore -ErrorAction Stop
            $ClipboardValue = [Windows.Clipboard]::GetText()
        } catch {
            $ClipboardValue = $null
        }
    }

    if ($null -eq $ClipboardValue) {
        return $null
    }

    return [string]$ClipboardValue
}

function Read-Message {
    Write-Host "Message input options:" -ForegroundColor Cyan
    Write-Host "  paste one line     Type or paste text, then press Enter."
    Write-Host "  clip               Copy text first, then type clip here."
    Write-Host "  multi-line         Start with <<< and end with >>>."
    Write-Host "Markdown shortcut: **bold** -> *bold*, __italic__ -> _italic_." -ForegroundColor DarkGray

    while ($true) {
        $FirstLine = Read-Host "Message / clip / <<<"
        if ([string]::IsNullOrWhiteSpace($FirstLine)) {
            Write-Host "Message cannot be blank." -ForegroundColor Yellow
            continue
        }

        $TrimmedFirstLine = $FirstLine.Trim()
        if ($TrimmedFirstLine.ToLowerInvariant() -eq "clip") {
            $ClipboardText = Read-ClipboardText

            if ($null -eq $ClipboardText) {
                Write-Host "Clipboard did not return text. Copy plain text and try clip again, or use <<< and >>>." -ForegroundColor Yellow
                continue
            }

            $ClipboardText = $ClipboardText.Trim()
            if (-not [string]::IsNullOrWhiteSpace($ClipboardText)) {
                return $ClipboardText
            }

            Write-Host "Clipboard is empty or only whitespace." -ForegroundColor Yellow
            continue
        }

        if (-not $TrimmedFirstLine.StartsWith("<<<")) {
            return $TrimmedFirstLine
        }

        $Lines = @()
        $AfterStart = $TrimmedFirstLine.Substring(3)
        if ($AfterStart.EndsWith(">>>")) {
            $InlineMessage = $AfterStart.Substring(0, $AfterStart.Length - 3).Trim()
            if (-not [string]::IsNullOrWhiteSpace($InlineMessage)) {
                return $InlineMessage
            }
        }

        if (-not [string]::IsNullOrEmpty($AfterStart)) {
            $Lines += $AfterStart
        }

        while ($true) {
            $Line = Read-Host
            if ($Line -eq ">>>") {
                break
            }
            if ($Line.TrimEnd().EndsWith(">>>")) {
                $Lines += $Line.TrimEnd().Substring(0, $Line.TrimEnd().Length - 3)
                break
            }
            $Lines += $Line
        }

        $Message = ($Lines -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            return $Message
        }

        Write-Host "Message cannot be blank." -ForegroundColor Yellow
    }
}

function Read-Time {
    while ($true) {
        $Time = Read-Required "Send time, 24-hour HH:MM, example 9:00, 09:00, or 21:30"
        if ($Time -match '^(\d{1,2}):(\d{2})$') {
            $Hour = [int]$Matches[1]
            $Minute = [int]$Matches[2]

            if ($Hour -ge 0 -and $Hour -le 23 -and $Minute -ge 0 -and $Minute -le 59) {
                return ('{0:D2}:{1:D2}' -f $Hour, $Minute)
            }

            Write-Host "Invalid time. Use 0:00 through 23:59." -ForegroundColor Yellow
            continue
        }

        Write-Host "Invalid time format. Use H:MM or HH:MM." -ForegroundColor Yellow
    }
}

function Read-RecipientCount {
    while ($true) {
        $RawCount = Read-Required "How many people do you want to send this message to"
        $Count = 0
        if ([int]::TryParse($RawCount, [ref]$Count) -and $Count -gt 0) {
            return $Count
        }

        Write-Host "Enter a whole number greater than 0." -ForegroundColor Yellow
    }
}

function Read-Recipients {
    param([int]$ExpectedCount)

    while ($true) {
        $RawNames = Read-Required "Recipient names, comma-separated, example: mike smith, jane doe"
        $Names = Split-CommaList $RawNames

        if ($Names.Count -eq $ExpectedCount) {
            return $Names
        }

        Write-Host "You entered $($Names.Count) names, but said $ExpectedCount people." -ForegroundColor Yellow
        $UseAnyway = Read-YesNo "Use these names anyway" $false
        if ($UseAnyway -and $Names.Count -gt 0) {
            return $Names
        }
    }
}

function Read-PhoneMappings {
    Write-Host "This tool first looks for recipients in your existing WhatsApp chats."
    Write-Host "If everyone already has a chat, answer n." -ForegroundColor DarkGray
    Write-Host "If anyone does not have a chat yet, answer y and add only those people by phone." -ForegroundColor DarkGray

    $HasNewContacts = Read-YesNo "Any recipients missing from your WhatsApp chats" $false
    if (-not $HasNewContacts) {
        return @()
    }

    Write-Host ""
    Write-Host "Phone-only recipients."
    Write-Host "Enter only people who are not already in your WhatsApp chats."
    Write-Host "Format: name=number, comma-separated."
    Write-Host "Example: jane doe=15551234567, mike smith=15557654321"
    Write-Host "For US numbers, 10 digits are accepted and 1 will be added automatically."

    while ($true) {
        $RawMappings = Read-Required "Phone mappings"
        $Mappings = Split-CommaList $RawMappings
        $HadError = $false
        $ParsedMappings = @()

        foreach ($Mapping in $Mappings) {
            $Parts = $Mapping -split '=', 2
            if ($Parts.Count -ne 2) {
                Write-Host "Could not read mapping: $Mapping" -ForegroundColor Yellow
                $HadError = $true
                continue
            }

            $Name = $Parts[0].Trim()
            $Phone = $Parts[1].Trim()
            if ($Name -eq "" -or $Phone -eq "") {
                Write-Host "Invalid mapping: $Mapping" -ForegroundColor Yellow
                $HadError = $true
                continue
            }

            $ParsedMappings += [pscustomobject]@{
                Name = $Name
                Phone = $Phone
            }
        }

        if (-not $HadError) {
            return $ParsedMappings
        }

        Write-Host "Try the phone mappings again." -ForegroundColor Yellow
    }
}

function Build-PhoneMap {
    param(
        [string[]]$Recipients,
        [object[]]$PhoneMappings
    )

    $PhoneMap = @{}
    $RecipientByKey = @{}
    foreach ($Recipient in $Recipients) {
        $Key = Normalize-NameKey $Recipient
        if ($Key -ne "" -and -not $RecipientByKey.ContainsKey($Key)) {
            $RecipientByKey[$Key] = $Recipient
        }
    }

    foreach ($Mapping in $PhoneMappings) {
        $NameKey = Normalize-NameKey $Mapping.Name
        if (-not $RecipientByKey.ContainsKey($NameKey)) {
            Write-Host "Phone mapping name '$($Mapping.Name)' is not in the final recipient list." -ForegroundColor Yellow
            Write-Host "Final recipients are: $($Recipients -join ', ')" -ForegroundColor Yellow
            Write-Host "Add '$($Mapping.Name)' to the recipient names, or remove that phone mapping and run again." -ForegroundColor Yellow
            exit 1
        }

        $MatchedRecipient = $RecipientByKey[$NameKey]
        $PhoneMap[$MatchedRecipient] = $Mapping.Phone
    }

    return $PhoneMap
}

function Read-Attachments {
    Write-Host "Paste full file paths separated by commas."
    Write-Host "Blank or n means no attachments." -ForegroundColor DarkGray
    $RawFiles = Read-Host "Files"
    if ([string]::IsNullOrWhiteSpace($RawFiles) -or $RawFiles.Trim().ToLowerInvariant() -eq "n") {
        return @()
    }

    $Files = @(Split-CommaList $RawFiles | ForEach-Object { Normalize-AttachmentPath $_ } | Where-Object { $_ -ne "" })
    $MissingFiles = @($Files | Where-Object { -not (Test-Path -LiteralPath $_) })

    if ($MissingFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "These files do not exist right now:" -ForegroundColor Yellow
        foreach ($MissingFile in $MissingFiles) {
            Write-Host "  $MissingFile" -ForegroundColor Yellow

            $Directory = Split-Path -Parent $MissingFile
            $Leaf = Split-Path -Leaf $MissingFile
            if ($Directory -and (Test-Path -LiteralPath $Directory) -and $Leaf.Length -gt 0) {
                $PrefixLength = [Math]::Min(4, $Leaf.Length)
                $Prefix = $Leaf.Substring(0, $PrefixLength)
                $SimilarFiles = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$Prefix*" } |
                    Select-Object -First 5)

                if ($SimilarFiles.Count -gt 0) {
                    Write-Host "  Similar files in that folder:" -ForegroundColor Yellow
                    $SimilarFiles | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Yellow }
                }
            }
        }

        Write-Host "Fix the attachment path or leave attachments blank." -ForegroundColor Yellow
        return (Read-Attachments)
    }

    return $Files
}

Clear-Host
Write-Host "WhatsApp Scheduled Messenger" -ForegroundColor Cyan
Write-Host "Build a WhatsApp message queue, schedule it with Windows Task Scheduler,"
Write-Host "and send later through your saved WhatsApp Web session."
Write-Host ""
Write-Host "Important:" -ForegroundColor DarkGray
Write-Host "  The computer must be on, awake, logged in, and connected to the internet at send time." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Overnight desktop/laptop setup:" -ForegroundColor DarkGray
Write-Host "  Leave the computer powered on." -ForegroundColor DarkGray
Write-Host "  Stay signed in to Windows." -ForegroundColor DarkGray
Write-Host "  Set sleep and hibernate to Never." -ForegroundColor DarkGray
Write-Host "  Desktop: you can turn the monitor off." -ForegroundColor DarkGray
Write-Host "  Laptop: plug it in, set lid close to Do nothing, or leave the lid open." -ForegroundColor DarkGray
Write-Host "  Laptop: you can turn the screen off." -ForegroundColor DarkGray
Write-Host "  Use the shutdown option here if you want the computer to power off after sending." -ForegroundColor DarkGray

Write-Section "Recipients"
$RecipientCount = Read-RecipientCount
$PhoneMappings = @(Read-PhoneMappings)
$Recipients = @(Read-Recipients $RecipientCount)
$PhoneMap = Build-PhoneMap $Recipients $PhoneMappings

Write-Section "Message"
$RawMessage = Read-Message
$Message = Convert-ToWhatsAppText $RawMessage

Write-Section "Attachments"
$Attachments = @(Read-Attachments)

Write-Section "Schedule"
$Time = Read-Time
$Shutdown = Read-YesNo "Shut down the computer after all queued messages send" $false
$QueueStamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$QueuePath = Join-Path $QueueDir "queue-$QueueStamp.json"

$Queue = @()
for ($Index = 0; $Index -lt $Recipients.Count; $Index++) {
    $Recipient = $Recipients[$Index]
    $Item = [ordered]@{
        recipient = $Recipient
        message = $Message
        attachments = @($Attachments)
        shutdown = ($Shutdown -and $Index -eq ($Recipients.Count - 1))
    }

    if ($PhoneMap.ContainsKey($Recipient)) {
        $Item["phone"] = $PhoneMap[$Recipient]
    }

    $Queue += [pscustomobject]$Item
}

$QueueJson = ConvertTo-Json -InputObject @($Queue) -Depth 5
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($QueuePath, "$QueueJson`r`n", $Utf8NoBom)

Write-Host ""
Write-Host "Queue saved:" -ForegroundColor Green
Write-Host "  File      : $QueuePath"
Write-Host "  Recipients: $($Recipients.Count)"
Write-Host "  Files     : $($Attachments.Count)"
Write-Host "  Shutdown  : $Shutdown"
Write-Host ""

if ($NoSchedule) {
    Write-Host "NoSchedule enabled. Task was not scheduled." -ForegroundColor Yellow
    exit 0
}

& $ScheduleScript $Time -QueueFile $QueuePath
exit $LASTEXITCODE
