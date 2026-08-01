[CmdletBinding()]
param(
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'backups' }
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDirectory).Path
$archiveName = "jenkins-home-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).tar.gz"
$containerWasRunning = $false

Push-Location $repoRoot
try {
    $containerId = (docker compose ps --quiet controller).Trim()
    if (-not $containerId) { throw 'Controller container does not exist; cannot discover its Jenkins Home volume.' }

    $volumeName = (docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}' $containerId).Trim()
    if (-not $volumeName) { throw 'Controller does not use a named Jenkins Home volume.' }

    $runningState = (docker inspect --format '{{.State.Running}}' $containerId).Trim()
    $containerWasRunning = $runningState -eq 'true'
    if ($containerWasRunning) {
        docker compose stop controller
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop Controller for a consistent backup.' }
    }

    $arguments = @(
        'run', '--rm', '--user', '0', '--entrypoint', 'tar',
        '--volume', "${volumeName}:/source:ro",
        '--volume', "${outputPath}:/backup",
        'jenkins-platform/controller:2.568.1',
        '-czf', "/backup/$archiveName", '-C', '/source', '.'
    )
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Jenkins Home backup failed.' }

    $archive = Join-Path $outputPath $archiveName
    if (-not (Test-Path -LiteralPath $archive)) { throw 'Backup archive was not created.' }
    Write-Host "Backup created: $archive"
}
finally {
    if ($containerWasRunning) {
        docker compose start controller | Out-Host
    }
    Pop-Location
}

