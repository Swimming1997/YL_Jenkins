[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
$containerName = "p45-disk-pressure-$suffix"
$volumeName = "p45_disk_pressure_$suffix"
$volumeCreated = $false
$containerCreated = $false

try {
    docker volume create --driver local --opt type=tmpfs --opt device=tmpfs --opt o=size=32m $volumeName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated capacity-limited volume.' }
    $volumeCreated = $true

    $containerId = (docker run --detach --name $containerName --network none --security-opt no-new-privileges:true --memory 768m --pids-limit 256 --volume "${volumeName}:/var/jenkins_home" --env 'JAVA_OPTS=-Djenkins.install.runSetupWizard=false' jenkins-platform/controller:2.568.1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $containerId) { throw 'Could not start the isolated disk-pressure Controller.' }
    $containerCreated = $true

    $deadline = (Get-Date).AddMinutes(2)
    $detected = $false
    $logs = ''
    do {
        $logs = docker logs $containerName 2>&1 | Out-String
        if ($logs -match '(?i)No space left on device|Disk quota exceeded') { $detected = $true; break }
        $running = (docker inspect --format '{{.State.Running}}' $containerName).Trim()
        if ($running -ne 'true') { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    Assert-True $detected 'Isolated Controller reports an explicit disk-capacity failure.'
    Assert-True ($logs -notmatch 'Jenkins is fully up and running') 'Capacity-starved Controller is not reported as healthy.'
    Write-Host "P45_DISK_PRESSURE_EVIDENCE: container=$containerName volume_size=32m detected=true"
}
finally {
    if ($containerCreated) { docker rm --force $containerName *> $null }
    if ($volumeCreated) { docker volume rm $volumeName *> $null }
}

