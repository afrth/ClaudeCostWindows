#Requires -Version 5.1
# Claude Cost Tracker — installer (PowerShell 5.1 port of install.sh)

param(
    [switch]$Insiders
)

$ErrorActionPreference = 'Stop'

# Accept bash-style --insiders in addition to PowerShell -Insiders
if (-not $Insiders -and ($args -contains '--insiders')) { $Insiders = $true }

$VscodeDir = if ($Insiders) { '.vscode-insiders' } else { '.vscode' }
$Flavor    = if ($Insiders) { 'VSCode Insiders' } else { 'VSCode' }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookDest  = Join-Path $env:USERPROFILE '.claude\hooks\cost_tracker.py'
$ExtDest   = Join-Path $env:USERPROFILE "$VscodeDir\extensions\claude-cost-tracker-0.1.0"
$Settings  = Join-Path $env:USERPROFILE '.claude\settings.json'
$Registry  = Join-Path $env:USERPROFILE "$VscodeDir\extensions\extensions.json"
$Tracker   = Join-Path $env:USERPROFILE '.claude\cost_tracker.json'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "==> Installing Claude Cost Tracker ($Flavor)"

# 1. Hook script
$hookDir = Split-Path -Parent $HookDest
if (-not (Test-Path $hookDir)) {
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
}
Copy-Item -Path (Join-Path $ScriptDir 'hooks\cost_tracker.py') -Destination $HookDest -Force
Write-Host "    Hook installed: $HookDest"

# 2. VSCode extension
if (-not (Test-Path $ExtDest)) {
    New-Item -ItemType Directory -Path $ExtDest -Force | Out-Null
}
Copy-Item -Path (Join-Path $ScriptDir 'vscode-extension\package.json') -Destination (Join-Path $ExtDest 'package.json') -Force
Copy-Item -Path (Join-Path $ScriptDir 'vscode-extension\extension.js')  -Destination (Join-Path $ExtDest 'extension.js')  -Force
Write-Host "    Extension installed: $ExtDest"

# 3. Register extension in VSCode registry
if (Test-Path $Registry) {
    $registryRaw = Get-Content -Path $Registry -Raw -Encoding UTF8
    if ($registryRaw -notmatch 'claude-cost-tracker') {
        $registryData = $registryRaw | ConvertFrom-Json
        if ($null -eq $registryData) { $registryData = @() }
        $list = New-Object System.Collections.ArrayList
        foreach ($item in @($registryData)) { [void]$list.Add($item) }

        $fsPath = $ExtDest
        $external = 'file:///' + ($ExtDest -replace '\\', '/')

        $entry = [ordered]@{
            identifier = [ordered]@{ id = 'local.claude-cost-tracker' }
            version    = '0.1.0'
            location   = [ordered]@{
                '$mid'   = 1
                fsPath   = $fsPath
                external = $external
                path     = $fsPath
                scheme   = 'file'
            }
            relativeLocation = 'claude-cost-tracker-0.1.0'
            metadata = [ordered]@{
                isApplicationScoped = $false
                isMachineScoped     = $false
                isBuiltin           = $false
                installedTimestamp  = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                pinned              = $false
                source              = 'vsix'
                targetPlatform      = 'undefined'
                updated             = $false
                private             = $false
                isPreReleaseVersion = $false
                hasPreReleaseVersion = $false
                preRelease          = $false
            }
        }

        [void]$list.Add([pscustomobject]$entry)
        $json = $list.ToArray() | ConvertTo-Json -Depth 10 -Compress
        Write-Utf8NoBom -Path $Registry -Content $json
        Write-Host "    Extension registered in $Flavor"
    } else {
        Write-Host "    Extension already registered, skipping"
    }
}

# 4. Claude Code hook in settings.json
if (-not (Test-Path $Settings)) {
    Write-Utf8NoBom -Path $Settings -Content '{"effortLevel": "high"}'
}

$hookCmd = 'python "' + $HookDest + '"'
$settingsRaw = Get-Content -Path $Settings -Raw -Encoding UTF8
$settingsObj = $settingsRaw | ConvertFrom-Json

# Ensure hooks property
if (-not ($settingsObj.PSObject.Properties.Name -contains 'hooks')) {
    $settingsObj | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
}
$hooksProp = $settingsObj.hooks
if ($null -eq $hooksProp) {
    $hooksProp = [pscustomobject]@{}
    $settingsObj.hooks = $hooksProp
}

# Ensure Stop array
if (-not ($hooksProp.PSObject.Properties.Name -contains 'Stop')) {
    $hooksProp | Add-Member -NotePropertyName 'Stop' -NotePropertyValue @()
}

$stopArr = @()
if ($null -ne $hooksProp.Stop) {
    $stopArr = @($hooksProp.Stop)
}

$already = $false
foreach ($entry in $stopArr) {
    if ($null -eq $entry) { continue }
    $innerHooks = @()
    if ($entry.PSObject.Properties.Name -contains 'hooks' -and $null -ne $entry.hooks) {
        $innerHooks = @($entry.hooks)
    }
    foreach ($h in $innerHooks) {
        if ($null -eq $h) { continue }
        if ($h.PSObject.Properties.Name -contains 'command' -and $h.command -eq $hookCmd) {
            $already = $true
            break
        }
    }
    if ($already) { break }
}

if (-not $already) {
    $newEntry = [pscustomobject][ordered]@{
        matcher = ''
        hooks   = @(
            [pscustomobject][ordered]@{
                type    = 'command'
                command = $hookCmd
            }
        )
    }
    $stopArr = $stopArr + $newEntry
    $hooksProp.Stop = $stopArr
    $json = $settingsObj | ConvertTo-Json -Depth 20
    Write-Utf8NoBom -Path $Settings -Content $json
    Write-Host "    Hook registered in ~/.claude/settings.json"
} else {
    Write-Host "    Hook already registered, skipping"
}

# 5. Init empty tracker if not exists
if (-not (Test-Path $Tracker)) {
    Write-Utf8NoBom -Path $Tracker -Content '{"total_cost":0,"total_requests":0,"by_day":{},"sessions":{},"last_updated":"waiting for first request..."}'
    Write-Host "    Created: $Tracker"
}

Write-Host ""
Write-Host "Done! Restart $Flavor to see the cost tracker in the status bar (bottom right)."
