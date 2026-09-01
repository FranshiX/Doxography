[CmdletBinding()]
param(
    [string]$VaultPath,
    [int]$QuietSeconds = 20,
    [switch]$Push,
    [switch]$DryRun
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
    'tools',
    'Agent_v2.md',
    '.gitignore',
    '.stignore.shared'
)
$logDirectory = Join-Path $resolvedVault '.vault-tools\logs'
$logPath = Join-Path $logDirectory 'vault-snapshot.log'

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Stop-Snapshot {
    param([string]$Reason, [int]$Code = 1)
    Write-Log "STOP: $Reason"
    exit $Code
}

function Get-SafeVaultFiles {
    param([Parameter(Mandatory)][string]$Root)

    foreach ($rootName in $safeGitPathspecs) {
        $path = Join-Path $Root $rootName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Get-Item -LiteralPath $path -Force
        }
        elseif (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Force -File -Recurse -ErrorAction Stop
        }
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-Snapshot 'git is not installed or is not available in PATH.'
}

Push-Location -LiteralPath $resolvedVault
try {
    if ((& git rev-parse --is-inside-work-tree 2>$null) -ne 'true') {
        Stop-Snapshot 'the selected vault is not a Git working tree.'
    }

    $gitDirectory = (& git rev-parse --git-dir).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) {
        $gitDirectory = Join-Path $resolvedVault $gitDirectory
    }

    $repositoryOperations = @(
        (Join-Path $gitDirectory 'MERGE_HEAD'),
        (Join-Path $gitDirectory 'rebase-merge'),
        (Join-Path $gitDirectory 'rebase-apply'),
        (Join-Path $gitDirectory 'CHERRY_PICK_HEAD')
    )
    if ($repositoryOperations | Where-Object { Test-Path -LiteralPath $_ }) {
        Stop-Snapshot 'a merge, rebase, or cherry-pick is in progress.'
    }

    $unmerged = @(& git diff --name-only --diff-filter=U -- @safeGitPathspecs)
    if ($unmerged.Count -gt 0) {
        Stop-Snapshot 'Git has unresolved merge conflicts.'
    }

    $syncConflicts = @(Get-SafeVaultFiles -Root $resolvedVault |
        Where-Object { $_.Name -like '*.sync-conflict-*' })
    if ($syncConflicts.Count -gt 0) {
        Stop-Snapshot "found $($syncConflicts.Count) Syncthing conflict file(s)."
    }

    $changes = @(& git status --porcelain=v1 --untracked-files=all -- @safeGitPathspecs)
    if ($changes.Count -eq 0) {
        Write-Log 'No changes to snapshot.'
        exit 0
    }

    if ($DryRun) {
        Write-Log "DRY RUN: $($changes.Count) pending path(s); no files were staged or committed."
        $changes | ForEach-Object { Write-Host $_ }
        exit 0
    }

    if ($QuietSeconds -gt 0) {
        $latestFile = Get-SafeVaultFiles -Root $resolvedVault |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($latestFile) {
            $ageSeconds = ((Get-Date).ToUniversalTime() - $latestFile.LastWriteTimeUtc).TotalSeconds
            if ($ageSeconds -ge 0 -and $ageSeconds -lt $QuietSeconds) {
                Stop-Snapshot "the vault changed less than $QuietSeconds seconds ago; waiting for a quiet period." 3
            }
        }
    }

    & git add -A -- @safeGitPathspecs
    if ($LASTEXITCODE -ne 0) {
        Stop-Snapshot 'git add failed.'
    }

    & git diff --cached --quiet -- @safeGitPathspecs
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Nothing remained staged after applying ignore rules.'
        exit 0
    }
    if ($LASTEXITCODE -ne 1) {
        Stop-Snapshot 'could not inspect staged changes.'
    }

    $message = 'vault snapshot: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    & git commit -m $message -- @safeGitPathspecs
    if ($LASTEXITCODE -ne 0) {
        Stop-Snapshot 'git commit failed.'
    }
    Write-Log "Created commit: $message"

    if ($Push) {
        $branch = (& git branch --show-current).Trim()
        if (-not $branch) {
            Stop-Snapshot 'cannot push from a detached HEAD.'
        }
        & git push origin $branch
        if ($LASTEXITCODE -ne 0) {
            Stop-Snapshot 'commit succeeded, but push failed. The commit remains safely stored locally.'
        }
        Write-Log "Pushed branch '$branch' to origin."
    }
}
finally {
    Pop-Location
}
