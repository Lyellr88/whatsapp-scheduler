Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$pathsToSkip = @(
    "\\.git\\",
    "\\.codex\\",
    "\\docs\\",
    "\\node_modules\\",
    "\\.npm-cache\\",
    "\\.wwebjs_auth\\",
    "\\.wwebjs_cache\\",
    "\\logs\\",
    "\\queues\\"
)

function Test-SkippedPath {
    param([string]$FullName)

    foreach ($skip in $pathsToSkip) {
        if ($FullName -match $skip) {
            return $true
        }
    }

    return $false
}

$powerShellFiles = Get-ChildItem -Path $projectRoot -Include *.ps1,*.psm1 -Recurse |
    Where-Object { -not (Test-SkippedPath -FullName $_.FullName) } |
    Sort-Object FullName

if (-not $powerShellFiles) {
    Write-Host "No PowerShell files found."
    exit 0
}

Write-Host "PowerShell syntax check"
$syntaxFailures = @()

foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        $syntaxFailures += [pscustomobject]@{
            File = $file.FullName
            Errors = $errors
        }
        Write-Host "FAIL $($file.FullName)" -ForegroundColor Red
        foreach ($parseError in $errors) {
            Write-Host "  Line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
    } else {
        Write-Host "OK   $($file.FullName)" -ForegroundColor Green
    }
}

if ($syntaxFailures.Count -gt 0) {
    throw "PowerShell syntax check failed for $($syntaxFailures.Count) file(s)."
}

Write-Host ""
Write-Host "PSScriptAnalyzer"

$suppressRules = @(
    "PSAvoidUsingWriteHost",
    "PSUseShouldProcessForStateChangingFunctions",
    "PSUseBOMForUnicodeEncodedFile"
)

$analysis = foreach ($file in $powerShellFiles) {
    Invoke-ScriptAnalyzer -Path $file.FullName -Severity Error,Warning -ExcludeRule $suppressRules
}

if ($analysis) {
    $analysis | Format-Table ScriptName, Line, Severity, RuleName, Message -AutoSize

    $errors = @($analysis | Where-Object Severity -eq "Error")
    if ($errors.Count -gt 0) {
        throw "PSScriptAnalyzer found $($errors.Count) error(s)."
    }

    Write-Warning "PSScriptAnalyzer found warning(s). Review before committing."
} else {
    Write-Host "OK   No PSScriptAnalyzer findings." -ForegroundColor Green
}

