[CmdletBinding()]
param(
    [string]$ExecutablePath = (Join-Path $env:LOCALAPPDATA 'Programs\Syncthing\syncthing.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "Syncthing executable was not found: $ExecutablePath"
}

$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$running = Get-Process -Name syncthing -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $resolvedExecutable } |
    Select-Object -First 1

if ($running) {
    Write-Host "Syncthing is already running with PID $($running.Id)."
    exit 0
}

Start-Process -FilePath $resolvedExecutable -ArgumentList '--no-browser','--no-restart' -WindowStyle Hidden
Write-Host 'Syncthing started in the background.'

