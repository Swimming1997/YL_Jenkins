[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$probe = "/var/jenkins_home/.p0-persistence-$([guid]::NewGuid().ToString('N'))"

Push-Location $repoRoot
try {
    $containerId = (docker compose ps --quiet controller).Trim()
    if (-not $containerId) { throw 'Controller container is not running.' }
    $health = 'unknown'

    docker exec $containerId touch $probe
    if ($LASTEXITCODE -ne 0) { throw 'Could not create persistence probe.' }

    docker compose up --detach --force-recreate --no-deps controller
    if ($LASTEXITCODE -ne 0) { throw 'Could not recreate controller.' }

    $deadline = (Get-Date).AddMinutes(3)
    do {
        $containerId = (docker compose ps --quiet controller).Trim()
        if ($containerId) {
            $health = (docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId).Trim()
            if ($health -eq 'healthy') { break }
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    if ($health -ne 'healthy') { throw 'Recreated controller did not become healthy.' }

    docker exec $containerId test -f $probe
    if ($LASTEXITCODE -ne 0) { throw 'Persistence probe did not survive container recreation.' }

    docker exec $containerId rm -f $probe
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove persistence probe.' }
    Write-Host 'PASS: Jenkins home persisted across controller recreation; probe was removed.'
}
finally {
    Pop-Location
}
