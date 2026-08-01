[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupFile,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]+$')]
    [string]$TargetVolume
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$archive = (Resolve-Path -LiteralPath $BackupFile).Path
$archiveDirectory = Split-Path -Parent $archive
$archiveName = Split-Path -Leaf $archive
$createdVolume = $false

docker volume inspect $TargetVolume *> $null
if ($LASTEXITCODE -eq 0) {
    throw "Target volume already exists; restore refuses to overwrite it: $TargetVolume"
}

try {
    docker volume create $TargetVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create target volume.' }
    $createdVolume = $true

    $arguments = @(
        'run', '--rm', '--user', '0', '--entrypoint', 'tar',
        '--volume', "${TargetVolume}:/target",
        '--volume', "${archiveDirectory}:/backup:ro",
        'jenkins-platform/controller:2.568.1',
        '-xzf', "/backup/$archiveName", '-C', '/target'
    )
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Jenkins Home restore failed.' }
    Write-Host "Restore completed into volume: $TargetVolume"
}
catch {
    if ($createdVolume) { docker volume rm $TargetVolume *> $null }
    throw
}

