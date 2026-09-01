[CmdletBinding()]
param(
    [string]$VaultPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VaultPath)) {
    $VaultPath = Split-Path -Parent $PSScriptRoot
}
$allowedRootNames = @(
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

function Get-SafeVaultFiles {
    param([Parameter(Mandatory)][string]$Root)

    foreach ($rootName in $allowedRootNames) {
        $path = Join-Path $Root $rootName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Get-Item -LiteralPath $path -Force
        }
        elseif (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Force -File -Recurse -ErrorAction Stop
        }
    }
}

$resolvedVault = (Resolve-Path -LiteralPath $VaultPath).Path
$conflicts = @(Get-SafeVaultFiles -Root $resolvedVault |
    Where-Object { $_.Name -like '*.sync-conflict-*' })

if ($conflicts.Count -eq 0) {
    Write-Host 'No Syncthing conflict files were found.' -ForegroundColor Green
    exit 0
}

Write-Warning "Found $($conflicts.Count) Syncthing conflict file(s). Resolve them before creating a snapshot."
$conflicts |
    Select-Object FullName, LastWriteTime, Length |
    Format-Table -AutoSize
exit 2
