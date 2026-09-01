[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(15, 1440)]
    [int]$IntervalMinutes = 60,
    [string]$TaskName = 'Doxography Vault Snapshot',
    [switch]$Push
)

$ErrorActionPreference = 'Stop'
$snapshotScript = Join-Path $PSScriptRoot 'Vault-Snapshot.ps1'
if (-not (Test-Path -LiteralPath $snapshotScript)) {
    throw "Snapshot script was not found: $snapshotScript"
}

$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$snapshotScript`""
if ($Push) { $taskCommand += ' -Push' }

if ($PSCmdlet.ShouldProcess($TaskName, "Create a task that runs every $IntervalMinutes minutes")) {
    & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO $IntervalMinutes /TR $taskCommand /F
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Task Scheduler returned exit code $LASTEXITCODE."
    }
    Write-Host "Scheduled task '$TaskName' was created."
    Write-Host "Command: $taskCommand"
}

