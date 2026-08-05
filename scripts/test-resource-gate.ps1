[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures\resource-gate'
$helper = Join-Path $repoRoot 'shared-library\resources\xhsmedium\paper-server-resource-gate.py'
$image = 'jenkins-platform/build-agent:node20'
$ownUrl = 'http://controller:8080/job/XHSMedium/job/Regression/job/scheduled/21/'

function Invoke-GateCase {
    param(
        [Parameter(Mandatory)][string]$Controller,
        [Parameter(Mandatory)][string]$Executors,
        [Parameter(Mandatory)][int]$ExpectedExit,
        [Parameter(Mandatory)][string]$ExpectedState
    )

    $caseId = (($Controller + '-' + $Executors) -replace '[^a-zA-Z0-9_.-]', '-').ToLowerInvariant()
    $containerName = "jenkins-platform-resource-gate-$caseId"
    if (docker ps -a --filter "name=^/${containerName}$" --format '{{.ID}}') { throw "Resource gate test container already exists: $containerName" }
    $output = & docker run --rm --name $containerName --network none --read-only --cap-drop ALL `
        --security-opt no-new-privileges `
        --volume "${helper}:/test/gate.py:ro" `
        --volume "${fixtureRoot}:/test/fixtures:ro" `
        --entrypoint python3 $image `
        /test/gate.py "/test/fixtures/$Controller" "/test/fixtures/$Executors" $ownUrl 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $ExpectedExit) { throw "Resource gate case $Controller/$Executors exited $exitCode, expected $ExpectedExit. Output: $output" }
    if (($output -join "`n") -notmatch "state=$ExpectedState") { throw "Resource gate case $Controller/$Executors did not emit state=$ExpectedState. Output: $output" }
    if (docker ps -a --filter "name=^/${containerName}$" --format '{{.ID}}') { throw "Resource gate test container remains: $containerName" }
}

Invoke-GateCase controller-30g.json executors-other.json 0 NORMAL
Invoke-GateCase controller-25g.json executors-own.json 0 WARNING
Invoke-GateCase controller-25g.json executors-other.json 79 CONCURRENCY_BLOCKED
Invoke-GateCase controller-below25g.json executors-own.json 78 BLOCKED
Invoke-GateCase controller-below20g.json executors-own.json 78 EMERGENCY

$containers = docker ps -a --filter 'name=jenkins-platform-resource-gate-' --format '{{.Names}}'
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect resource-gate test residue.' }
if ($containers) { throw "Resource-gate test left containers: $($containers -join ', ')" }

Write-Host 'PASS: paper-server resource gate boundaries and cleanup validated in Docker.'
