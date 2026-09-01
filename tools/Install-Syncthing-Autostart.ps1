[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'Doxography Syncthing'
)

$ErrorActionPreference = 'Stop'
$startScript = Join-Path $PSScriptRoot 'Start-Syncthing.ps1'
if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "Start script was not found: $startScript"
}

$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`""
if ($PSCmdlet.ShouldProcess($TaskName, 'Create an at-logon task for Syncthing')) {
    & schtasks.exe /Create /TN $TaskName /SC ONLOGON /TR $taskCommand /F
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Task Scheduler returned exit code $LASTEXITCODE."
    }
    Write-Host "Scheduled task '$TaskName' was created."
}

