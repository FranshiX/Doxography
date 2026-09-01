[CmdletBinding()]
param(
    [string]$VaultPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VaultPath)) {
    $VaultPath = Split-Path -Parent $PSScriptRoot
}
$resolvedVault = (Resolve-Path -LiteralPath $VaultPath).Path
$safeGitPathspecs = @(
    '.obsidian',
    '٠٠-الفهرس',
    'الأدب-والفن',
    'الأسطورة-وعلم-الأديان-المقارن',
    'الأنثروبولوجيا',
    'التاريخ-والسياق',
    'التقاليد-الباطنية',
    'الفلسفة',
    'علم-النفس-العميق',
    'عقل-الدوكسوغراف',
    'tools',
    'Agent_v2.md',
    'INVOKE_AGENT.md',
    '.gitignore',
    '.stignore.shared'
)
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details
    )

    $checks.Add([pscustomobject]@{
        Check   = $Name
        Status  = if ($Passed) { 'OK' } else { 'ATTENTION' }
        Details = $Details
    })
}

Push-Location -LiteralPath $resolvedVault
try {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    Add-Check -Name 'Git installed' -Passed ([bool]$gitCommand) -Details $(if ($gitCommand) { $gitCommand.Source } else { 'git was not found' })

    if ($gitCommand) {
        $insideRepository = (& git rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        Add-Check -Name 'Git repository' -Passed $insideRepository -Details $resolvedVault

        if ($insideRepository) {
            $branch = (& git branch --show-current).Trim()
            $remote = (& git remote get-url origin 2>$null)
            $statusLines = @(& git status --porcelain=v1 --untracked-files=all -- @safeGitPathspecs)
            Add-Check -Name 'Current branch' -Passed ([bool]$branch) -Details $branch
            Add-Check -Name 'GitHub remote' -Passed ([bool]$remote) -Details $(if ($remote) { $remote } else { 'origin is not configured' })
            Add-Check -Name 'Working tree' -Passed ($statusLines.Count -eq 0) -Details "$($statusLines.Count) pending path(s) in the explicit allowlist"
        }
    }

    Add-Check -Name 'Shared ignore rules' -Passed (Test-Path -LiteralPath '.stignore.shared') -Details '.stignore.shared'
    Add-Check -Name 'Local Syncthing ignore' -Passed (Test-Path -LiteralPath '.stignore') -Details '.stignore'
    Add-Check -Name 'Git ignore rules' -Passed (Test-Path -LiteralPath '.gitignore') -Details '.gitignore'

    $conflictScript = Join-Path $PSScriptRoot 'Find-Sync-Conflicts.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $conflictScript -VaultPath $resolvedVault *> $null
    $conflictExitCode = $LASTEXITCODE
    Add-Check -Name 'Syncthing conflicts' -Passed ($conflictExitCode -eq 0) -Details $(if ($conflictExitCode -eq 0) { 'none found' } else { 'run Find-Sync-Conflicts.ps1 for details' })

    $syncthingCommand = Get-Command syncthing -ErrorAction SilentlyContinue
    $defaultSyncthingPath = Join-Path $env:LOCALAPPDATA 'Programs\Syncthing\syncthing.exe'
    $syncthingExecutable = if ($syncthingCommand) {
        $syncthingCommand.Source
    }
    elseif (Test-Path -LiteralPath $defaultSyncthingPath) {
        $defaultSyncthingPath
    }
    else {
        $null
    }
    $syncthingProcess = Get-Process -Name syncthing -ErrorAction SilentlyContinue
    Add-Check -Name 'Syncthing installed' -Passed ([bool]$syncthingExecutable) -Details $(if ($syncthingExecutable) { $syncthingExecutable } else { 'not installed yet' })
    Add-Check -Name 'Syncthing running' -Passed ([bool]$syncthingProcess) -Details $(if ($syncthingProcess) { "PID $($syncthingProcess.Id -join ', ')" } else { 'not running' })
}
finally {
    Pop-Location
}

$checks | Format-Table -AutoSize
if ($checks.Status -contains 'ATTENTION') { exit 1 }
exit 0
