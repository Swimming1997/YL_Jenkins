[CmdletBinding()]
param(
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Linux engine is unavailable. Start Docker Desktop and retry.'
    }

    if (-not (Test-Path -LiteralPath '.env')) {
        Copy-Item -LiteralPath '.env.example' -Destination '.env'
        Write-Host 'Created .env from .env.example.'
    }

    & (Join-Path $PSScriptRoot 'generate-secrets.ps1')

    docker compose config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'docker compose config validation failed.' }

    $arguments = @('compose', 'up', '--detach')
    if (-not $NoBuild) { $arguments += '--build' }
    $arguments += 'controller'
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Jenkins startup failed.' }

    $deadline = (Get-Date).AddMinutes(5)
    do {
        $containerId = docker compose ps --quiet controller
        if ($containerId) {
            $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId
            if ($health -eq 'healthy') {
                $published = (docker compose port controller 8080).Trim()
                Write-Host "Jenkins is healthy at http://$published"
                Write-Host 'Local account passwords are stored in the Git-ignored .secrets directory.'
                exit 0
            }
            if ($health -eq 'unhealthy') {
                docker compose logs --tail 100 controller
                throw 'Jenkins health check reported unhealthy.'
            }
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    docker compose logs --tail 100 controller
    throw 'Timed out waiting for Jenkins health.'
}
finally {
    Pop-Location
}
